import WidgetKit
import Foundation

/// The signed-in server. The address lives in UserDefaults and the App Group's settings, the token in the Keychain's shared group,
/// so the share extension can upload too.
@MainActor @Observable
final class Session {
    private(set) var client: ImmichClient?
    /// The server said the token is no longer valid. The sign-in page says so; nothing on this iPhone was removed.
    private(set) var expired = false

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
        await save(client)
    }

    func signInWithSSO(server text: String, browser: (URL) async throws -> URL) async throws {
        var client = try await reach(text)
        client.token = try await client.ssoLogin(browser: browser)
        await save(client)
    }

    private func reach(_ text: String) async throws -> ImmichClient {
        guard let url = ImmichClient.serverURL(from: text) else { throw SignInError.badAddress }
        let client = ImmichClient(server: url)
        try await client.ping()
        return client
    }

    private func save(_ client: ImmichClient) async {
        // after an expired session, the kept Outbox, backup record and offline files belong to the old account:
        // another server or another user starts clean
        let account = try? await client.me().id
        let previous = UserDefaults.standard.string(forKey: "account.id")
        // an unknown account (that request failed) counts as the same one: wiping on a hiccup would lose the Outbox
        let otherAccount = account != nil && previous != nil && account != previous
        if expired, UserDefaults.standard.string(forKey: "server") != client.server.absoluteString || otherAccount {
            removeAccountData()
        }
        expired = false
        if let account { UserDefaults.standard.set(account, forKey: "account.id") }
        // also in the app's own settings, which the sign-in page and the background backup read
        UserDefaults.standard.set(client.server.absoluteString, forKey: "server")
        AppGroup.defaults?.set(client.server.absoluteString, forKey: "server")
        Keychain.write("token", client.token!)
        self.client = client
    }

    /// A 401: the token expired or was revoked (on the web, or by a proxy). Back to sign-in, keeping changes waiting
    /// in the Outbox, the backup record and offline photos, which a sign-in to the same account picks up again.
    func expire() {
        Keychain.delete("token")
        expired = true
        client = nil
    }

    /// Sign Out: leaves nothing of the account on this iPhone.
    func signOut() {
        removeAccountData()
        expired = false
        client = nil
    }

    /// Saved photos, History, the widget's photos, the backup record,
    /// and what the app kept in memory (images, trips, pets, the avatar).
    private func removeAccountData() {
        Keychain.delete("token")
        UserDefaults.standard.removeObject(forKey: "account.id")
        // the next server may be on the same home network: requests must not go to this one's local address
        ImmichClient.localAddress = nil
        Keychain.delete("hidden.pin")
        OfflineDownloads.shared.cancel()
        Backup.shared.enabled = false
        Backup.shared.forget()
        History.shared.clear()
        Pets.shared.forget()
        ImageCache.removeAll()
        Still.forgetBlurs()
        TripsView.found = nil
        TripsView.summary = nil
        AccountButton.loaded = nil
        URLCache.shared.removeAllCachedResponses()
        OfflineFiles.removeAll()
        WidgetSync.clear()
        Outbox.shared.clear()
        Task { await OfflineIndex.shared.clear() }
        for folder in [ImmichClient.offlineFolder, FileManager.default.temporaryDirectory.appending(path: "originals"),
                       Featured.folder].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder)
        }
        WidgetCenter.shared.reloadAllTimelines()
        UserDefaults.standard.removeObject(forKey: "search.recent")
    }
}

enum SignInError: LocalizedError {
    case badAddress
    var errorDescription: String? { "This is not a server address. Example: photos.example.com or 192.168.1.5:2283" }
}
