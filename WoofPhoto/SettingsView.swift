import SwiftUI
import WidgetKit

/// Account, backup, storage and the M0 checks, behind the Library's account button.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var me: User?
    @State private var version: String?
    @State private var cacheSize = URLCache.shared.currentDiskUsage
    @AppStorage("library.columns") private var columns = 5
    @AppStorage("accent") private var accent = AccentPreset.all[0].name

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Text(me?.name.first.map(String.init) ?? "")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.tint, in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me?.name ?? "…").font(.headline)
                        Text(me?.email ?? "…")
                        Text([session.client?.server.host(), version.map { "Immich \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 4)
            }
            Section("Accent Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                    ForEach(AccentPreset.all) { preset in
                        Button {
                            accent = preset.name
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if preset.name == accent {
                                        Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(ZoomPressStyle())
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(preset.name == accent ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
                .sensoryFeedback(.selection, trigger: accent)
            }
            Section {
                NavigationLink { BackupView() } label: { row("Backup", "icloud.and.arrow.up", .green) }
                NavigationLink { WidgetSettings() } label: { row("Featured Photos Widget", "square.grid.2x2", .purple) }
            }
            Section {
                LabeledContent { Text(Int64(cacheSize).formatted(.byteCount(style: .file))) } label: { row("Saved Thumbnails", "internaldrive", .gray) }
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
                NavigationLink { SpikesView() } label: { row("M0 Checks", "checklist", .gray) }
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

    /// A row with a coloured icon square, like iOS Settings.
    private func row(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: .rect(cornerRadius: 7))
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
