import Foundation
import LocalAuthentication
import Security

enum Keychain {
    /// Reads a generic password. `allowUI: false` fails instead of prompting, so background
    /// refreshes stay silent; it only succeeds once the user chose "Always Allow".
    static func read(service: String, allowUI: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Value of the deprecated kSecUseAuthenticationUIFail. interactionNotAllowed alone
            // still shows Allow/Deny ACL prompts for legacy (file) keychain items.
            query[kSecUseAuthenticationUI as String] = "u_AuthUIF"
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Attributes-only lookup: never returns the secret, never prompts.
    static func exists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}
