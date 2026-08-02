import Foundation
import Security

/// Reads DeviceConfig from the shared App Group keychain.
/// Mirrors KeychainHelper but only needs read access.
enum SharedKeychainHelper {
    private static let service = "com.silv.Robo"
    private static let account = "deviceConfig"
    // Team ID prefix must match DEVELOPMENT_TEAM in project.yml
    private static let accessGroup = "R3Z5CY34Q5.group.com.silv.Robo"

    static func load() -> SharedDeviceConfig? {
        // Try shared access group first (written by build 163+)
        if let config = query(accessGroup: accessGroup) {
            return config
        }
        // Fallback: try without access group (pre-163 keychain entries)
        if let config = query(accessGroup: nil) {
            return config
        }
        return nil
    }

    /// Debug info for troubleshooting keychain issues in the share extension UI.
    static var debugStatus: String {
        let shared = query(accessGroup: accessGroup)
        let legacy = query(accessGroup: nil)
        var parts: [String] = []
        if let s = shared { parts.append("shared:\(s.id.prefix(8))") }
        else { parts.append("shared:nil") }
        if let l = legacy { parts.append("legacy:\(l.id.prefix(8))") }
        else { parts.append("legacy:nil") }
        return parts.joined(separator: " ")
    }

    private static func query(accessGroup: String?) -> SharedDeviceConfig? {
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
        return try? JSONDecoder().decode(SharedDeviceConfig.self, from: data)
    }
}

/// Minimal subset of DeviceConfig needed by the share extension.
/// Fields are decoded from the full DeviceConfig stored by the main app.
struct SharedDeviceConfig: Codable {
    var id: String
    var apiBaseURL: String
    var mcpToken: String?
}
