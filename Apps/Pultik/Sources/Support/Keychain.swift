import Foundation
import Security

/// Pultík's runtime secret store: generic passwords in the login keychain,
/// service `pultik-<integration>`.
///
/// The keychain — not Onyx — is deliberate: Pultík launches at login and polls
/// headless, while Onyx items sit behind Touch ID or a locked vault. Onyx
/// remains the human source of truth; this is the copy an unattended app is
/// allowed to read. (Same split as the CLI's CalDAV credential.)
enum Keychain {
    static func read(service: String, account: String) -> String? {
        try? lookup(service: service, account: account)
    }

    /// Distinguish a missing item from a locked/denied store before trying
    /// an older credential. Failure must never select a stale fallback.
    static func lookup(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return String(data: data, encoding: .utf8)
    }

    /// Upserts. Returns nil on success, a human-readable reason on failure —
    /// callers surface it, never swallow it.
    @discardableResult
    static func write(service: String, account: String, value: String) -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            return SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
        }
        return nil
    }

    @discardableResult
    static func delete(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
        }
        return nil
    }
}
