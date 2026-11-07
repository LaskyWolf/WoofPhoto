import Foundation
import LocalAuthentication
import Security

/// Small secrets: the token, proxy headers, the Hidden PIN, the Gotify token.
/// Plain items go into the App Group's keychain group, so the share extension can read them too.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "WoofPhoto", kSecAttrAccount as String: key]
    }

    /// Without an access group, a read looks in every group the signature allows: the shared one and the app's own.
    static func read(_ key: String) -> String? {
        var item: CFTypeRef?
        var q = query(key)
        q[kSecReturnData as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `protected`: iOS itself asks for Face ID or the passcode before handing the value back. Protected items stay in the app's own group.
    static func write(_ key: String, _ value: String, protected: Bool = false) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        if protected, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) {
            q[kSecAttrAccessControl as String] = access
            SecItemAdd(q as CFDictionary, nil)
            return
        }
        // never copied to backups or a new iPhone; still readable by the background backup
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var shared = q
        shared[kSecAttrAccessGroup as String] = AppGroup.id
        // a signature without the App Group refuses the shared group: the app's own group still works
        if SecItemAdd(shared as CFDictionary, nil) != errSecSuccess { SecItemAdd(q as CFDictionary, nil) }
    }

    /// Moves a plain item saved by a version before the share extension into the shared group. Not for protected items.
    /// Added there first and deleted from the old group after, so a failure leaves the old copy in place.
    static func share(_ key: String) {
        var item: CFTypeRef?
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let found = item as? [String: Any],
              let old = found[kSecAttrAccessGroup as String] as? String, old != AppGroup.id,
              let data = found[kSecValueData as String] as? Data else { return }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrAccessGroup as String] = AppGroup.id
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return }
        var remove = query(key)
        remove[kSecAttrAccessGroup as String] = old
        SecItemDelete(remove as CFDictionary)
    }

    /// Reads a protected value; iOS shows Face ID with this reason. Off the main thread, since the read waits for it.
    static func readProtected(_ key: String, reason: String) async -> String? {
        await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            var item: CFTypeRef?
            var q = query(key)
            q[kSecReturnData as String] = true
            q[kSecUseAuthenticationContext as String] = context
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Deletes the item from every group.
    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
