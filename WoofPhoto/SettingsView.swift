import SwiftUI
import WidgetKit

/// WoofMusic's settings page: the account on top, then one page per area. Pushed from the account button.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var me: User?
    @State private var showsChecks = false

    var body: some View {
        List {
            Section { accountRow }
            Section("Appearance") {
                SettingsRow("Appearance", icon: "paintpalette") { AppearanceSettings() }
            }
            Section("Library") {
                SettingsRow("Library & Viewer", icon: "photo.on.rectangle") { LibrarySettings() }
            }
            Section("Backup & Storage") {
                SettingsRow("Backup", icon: "icloud.and.arrow.up") { BackupView() }
                SettingsRow("Storage", icon: "internaldrive") { StorageSettings() }
            }
            Section("Server") {
                SettingsRow("Immich", icon: "server.rack") { ImmichSettings() }
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsChecks) { SpikesView() }
        .task { me = try? await session.client?.me() }
    }

    /// Opens the account page. A long press opens the M0 checks, like WoofMusic's hidden Diagnostics.
    private var accountRow: some View {
        NavigationLink { AccountSettings() } label: {
            HStack(spacing: 14) {
                Avatar(name: me?.name, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(me?.name ?? "Account").font(.headline)
                    Text(me?.email ?? session.client?.server.host() ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in showsChecks = true })
        .sensoryFeedback(.impact(weight: .medium), trigger: showsChecks) { _, shown in shown }
        .accessibilityAction(named: "M0 Checks") { showsChecks = true }
    }
}

/// WoofMusic's SettingsNavigationRow: a label with its icon in the accent colour.
struct SettingsRow<Destination: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var destination: () -> Destination

    init(_ title: String, icon: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.icon = icon
        self.destination = destination
    }

    var body: some View {
        NavigationLink { destination() } label: { Label(title, systemImage: icon) }
    }
}

/// The user's initial on the accent colour.
struct Avatar: View {
    let name: String?
    var size: CGFloat = 36

    var body: some View {
        Text(name?.first.map(String.init) ?? "")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

struct AccountSettings: View {
    @Environment(Session.self) private var session
    @State private var me: User?
    @State private var version: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Avatar(name: me?.name, size: 84)
                    Text(me?.name ?? "…").font(.title2.bold())
                    Text(me?.email ?? "").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section("Server") {
                LabeledContent("Address", value: session.client?.server.absoluteString ?? "")
                LabeledContent("Immich", value: version ?? "…")
            }
            if let used = me?.quotaUsageInBytes {
                Section("Storage on the Server") {
                    LabeledContent("Used", value: used.formatted(.byteCount(style: .file)))
                    if let quota = me?.quotaSizeInBytes {
                        LabeledContent("Quota", value: quota.formatted(.byteCount(style: .file)))
                        ProgressView(value: Double(used), total: Double(max(quota, 1)))
                    }
                }
            }
            Section {
                Button("Sign Out", role: .destructive) { session.signOut() }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
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

struct AppearanceSettings: View {
    @AppStorage("accent") private var accent = AccentPreset.all[0].name

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6), spacing: 14) {
                    ForEach(AccentPreset.all) { preset in
                        Button { accent = preset.name } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if preset.name == accent {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(preset.name == accent ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                .sensoryFeedback(.selection, trigger: accent)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Applies to buttons, chips, selection and the selected tab.")
            }
            WidgetSettings()
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Grid, viewer and History on one page, as WoofMusic keeps the player's settings together.
struct LibrarySettings: View {
    var body: some View {
        List {
            TimelineSettings()
            ViewerSettings()
            HistorySettings()
        }
        .navigationTitle("Library & Viewer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TimelineSettings: View {
    @AppStorage("library.columns") private var columns = 5
    @AppStorage("grid.backupBadge") private var backupBadge = true

    var body: some View {
        Section {
            Picker(selection: $columns) {
                ForEach(AssetGrid.columnSteps, id: \.self) { Text("\($0)").tag($0) }
            } label: { Label("Photos per Row", systemImage: "square.grid.3x3") }
        } header: {
            Text("Grid")
        } footer: {
            Text("Pinching the grid changes it too.")
        }
        Section {
            Toggle(isOn: $backupBadge) { Label("Not Backed Up Badge", systemImage: "icloud.slash") }
        } footer: {
            Text("Marks the photos on this iPhone that aren't on the server yet.")
        }
    }
}

struct ViewerSettings: View {
    @AppStorage("viewer.fullSize") private var fullSize = false
    @AppStorage("video.autoplay") private var autoplay = true
    @AppStorage("video.loop") private var loop = false

    var body: some View {
        Section {
            Toggle(isOn: $fullSize) { Label("Load Full-Size Photos", systemImage: "photo") }
        } header: {
            Text("Photos")
        } footer: {
            Text("Off, the full-size photo loads only when you zoom in. On, it loads as soon as the photo opens, which uses more data.")
        }
        Section("Videos") {
            Toggle(isOn: $autoplay) { Label("Play Automatically", systemImage: "play") }
            Toggle(isOn: $loop) { Label("Loop", systemImage: "repeat") }
        }
    }
}

struct HistorySettings: View {
    @AppStorage("history.paused") private var paused = false
    @State private var confirmsClear = false

    var body: some View {
        Section {
            Toggle(isOn: Binding { !paused } set: { paused = !$0 }) { Label("Record History", systemImage: "clock.arrow.circlepath") }
        } header: {
            Text("History")
        } footer: {
            Text("History lists the photos you view, edit, delete, favorite, hide, archive or move between albums. It stays on this iPhone.")
        }
        Section {
            Button("Clear History", role: .destructive) { confirmsClear = true }
                .disabled(History.shared.entries.isEmpty)
        }
        .confirmationDialog("All of History is deleted. Your photos stay as they are.", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { History.shared.clear() }
        }
    }
}

struct StorageSettings: View {
    @State private var cacheSize = URLCache.shared.currentDiskUsage

    var body: some View {
        List {
            Section {
                LabeledContent("Saved Thumbnails", value: Int64(cacheSize).formatted(.byteCount(style: .file)))
                Button("Clear Saved Thumbnails", role: .destructive) {
                    URLCache.shared.removeAllCachedResponses()
                    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "originals"))
                    try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "spatial"))
                    cacheSize = URLCache.shared.currentDiskUsage
                }
            } footer: {
                Text("Thumbnails, photos you opened and Spatial Scenes stay on this iPhone, so they show without a connection. Thumbnails use up to 512 MB.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The user's preferences stored on the Immich server, shared with the web app and the official app.
@MainActor @Observable
final class ServerPreferences {
    private var values: [String: [String: Any]] = [:]
    var loaded = false
    var error: String?

    func load(_ client: ImmichClient?) async {
        guard let client else { return }
        do {
            let data = try await client.call("GET", "/users/me/preferences")
            values = (try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]) ?? [:]
            loaded = true
        } catch {
            self.error = error.explanation
        }
    }

    func value<T>(_ group: String, _ key: String, default fallback: T) -> T { values[group]?[key] as? T ?? fallback }

    /// Saves at once; on failure the switch goes back.
    func binding<T>(_ group: String, _ key: String, default fallback: T, client: ImmichClient?) -> Binding<T> {
        Binding { self.value(group, key, default: fallback) } set: { new in
            let old = self.values[group]?[key]
            self.values[group, default: [:]][key] = new
            Task {
                do {
                    try await client?.call("PUT", "/users/me/preferences", body: [group: [key: new]])
                } catch {
                    self.values[group]?[key] = old
                    self.error = error.explanation
                }
            }
        }
    }
}

/// Everything about the server on one page: its shared preferences, then this iPhone's proxy headers.
struct ImmichSettings: View {
    @Environment(Session.self) private var session
    @State private var prefs = ServerPreferences()
    @State private var headers = ImmichClient.proxyHeaders

    var body: some View {
        let client = session.client
        List {
            if prefs.loaded {
                Section {
                    Toggle(isOn: prefs.binding("memories", "enabled", default: true, client: client)) { Label("Memories", systemImage: "clock.arrow.circlepath") }
                    Toggle(isOn: prefs.binding("people", "enabled", default: true, client: client)) { Label("People", systemImage: "person.2") }
                    Toggle(isOn: prefs.binding("ratings", "enabled", default: false, client: client)) { Label("Ratings", systemImage: "star") }
                    Toggle(isOn: prefs.binding("tags", "enabled", default: false, client: client)) { Label("Tags", systemImage: "tag") }
                    Toggle(isOn: prefs.binding("folders", "enabled", default: false, client: client)) { Label("Folders", systemImage: "folder") }
                    Toggle(isOn: prefs.binding("sharedLinks", "enabled", default: true, client: client)) { Label("Shared Links", systemImage: "link") }
                } header: {
                    Text("Features")
                } footer: {
                    Text("Saved on your Immich server, so the web app and the official app follow them too.")
                }
                Section {
                    Toggle(isOn: prefs.binding("emailNotifications", "enabled", default: true, client: client)) { Label("Email Notifications", systemImage: "envelope") }
                    Toggle(isOn: prefs.binding("emailNotifications", "albumInvite", default: true, client: client)) { Label("Album Invites", systemImage: "person.badge.plus") }
                    Toggle(isOn: prefs.binding("emailNotifications", "albumUpdate", default: true, client: client)) { Label("Album Updates", systemImage: "rectangle.stack.badge.plus") }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Emails from your Immich server, if its administrator set up email.")
                }
                Section {
                    Picker(selection: prefs.binding("download", "archiveSize", default: 4 << 30, client: client)) {
                        ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0) GB").tag($0 << 30) }
                    } label: { Label("Archive Size", systemImage: "archivebox") }
                    Toggle(isOn: prefs.binding("download", "includeEmbeddedVideos", default: false, client: client)) { Label("Include Live Photo Videos", systemImage: "livephoto") }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloads of many items are split into zip files of this size.")
                }
            } else if prefs.error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = prefs.error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            // outside the server's preferences: a proxy may need these before anything loads
            Section {
                TextField("Name: value", text: $headers, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Custom Proxy Headers")
            } footer: {
                Text("One header per line, like CF-Access-Client-Id: abc. Sent with every request, for servers behind a proxy that needs them.")
            }
        }
        .navigationTitle("Immich")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: headers) { ImmichClient.proxyHeaders = headers }
        .task { await prefs.load(client) }
    }
}

/// Chooses the photos for the Featured Photos widget and copies them into the shared folder.
struct WidgetSettings: View {
    @Environment(Session.self) private var session
    @AppStorage("featured.favoritesOnly") private var favoritesOnly = false
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Section {
            Toggle("Favorites Only", isOn: $favoritesOnly)
            Button("Choose New Photos") { Task { await refresh() } }
                .disabled(busy)
            if busy { ProgressView() }
            if let status { Text(status).foregroundStyle(.secondary) }
        } header: {
            Text("Featured Photos Widget")
        } footer: {
            Text("Add the WoofPhoto widget to the Home Screen. It shows a different one of these photos every hour. WoofPhoto chooses new ones once a day when you open it.")
        }
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
        guard !isRefreshing else { return 0 }
        isRefreshing = true
        defer { isRefreshing = false }
        // filled aside and swapped in at the end, so a failed refresh leaves the old photos
        let fresh = folder.deletingLastPathComponent().appending(path: "featured-new")
        try? FileManager.default.removeItem(at: fresh)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        var body: [String: Any] = ["size": 24, "type": "IMAGE"]
        if favoritesOnly { body["isFavorite"] = true }
        let assets: [Asset] = try await client.fetch("POST", "/search/random", body: body)
        var items: [Featured.Item] = []
        for asset in assets {
            guard let data = try? await client.image(asset.id, size: "preview"), let image = UIImage(data: data),
                  let small = image.preparingThumbnail(of: fit(image.size, side: 800))?.jpegData(compressionQuality: 0.8) else { continue }
            let file = "\(asset.id).jpg"
            try small.write(to: fresh.appending(path: file))
            items.append(Featured.Item(id: asset.id, file: file, date: asset.date))
        }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: fresh, to: folder)
        try Featured.save(items)
        UserDefaults.standard.set(Date.now, forKey: "featured.updated")
        WidgetCenter.shared.reloadAllTimelines()
        return items.count
    }

    /// Refreshes at most once a day, when the app opens.
    // ponytail: a plain flag; refreshes start from the main actor only
    nonisolated(unsafe) private static var isRefreshing = false

    /// Only for a widget on the Home Screen: without one, no photos are copied out of the app.
    static func refreshIfStale(client: ImmichClient) async {
        guard let widgets = try? await WidgetCenter.shared.currentConfigurations(), !widgets.isEmpty else { return }
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
