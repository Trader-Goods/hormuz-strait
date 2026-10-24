import Foundation
import Security

enum KeychainStore {
    private static let service = "com.tradergoods.spamsweep"

    static func save(email: String, appPassword: String) throws {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(appPassword.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw IMAPError.keychain }
    }

    static func load() -> (email: String, appPassword: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let found = item as? [String: Any],
              let email = found[kSecAttrAccount as String] as? String,
              let data = found[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              !email.isEmpty,
              !password.isEmpty
        else { return nil }
        return (email, password)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
