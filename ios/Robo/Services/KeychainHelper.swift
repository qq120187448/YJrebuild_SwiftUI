import Foundation
import Security

/// Minimal Keychain wrapper for storing DeviceConfig across app reinstalls.
/// Uses App Group access group so the Share Extension can read credentials.
enum KeychainHelper {
    private static let service = "com.silv.Robo"
    private static let account = "deviceConfig"
    // Team ID prefix must match DEVELOPMENT_TEAM in project.yml
    private static let accessGroup = "R3Z5CY34Q5.group.com.silv.Robo"

    @discardableResult
    static func save(_ config: DeviceConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        // Delete existing, then add (simpler than update logic)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> DeviceConfig? {
        // Try with access group first (build 163+)
        if let config = query(accessGroup: accessGroup) {
            return config
        }
        // Fallback: try without access group (pre-163 keychain entries)
        if let config = query(accessGroup: nil) {
            // Migrate: re-save with access group so share extension can read it.
            // Only delete legacy entry if save succeeded — otherwise we'd lose
            // the only copy of the credentials.
            if save(config) {
                deleteLegacy()
            }
            return config
        }
        return nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private static func query(accessGroup: String?) -> DeviceConfig? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceConfig.self, from: data)
    }

    /// Delete legacy keychain entry (no access group) after migration.
    private static func deleteLegacy() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // NO access group — targets legacy entry only
        ]
        SecItemDelete(q as CFDictionary)
    }
}
