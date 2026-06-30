import CryptoKit
import Foundation
import Security

/// At-rest encryption for high-sensitivity local data under `~/.hermes/private/`.
/// A 256-bit AES key is stored in the Keychain; payloads are AES-GCM blobs on disk (0600).
enum PrivateStore {
    private static let keychainService = "com.hermes.private-store"
    private static let keychainAccount = "aes-data-key"

    private static var directory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/private", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).enc")
    }

    // MARK: - Codable API

    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        try saveData(data, key: key)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = loadData(key: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Raw data

    static func saveData(_ plaintext: Data, key: String) throws {
        let keyData = try symmetricKey()
        let sealed = try AES.GCM.seal(plaintext, using: keyData)
        guard let combined = sealed.combined else { throw StoreError.sealFailed }
        let url = fileURL(key)
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func loadData(key: String) -> Data? {
        let url = fileURL(key)
        guard let combined = try? Data(contentsOf: url) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: try symmetricKey())
        } catch {
            return nil
        }
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    // MARK: - Keychain

    private static func symmetricKey() throws -> SymmetricKey {
        if let existing = keychainRead() {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        guard keychainWrite(raw) else { throw StoreError.keychainFailed }
        return key
    }

    private static func keychainWrite(_ data: Data) -> Bool {
        keychainDelete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainRead() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    private static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum StoreError: Error {
        case sealFailed
        case keychainFailed
    }
}

/// JSON keys persisted encrypted instead of UserDefaults plist.
enum PrivateStoreKeys {
    static let all: Set<String> = [
        "latestHealth",
        "locationPoints",
        "personalProfile",
        "selfModel",
        "dailyHistory",
        "intentionCards",
        "intentionDismissedIds",
        "intentionDismissedKinds",
        "locationDaily",
        "photoDaily",
        "homeLocationKeyword"
    ]
}
