import Foundation

/// Verifies Google ID tokens (JWTs) sent by the iOS/iPad client.
/// Uses Google's tokeninfo endpoint — no local crypto needed — and caches
/// successful verifications until the token expires to avoid a network
/// round-trip on every request.
actor GoogleTokenVerifier {
    static let shared = GoogleTokenVerifier()

    private struct CacheEntry {
        let email: String
        let aud: String
        let exp: Date
    }
    private var cache: [String: CacheEntry] = [:]

    /// Returns true if the token is a currently-valid Google ID token whose
    /// verified email matches `allowedEmail` AND whose `aud` matches `allowedClientID`.
    ///
    /// `aud` (the OAuth client the token was minted for) MUST be verified: a Google
    /// ID token is not scoped to this app by email alone — the same account's token
    /// from any other app/site would otherwise be accepted (audience confusion).
    func verify(idToken: String, allowedEmail: String, allowedClientID: String) async -> Bool {
        let allowed = allowedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let clientID = allowedClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fail closed: both the allowed email AND the expected client ID (aud) are required.
        guard !allowed.isEmpty, !clientID.isEmpty else { return false }

        let now = Date()

        // Cached?
        if let entry = cache[idToken], entry.exp > now {
            return matches(entry: entry, allowed: allowed, allowedClientID: allowedClientID)
        }

        guard let encoded = idToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://oauth2.googleapis.com/tokeninfo?id_token=\(encoded)") else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = (json["email"] as? String)?.lowercased(),
                  let aud = json["aud"] as? String,
                  let expEpoch = doubleValue(json["exp"]),
                  let iss = json["iss"] as? String
            else { return false }

            // Issuer must be Google.
            guard iss == "accounts.google.com" || iss == "https://accounts.google.com" else { return false }

            // Email must be verified.
            let emailVerified = boolValue(json["email_verified"])
            guard emailVerified else { return false }

            let exp = Date(timeIntervalSince1970: expEpoch)
            guard exp > now else { return false }

            let entry = CacheEntry(email: email, aud: aud, exp: exp)
            cache[idToken] = entry
            pruneExpired(now: now)

            return matches(entry: entry, allowed: allowed, allowedClientID: allowedClientID)
        } catch {
            return false
        }
    }

    private func matches(entry: CacheEntry, allowed: String, allowedClientID: String) -> Bool {
        let clientID = allowedClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        // aud (client ID) is mandatory — prevents accepting the same account's
        // token minted for a different OAuth client (audience confusion).
        guard !clientID.isEmpty, entry.email == allowed, entry.aud == clientID else { return false }
        return true
    }

    private func pruneExpired(now: Date) {
        cache = cache.filter { $0.value.exp > now }
    }

    // tokeninfo returns numeric claims as strings; accept both.
    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let s = any as? String { return s == "true" }
        return false
    }
}
