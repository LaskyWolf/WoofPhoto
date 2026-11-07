import SwiftUI

/// All albums, or all shared albums, as a two-column grid of covers.
struct AlbumsView: View {
    let shared: Bool

    @Environment(Session.self) private var session
    @State private var albums: [Album]?
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums ?? []) { AlbumTile(album: $0, size: nil) { Task { await load() } } }
            }
            .padding()
        }
        .overlay {
            if albums == nil, error == nil { ProgressView() }
            if let error { ContentUnavailableView("Can't Load Albums", systemImage: "exclamationmark.triangle", description: Text(error)) }
            if albums?.isEmpty == true { ContentUnavailableView(shared ? "No Shared Albums" : "No Albums", systemImage: "rectangle.stack") }
        }
        .navigationTitle(shared ? "Shared Albums" : "Albums")
        .toolbar {
            Button("New Album", systemImage: "plus") { naming = true }
        }
        .alert("New Album", isPresented: $naming) {
            TextField("Title", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Save") { Task { await create() } }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            albums = try await session.client?.albums().filter { ($0.shared == true) == shared }
                .sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
        } catch {
            self.error = error.explanation
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        do {
            _ = try await session.client?.createAlbum(name)
            await load()
        } catch {
            self.error = error.explanation
        }
    }
}

/// An album's cover, name and count. Long press to rename or delete.
struct AlbumTile: View {
    let album: Album
    /// Fixed width in a row; nil fills a grid column.
    var size: CGFloat? = 150
    /// WoofMusic's list layout: a small cover beside the name.
    var isRow = false
    var onChange: () -> Void = {}

    @Environment(Session.self) private var session
    @Environment(\.shelfZoom) private var shelfZoom
    /// The newest photo, for an album without a key photo (often one shared with you).
    @State private var firstPhoto: String?
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmsDelete = false
    @State private var sharesLink = false
    @State private var error: String?

    var body: some View {
        let cover = (album.albumThumbnailAssetId ?? firstPhoto).map { AssetRef(id: $0) }
        let shelf = Shelf.album(id: album.id, name: album.albumName)
        NavigationLink(value: shelf) {
            if isRow {
                HStack(spacing: 14) {
                    Thumbnail(asset: cover, size: "preview", cornerRadius: Tokens.tileRadius)
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.albumName).font(.headline).lineLimit(2)
                        Text("\((album.assetCount ?? 0).formatted()) items").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Thumbnail(asset: cover, size: "preview", cornerRadius: Tokens.tileRadius)
                        .frame(width: size)
                    Text(album.albumName).font(.subheadline).lineLimit(1)
                    Text((album.assetCount ?? 0).formatted()).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(width: size)
            }
        }
        .buttonStyle(.plain)
        .zoomSource(shelf, in: shelfZoom)
        .task {
            guard album.albumThumbnailAssetId == nil, firstPhoto == nil, let client = session.client else { return }
            firstPhoto = try? await client.firstAssets(["albumIds": [album.id]], count: 1).first?.id
        }
        .liftedMenu {
            Button("Rename", systemImage: "pencil") {
                name = album.albumName
                renaming = true
            }
            Button("Share Link…", systemImage: "link") { sharesLink = true }
            Button("Delete Album", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .sheet(isPresented: $sharesLink) { SharedLinkEditor(albumID: album.id) }
        .alert("Rename Album", isPresented: $renaming) {
            TextField("Title", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    do { try await session.client?.updateAlbum(album.id, ["albumName": name]) } catch { self.error = error.explanation }
                    onChange()
                }
            }
        }
        .confirmationDialog("The photos stay in your library.", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                Task {
                    do { try await session.client?.deleteAlbum(album.id) } catch { self.error = error.explanation }
                    onChange()
                }
            }
        }
        .messageAlert($error)
    }
}

/// One album's photos, with rename, delete, sharing and the activity of a shared album.
struct AlbumView: View {
    let id: String

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var album: Album?
    @State private var timeline: Timeline
    @State private var renaming = false
    @State private var newName = ""
    @State private var showsActivity = false
    @State private var sharesLink = false
    @State private var showsMembers = false
    @State private var confirmsDelete = false
    @State private var playsSlideshow = false
    @State private var slideshow: [AssetRef] = []
    @State private var error: String?

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
        _timeline = State(initialValue: Timeline(.album(id)))
    }

    var body: some View {
        AssetGrid(timeline: timeline, hero: AnyView(hero))
            .detailBarTitle(name)
            .alert("Rename Album", isPresented: $renaming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    Task {
                        do {
                            try await session.client?.updateAlbum(id, ["albumName": newName])
                            name = newName
                        } catch {
                            self.error = error.explanation
                        }
                    }
                }
            }
            .confirmationDialog("The photos stay in your library.", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) {
                    Task {
                        do {
                            try await session.client?.deleteAlbum(id)
                            dismiss()
                        } catch {
                            self.error = error.explanation
                        }
                    }
                }
            }
            .sheet(isPresented: $showsActivity) { ActivitySheet(album: id) }
            .sheet(isPresented: $sharesLink) { SharedLinkEditor(albumID: id) }
            // the header says Shared Album once someone is added
            .sheet(isPresented: $showsMembers, onDismiss: { Task { album = try? await session.client?.album(id) } }) {
                AlbumMembersView(album: id)
            }
            .messageAlert($error)
            .fullScreenCover(isPresented: $playsSlideshow) { Slideshow(assets: slideshow, start: 0) }
            .task { album = try? await session.client?.album(id) }
    }

    /// WoofMusic's album header: cover, kind line, title, count, then More, Shuffle and Play.
    private var hero: some View {
        DetailHeader(meta: meta, title: name) {
            Thumbnail(asset: album?.albumThumbnailAssetId.map { AssetRef(id: $0) }, size: "preview", square: false)
        } secondary: {
            if timeline.months != nil {
                Text("\(timeline.count.formatted()) Items").font(.subheadline).foregroundStyle(.secondary)
            }
        } buttons: {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newName = name
                    renaming = true
                }
                Section {
                    Button("Share Link…", systemImage: "link") { sharesLink = true }
                    Button("Shared With…", systemImage: "person.2") { showsMembers = true }
                }
                if album?.shared == true || album?.isActivityEnabled == true {
                    Button("Activity", systemImage: "bubble.left.and.bubble.right") { showsActivity = true }
                }
                Button("Delete Album", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            } label: {
                RoundIcon(systemImage: "ellipsis")
            }
            .accessibilityLabel("More")
            if !timeline.assets.isEmpty {
                Button { play(timeline.assets.shuffled()) } label: { RoundIcon(systemImage: "shuffle") }
                    .accessibilityLabel("Shuffle Slideshow")
                Button { play(timeline.assets) } label: { RoundIcon(systemImage: "play.fill", filled: true) }
                    .accessibilityLabel("Play Slideshow")
            }
        }
    }

    private func play(_ assets: [AssetRef]) {
        slideshow = assets
        playsSlideshow = true
    }

    /// "Album · Jun – Aug 2026", like WoofMusic's "Album · 2024".
    private var meta: String {
        var range: String?
        if let start = album?.startDate.flatMap({ Date(immich: $0) }), let end = album?.endDate.flatMap({ Date(immich: $0) }) {
            range = (start..<max(start, end)).formatted(.interval.month(.abbreviated).year())
        }
        return [album?.shared == true ? "Shared Album" : "Album", range].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Likes and comments on a shared album.
struct ActivitySheet: View {
    let album: String

    @Environment(Session.self) private var session
    @State private var activities: [Activity] = []
    @State private var me: User?
    @State private var comment = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(activities.filter { $0.assetId == nil }) { activity in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.user.name).font(.subheadline.bold())
                        if let comment = activity.comment {
                            Text(comment)
                        } else {
                            Label("Liked this album", systemImage: "heart.fill").foregroundStyle(.pink)
                        }
                    }
                    .swipeActions {
                        if activity.user.id == me?.id {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    try? await session.client?.deleteActivity(activity.id)
                                    await load()
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if activities.isEmpty, error == nil { ContentUnavailableView("No Activity", systemImage: "bubble.left.and.bubble.right") }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(myLike == nil ? "Like" : "Unlike", systemImage: myLike == nil ? "heart" : "heart.fill") {
                        Task { await toggleLike() }
                    }
                    .labelStyle(.iconOnly)
                    .tint(.pink)
                    TextField("Add a Comment", text: $comment)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await send() } }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
    }

    private var myLike: Activity? { activities.first { $0.type == "like" && $0.assetId == nil && $0.user.id == me?.id } }

    private func load() async {
        guard let client = session.client else { return }
        do {
            if me == nil { me = try await client.me() }
            activities = try await client.activities(album: album)
        } catch {
            self.error = error.explanation
        }
    }

    private func send() async {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        comment = ""
        try? await session.client?.addActivity(album: album, comment: text)
        await load()
    }

    private func toggleLike() async {
        if let myLike {
            try? await session.client?.deleteActivity(myLike.id)
        } else {
            try? await session.client?.addActivity(album: album, comment: nil)
        }
        await load()
    }
}

/// Picks an album, or creates one, to add assets to.
struct AlbumPicker: View {
    let assets: [String]
    var onDone: (String) -> Void = { _ in }

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                Button("New Album…", systemImage: "plus") { naming = true }
                ForEach(albums) { album in
                    Button {
                        Task { await add(to: album) }
                    } label: {
                        HStack {
                            Thumbnail(asset: album.albumThumbnailAssetId.map { AssetRef(id: $0) })
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(album.albumName)
                                Text((album.assetCount ?? 0).formatted()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .alert("New Album", isPresented: $naming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await create() } }
            }
        }
        .task {
            albums = (try? await session.client?.albums())?
                .sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending } ?? []
        }
    }

    private func add(to album: Album) async {
        do {
            try await session.client?.addToAlbum(album.id, assets: assets)
            onDone(album.albumName)
            dismiss()
        } catch {
            self.error = error.explanation
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try await session.client?.createAlbum(name, assets: assets)
            onDone(name)
            dismiss()
        } catch {
            self.error = error.explanation
        }
    }
}
