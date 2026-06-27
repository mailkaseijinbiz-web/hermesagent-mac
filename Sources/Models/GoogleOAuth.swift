import Foundation
import Network
import Security
import CryptoKit
import AppKit

/// Google OAuth 2.0 (PKCE) manager.
/// Spins up a temporary loopback HTTP listener, opens the auth URL in the
/// default browser, captures the callback code, and exchanges it for tokens.
/// Tokens are stored in the macOS Keychain.
@MainActor
final class GoogleOAuth: ObservableObject {
    static let shared = GoogleOAuth()

    @Published var email: String? = nil
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String? = nil

    /// Supplied by the user in Settings (Google Cloud Console → OAuth 2.0 Client ID for "Desktop app").
    @Published var clientId: String = UserDefaults.standard.string(forKey: "googleClientId") ?? "" {
        didSet { UserDefaults.standard.set(clientId, forKey: "googleClientId") }
    }
    @Published var clientSecret: String = UserDefaults.standard.string(forKey: "googleClientSecret") ?? "" {
        didSet { UserDefaults.standard.set(clientSecret, forKey: "googleClientSecret") }
    }

    private(set) var accessToken: String? = nil
    private var tokenExpiry: Date = .distantPast
    private var codeVerifier: String = ""

    var refreshToken: String? {
        get { keychainRead("google_refresh_token") }
        set { keychainWrite("google_refresh_token", newValue) }
    }

    // Callback server state
    private var listener: NWListener? = nil
    private var callbackPort: UInt16 = 0
    private var pendingCont: CheckedContinuation<String, Error>? = nil
    private let callbackQueue = DispatchQueue(label: "google-oauth-callback")

    let scopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/gmail.modify",
        "openid", "email", "profile"
    ]

    private init() {
        email = UserDefaults.standard.string(forKey: "googleAccountEmail")
        isConnected = refreshToken != nil && !(email ?? "").isEmpty
        if isConnected {
            GoogleCalendarSync.shared.startPeriodicSync()
            GmailSync.shared.startPeriodicSync()
        }
    }

    // MARK: - Public API

    func connect() async {
        guard !clientId.isEmpty else {
            errorMessage = "クライアント ID を設定してください（Google Cloud Console → OAuth 2.0 クライアント ID）"
            return
        }
        guard !clientSecret.isEmpty else {
            errorMessage = "クライアント シークレットを設定してください"
            return
        }
        isConnecting = true
        errorMessage = nil
        do {
            let code = try await startOAuthFlow()
            try await exchangeCode(code)
            isConnected = true
            // 接続後すぐに同期開始
            GoogleCalendarSync.shared.startPeriodicSync()
            GmailSync.shared.startPeriodicSync()
        } catch {
            if (error as? CancellationError) != nil {
                errorMessage = "認証がキャンセルされました"
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isConnecting = false
    }

    func disconnect() {
        accessToken = nil
        tokenExpiry = .distantPast
        refreshToken = nil
        email = nil
        isConnected = false
        UserDefaults.standard.removeObject(forKey: "googleAccountEmail")
    }

    /// Returns a valid access token, refreshing if necessary.
    func validToken() async throws -> String {
        if let t = accessToken, tokenExpiry > Date().addingTimeInterval(120) { return t }
        return try await doRefresh()
    }

    // MARK: - OAuth browser flow

    private func startOAuthFlow() async throws -> String {
        let port = try await startCallbackServer()
        codeVerifier = makeCodeVerifier()
        let challenge = codeChallenge(codeVerifier)
        let state = UUID().uuidString
        let redirectUri = "http://127.0.0.1:\(port)/callback"

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id",             value: clientId),
            .init(name: "redirect_uri",           value: redirectUri),
            .init(name: "response_type",          value: "code"),
            .init(name: "scope",                  value: scopes.joined(separator: " ")),
            .init(name: "code_challenge",         value: challenge),
            .init(name: "code_challenge_method",  value: "S256"),
            .init(name: "state",                  value: state),
            .init(name: "access_type",            value: "offline"),
            .init(name: "prompt",                 value: "consent"),
        ]
        NSWorkspace.shared.open(c.url!)

        return try await withCheckedThrowingContinuation { cont in
            pendingCont = cont
            // Safety timeout: if the browser is closed/abandoned (or the redirect fails),
            // don't lock the UI on "認証中…" forever — fail after 3 minutes.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                if let c = self.pendingCont {
                    self.pendingCont = nil
                    self.listener?.cancel(); self.listener = nil
                    c.resume(throwing: OAuthError.timeout)
                }
            }
        }
    }

    private func exchangeCode(_ code: String) async throws {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return }
        let port = callbackPort
        let redirectUri = "http://127.0.0.1:\(port)/callback"

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id":     clientId,
            "client_secret": clientSecret,
            "code":          code,
            "code_verifier": codeVerifier,
            "redirect_uri":  redirectUri,
            "grant_type":    "authorization_code",
        ].map { "\($0.key)=\($0.value.urlEncoded)" }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.invalidResponse
        }
        if let e = json["error"] as? String {
            throw OAuthError.serverError(e, json["error_description"] as? String ?? "")
        }
        guard let access = json["access_token"] as? String else { throw OAuthError.invalidResponse }
        accessToken = access
        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        tokenExpiry = Date().addingTimeInterval(Double(expiresIn))
        if let refresh = json["refresh_token"] as? String { refreshToken = refresh }

        try await fetchUserEmail()
    }

    private func doRefresh() async throws -> String {
        guard let refresh = refreshToken, !refresh.isEmpty else { throw OAuthError.notAuthenticated }
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { throw OAuthError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id":     clientId,
            "client_secret": clientSecret,
            "refresh_token": refresh,
            "grant_type":    "refresh_token",
        ].map { "\($0.key)=\($0.value.urlEncoded)" }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw OAuthError.invalidResponse }
        accessToken = access
        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        tokenExpiry = Date().addingTimeInterval(Double(expiresIn))
        return access
    }

    private func fetchUserEmail() async throws {
        let token = try await validToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = json["email"] as? String {
            email = e
            UserDefaults.standard.set(e, forKey: "googleAccountEmail")
        }
    }

    // MARK: - Loopback HTTP server

    /// Start the loopback listener on a BACKGROUND queue and resolve the OS-assigned port
    /// via the ready state. (The old code started on `.main` and busy-waited with
    /// `Thread.sleep` — which starved the listener's own delivery queue, leaving the port
    /// at 0 and producing a broken redirect_uri `http://127.0.0.1:0/callback` that hung.)
    private func startCallbackServer() async throws -> UInt16 {
        listener?.cancel()
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleConnection(conn) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = l.port?.rawValue, !resumed { resumed = true; cont.resume(returning: p) }
                case .failed(let err):
                    if !resumed { resumed = true; cont.resume(throwing: err) }
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: OAuthError.invalidResponse) }
                default:
                    break
                }
            }
            l.start(queue: callbackQueue)
        }
        callbackPort = port
        return port
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: callbackQueue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data, let raw = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let code = Self.parseCode(from: raw)
            let html = """
            <html><body style="font-family:system-ui;text-align:center;padding-top:80px">
            <h2>✅ 接続完了</h2><p>このタブを閉じてアプリに戻ってください。</p></body></html>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            // Only resolve on a real callback carrying ?code= (ignore favicon / probes).
            guard let code else { return }
            Task { @MainActor in
                guard let self else { return }
                self.listener?.cancel(); self.listener = nil
                self.pendingCont?.resume(returning: code)
                self.pendingCont = nil
            }
        }
    }

    /// Extract the OAuth `code` from a raw HTTP request line. Static → safe to call off the main actor.
    private static func parseCode(from raw: String) -> String? {
        guard let line = raw.components(separatedBy: "\r\n").first, line.hasPrefix("GET "),
              let urlStr = line.components(separatedBy: " ").dropFirst().first,
              let comps = URLComponents(string: "http://localhost\(urlStr)"),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    // MARK: - PKCE

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(_ verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token storage
    //
    // 認証トークンは ~/.hermes/.oauth/<key> (0600) に保存する。従来のキーチェーンはアプリの
    // cdhash に ACL を固定するため、未署名の開発ビルドのたびに（設定を開いた瞬間など）
    // 「パスワードを入力」プロンプトが出ていた。データ保護キーチェーンも entitlement 依存で
    // 未署名ビルドでは効かず、毎回旧キーチェーンへフォールバックしてプロンプトが出ていた。
    // ファイル保存はコード署名に依存しないのでプロンプトが一切出ない（API キーや LINE トークンと
    // 同じ ~/.hermes 配下、0600）。既存ログインを失わないよう、初回だけ旧キーチェーンから1回だけ
    // 読み出して移行する（その1回のみプロンプトの可能性、以後は二度と出ない）。

    private var oauthDir: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/.oauth")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
    private func tokenFileURL(_ key: String) -> URL { oauthDir.appendingPathComponent(key) }

    private func keychainRead(_ key: String) -> String? {
        // 1) ファイル（プライマリ・プロンプトなし）。
        if let s = try? String(contentsOf: tokenFileURL(key), encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // 2) データ保護キーチェーン（署名ビルド用。未署名では静かに失敗＝プロンプトなし）。
        if let s = readKeychainItem(key, dataProtection: true) {
            writeTokenFile(key, s)
            return s
        }
        // 3) 旧キーチェーンからの1回限り移行（この1回だけプロンプトの可能性）。フラグで以後抑止し、
        //    成功したら旧アイテムを削除してプロンプト源を断つ。
        let migFlag = "oauthMigrated_\(key)"
        if !UserDefaults.standard.bool(forKey: migFlag) {
            UserDefaults.standard.set(true, forKey: migFlag)
            if let s = readKeychainItem(key, dataProtection: false) {
                writeTokenFile(key, s)
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
                               kSecUseDataProtectionKeychain: false] as CFDictionary)
                return s
            }
        }
        return nil
    }

    private func keychainWrite(_ key: String, _ value: String?) {
        guard let v = value, !v.isEmpty else {
            try? FileManager.default.removeItem(at: tokenFileURL(key))
            for dp in [true, false] {
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
                               kSecUseDataProtectionKeychain: dp] as CFDictionary)
            }
            return
        }
        writeTokenFile(key, v)                              // プライマリ。
        _ = writeItem(key, Data(v.utf8), dataProtection: true)   // 署名ビルド用ベストエフォート。
    }

    private func writeTokenFile(_ key: String, _ value: String) {
        let url = tokenFileURL(key)
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)   // atomic: temp file + rename
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // 失敗するとログインが永続化されない（再認証になる）。ファイルログに残す（次回書込で再試行）。
            Log.failure("auth", "Googleトークンの保存に失敗 (\(url.path))", error)
        }
    }

    private func readKeychainItem(_ key: String, dataProtection: Bool) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: dataProtection,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }

    @discardableResult
    private func writeItem(_ key: String, _ d: Data, dataProtection: Bool) -> Bool {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: dataProtection,
        ]
        let attrs: [CFString: Any] = [kSecValueData: d, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        let upd = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if upd == errSecSuccess { return true }
        if upd == errSecItemNotFound {
            var add = q
            add[kSecValueData] = d
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    // MARK: - Errors

    enum OAuthError: LocalizedError {
        case invalidResponse
        case notAuthenticated
        case serverError(String, String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidResponse:          return "無効なレスポンスです"
            case .notAuthenticated:         return "Google アカウントが接続されていません"
            case .serverError(let c, let d): return "\(c): \(d)"
            case .timeout:                  return "認証がタイムアウトしました。ブラウザで認証を完了してから再試行してください。"
            }
        }
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
