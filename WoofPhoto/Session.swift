import WidgetKit
import Foundation

/// The signed-in server. The address lives in UserDefaults and the App Group's settings, the token in the Keychain's shared group,
/// so the share extension can upload too.
@MainActor @Observable
final class Session {
    private(set) var client: ImmichClient?

    init() {
        // versions before the share extension kept these in the app's own settings and keychain group
        if let server = UserDefaults.standard.string(forKey: "server") { AppGroup.defaults?.set(server, forKey: "server") }
        Keychain.share("token")
        Keychain.share("proxyHeaders")
        client = ImmichClient.saved()
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
        // also in the app's own settings, which the sign-in page and the background backup read
        UserDefaults.standard.set(client.server.absoluteString, forKey: "server")
        AppGroup.defaults?.set(client.server.absoluteString, forKey: "server")
        Keychain.write("token", client.token!)
        self.client = client
    }

    /// Leaves nothing of the account on this iPhone: saved photos, History, the widget's photos, the backup record,
    /// and what the app kept in memory (images, trips, pets, the avatar).
    func signOut() {
        Keychain.delete("token")
        Keychain.delete("hidden.pin")
        Backup.shared.forget()
        History.shared.clear()
        Pets.shared.forget()
        ImageCache.removeAll()
        Still.forgetBlurs()
        TripsView.found = nil
        TripsView.summary = nil
        AccountButton.loaded = nil
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
