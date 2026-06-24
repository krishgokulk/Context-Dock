import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.krishgokul.ContextDock") {
        self.service = service
    }

    func string(for account: String) -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    func set(_ value: String, for account: String) {
        guard !value.isEmpty else {
            delete(account: account)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Use the data-protection keychain so item access is scoped by the
            // app's entitlement / Team ID rather than a per-build code-signature
            // ACL. Without this, every Debug rebuild changes the cdhash and macOS
            // re-prompts for the login password to release the item.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
