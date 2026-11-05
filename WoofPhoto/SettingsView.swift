import SwiftUI
import WidgetKit

/// Account, backup, storage and the M0 checks, behind the Library's account button.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var me: User?
    @State private var version: String?
    @State private var cacheSize = URLCache.shared.currentDiskUsage
    @AppStorage("library.columns") private var columns = 5

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Name", value: me?.name ?? "…")
                LabeledContent("Email", value: me?.email ?? "…")
                LabeledContent("Server", value: session.client?.server.absoluteString ?? "?")
                if let version { LabeledContent("Server Version", value: version) }
            }
            Section {
                NavigationLink("Backup") { BackupView() }
                NavigationLink("Featured Photos Widget") { WidgetSettings() }
            }
            Section {
                LabeledContent("Saved Thumbnails", value: Int64(cacheSize).formatted(.byteCount(style: .file)))
                Button("Clear Saved Thumbnails") {
                    URLCache.shared.removeAllCachedResponses()
                    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "originals"))
                    cacheSize = URLCache.shared.currentDiskUsage
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Thumbnails and photos you opened stay on this iPhone, so they show without a connection. Up to 512 MB.")
            }
            Section {
                NavigationLink("M0 Checks") { SpikesView() }
            }
            Section {
                Button("Sign Out", role: .destructive) { session.signOut() }
            }
        }
        .navigationTitle("Settings")
        .task {
            guard let client = session.client else { return }
            me = try? await client.me()
            let info: ServerVersion? = try? await client.get("/server/version")
            version = info.map { "\($0.major).\($0.minor).\($0.patch)" }
        }
    }
}

private struct ServerVersion: Decodable {
    var major: Int
    var minor: Int
    var patch: Int
}

/// Chooses the photos for the Featured Photos widget and copies them into the shared folder.
struct WidgetSettings: View {
    @Environment(Session.self) private var session
    @AppStorage("featured.favoritesOnly") private var favoritesOnly = false
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Favorites Only", isOn: $favoritesOnly)
                Button("Choose New Photos") { Task { await refresh() } }
                    .disabled(busy)
                if busy { ProgressView() }
                if let status { Text(status).foregroundStyle(.secondary) }
            } footer: {
                Text("Add the WoofPhoto widget to the Home Screen. It shows a different one of these photos every hour. WoofPhoto chooses new ones once a day when you open it.")
            }
        }
        .navigationTitle("Featured Photos")
    }

    private func refresh() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            let count = try await FeaturedPhotos.refresh(client: client, favoritesOnly: favoritesOnly)
            status = "\(count) photos ready for the widget."
        } catch {
            status = error.explanation
        }
    }
}

enum FeaturedPhotos {
    /// Picks 24 random photos, saves each as an 800-pixel JPEG for the widget, and reloads it.
    @discardableResult
    static func refresh(client: ImmichClient, favoritesOnly: Bool = UserDefaults.standard.bool(forKey: "featured.favoritesOnly")) async throws -> Int {
        guard let folder = Featured.folder else { throw FeaturedError.noGroup }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var body: [String: Any] = ["size": 24, "type": "IMAGE"]
        if favoritesOnly { body["isFavorite"] = true }
        let assets: [Asset] = try await client.fetch("POST", "/search/random", body: body)
        var items: [Featured.Item] = []
        for asset in assets {
            guard let data = try? await client.image(asset.id, size: "preview"), let image = UIImage(data: data),
                  let small = image.preparingThumbnail(of: fit(image.size, side: 800))?.jpegData(compressionQuality: 0.8) else { continue }
            let file = "\(asset.id).jpg"
            try small.write(to: folder.appending(path: file))
            items.append(Featured.Item(id: asset.id, file: file, date: asset.date))
        }
        try Featured.save(items)
        UserDefaults.standard.set(Date.now, forKey: "featured.updated")
        WidgetCenter.shared.reloadAllTimelines()
        return items.count
    }

    /// Refreshes at most once a day, when the app opens.
    static func refreshIfStale(client: ImmichClient) async {
        let last = UserDefaults.standard.object(forKey: "featured.updated") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 86400 else { return }
        try? await refresh(client: client)
    }

    private static func fit(_ size: CGSize, side: CGFloat) -> CGSize {
        let scale = min(1, side / max(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    enum FeaturedError: LocalizedError {
        case noGroup
        var errorDescription: String? { "The widget's shared folder isn't available. Check the App Group in M0 Checks." }
    }
}
