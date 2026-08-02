import Foundation
import Security

enum KeychainKey: String {
    case anthropic = "anthropic-api-key"
    case openai = "openai-api-key"
}

/// Generic-password Keychain wrapper for Hush's API keys. Values never
/// touch UserDefaults, logs, or disk.
enum KeychainStore {
    private static let service = "com.hush.app.keys"

    static func set(_ value: String, for key: KeychainKey) {
        delete(key)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // Account name and numeric status only — never the key material.
            NSLog("Hush: keychain write failed for %@ (status %d)", key.rawValue, Int(status))
        }
    }

    static func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    static func delete(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        // Status intentionally discarded: errSecItemNotFound is the normal
        // first-write case, so a failure here carries no useful signal.
        SecItemDelete(query as CFDictionary)
    }
}
