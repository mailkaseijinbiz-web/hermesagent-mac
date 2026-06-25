import Foundation
import CryptoKit

/// Sends Apple Push Notifications using a token-based (.p8) provider key.
/// The Mac acts as the APNs provider: it signs an ES256 JWT with the .p8 key
/// and POSTs to Apple's APNs HTTP/2 endpoint for each device token.
actor APNsSender {
    static let shared = APNsSender()

    private var cachedJWT: String?
    private var jwtIssuedAt: Date?

    struct Config {
        let keyPath: String      // path to AuthKey_XXXX.p8
        let keyId: String        // 10-char Key ID
        let teamId: String       // 10-char Team ID
        let bundleId: String     // app bundle id (apns-topic)
        let useSandbox: Bool     // dev builds use the sandbox endpoint
    }

    /// Returns device tokens that APNs reported as invalid (410 / Unregistered /
    /// BadDeviceToken) so the caller can purge them.
    @discardableResult
    func send(to deviceTokens: [String], title: String, body: String, sessionId: String?, config: Config) async -> [String] {
        guard !deviceTokens.isEmpty,
              !config.keyId.isEmpty, !config.teamId.isEmpty,
              let jwt = providerJWT(config: config) else { return [] }

        var invalidTokens: [String] = []
        let host = config.useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"

        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "sound": "default"
        ]
        aps["thread-id"] = sessionId ?? "hermes"
        var payload: [String: Any] = ["aps": aps]
        if let sid = sessionId { payload["sessionId"] = sid }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        for token in deviceTokens {
            guard let url = URL(string: "https://\(host)/3/device/\(token)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            req.setValue(config.bundleId, forHTTPHeaderField: "apns-topic")
            req.setValue("alert", forHTTPHeaderField: "apns-push-type")
            req.setValue("10", forHTTPHeaderField: "apns-priority")
            req.httpBody = bodyData
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let msg = String(data: data, encoding: .utf8) ?? ""
                    print("[APNs] \(http.statusCode) for token \(token.prefix(8))…: \(msg)")
                    // Stale/invalid device token — mark for removal.
                    if http.statusCode == 410 || msg.contains("Unregistered") || msg.contains("BadDeviceToken") {
                        invalidTokens.append(token)
                    }
                }
            } catch {
                print("[APNs] send error: \(error)")
            }
        }
        return invalidTokens
    }

    // MARK: - Provider JWT (reusable up to ~1h; cache for 50min)

    private func providerJWT(config: Config) -> String? {
        if let jwt = cachedJWT, let iat = jwtIssuedAt, Date().timeIntervalSince(iat) < 3000 {
            return jwt
        }
        guard let pem = try? String(contentsOfFile: config.keyPath, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            print("[APNs] could not load .p8 key at \(config.keyPath)")
            return nil
        }
        let header: [String: Any] = ["alg": "ES256", "kid": config.keyId]
        let claims: [String: Any] = ["iss": config.teamId, "iat": Int(Date().timeIntervalSince1970)]
        guard let h = try? JSONSerialization.data(withJSONObject: header),
              let c = try? JSONSerialization.data(withJSONObject: claims) else { return nil }

        let signingInput = b64url(h) + "." + b64url(c)
        guard let sig = try? key.signature(for: Data(signingInput.utf8)) else { return nil }
        let jwt = signingInput + "." + b64url(sig.rawRepresentation)
        cachedJWT = jwt
        jwtIssuedAt = Date()
        return jwt
    }

    private func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
