import WidgetKit
import Foundation
import LocalAuthentication
import Security

/// The signed-in server. The address lives in UserDefaults, the token in the Keychain.
@MainActor @Observable
final class Session {
    private(set) var client: ImmichClient?

    init() {
        if let text = UserDefaults.standard.string(forKey: "server"), let url = URL(string: text),
           let token = Keychain.read("token") {
            client = ImmichClient(server: url, token: token)
        }
    }

    func signIn(server text: String, email: String, password: String) async throws {
        var client = try await reach(text)
        client.token = try await client.login(email: email, password: password)
        save(client)
    }

    func signInWithSSO(server text: String, browser: (URL) async throws -> URL) async throws {
        var client = try await reach(text)
        client.token = try await client.ssoLogin(browser: browser)
        save(client)
    }

    private func reach(_ text: String) async throws -> ImmichClient {
        guard let url = ImmichClient.serverURL(from: text) else { throw SignInError.badAddress }
        let client = ImmichClient(server: url)
        try await client.ping()
        return client
    }

    private func save(_ client: ImmichClient) {
        UserDefaults.standard.set(client.server.absoluteString, forKey: "server")
        Keychain.write("token", client.token!)
        self.client = client
    }

    /// Leaves nothing of the account on this iPhone: saved photos, History, the widget's photos and the backup record.
    func signOut() {
        Keychain.delete("token")
        Keychain.delete("hidden.pin")
        Backup.shared.forget()
        History.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        for folder in [ImmichClient.offlineFolder, FileManager.default.temporaryDirectory.appending(path: "originals"),
                       URL.cachesDirectory.appending(path: "spatial"), Featured.folder].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder)
        }
        WidgetCenter.shared.reloadAllTimelines()
        UserDefaults.standard.removeObject(forKey: "search.recent")
        client = nil
    }
}

enum SignInError: LocalizedError {
    case badAddress
    var errorDescription: String? { "This is not a server address. Example: photos.example.com or 192.168.1.5:2283" }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "WoofPhoto", kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var item: CFTypeRef?
        var q = query(key)
        q[kSecReturnData as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `protected`: iOS itself asks for Face ID or the passcode before handing the value back.
    static func write(_ key: String, _ value: String, protected: Bool = false) {
        delete(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        if protected, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) {
            q[kSecAttrAccessControl as String] = access
        } else {
            // never copied to backups or a new iPhone; still readable by the background backup
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        SecItemAdd(q as CFDictionary, nil)
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

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
