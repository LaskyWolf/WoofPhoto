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

/// An album's cover, name and count. Long press to rename, pin or delete.
struct AlbumTile: View {
    let album: Album
    /// Fixed width in a row; nil fills a grid column.
    var size: CGFloat? = 150
    var onChange: () -> Void = {}

    @Environment(Session.self) private var session
    @Environment(Pins.self) private var pins
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmsDelete = false

    var body: some View {
        NavigationLink(value: Shelf.album(id: album.id, name: album.albumName)) {
            VStack(alignment: .leading, spacing: 2) {
                Thumbnail(asset: album.albumThumbnailAssetId.map { AssetRef(id: $0) }, size: "preview")
                    .frame(width: size)
                    .clipShape(.rect(cornerRadius: 12))
                Text(album.albumName).font(.subheadline).lineLimit(1)
                Text((album.assetCount ?? 0).formatted()).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                name = album.albumName
                renaming = true
            }
            let shelf = Shelf.album(id: album.id, name: album.albumName)
            Button(pins.contains(shelf) ? "Unpin" : "Pin", systemImage: "pin") { pins.toggle(shelf) }
            Button("Delete Album", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .alert("Rename Album", isPresented: $renaming) {
            TextField("Title", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    try? await session.client?.updateAlbum(album.id, ["albumName": name])
                    onChange()
                }
            }
        }
        .confirmationDialog("The photos stay in your library.", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                Task {
                    try? await session.client?.deleteAlbum(album.id)
                    onChange()
                }
            }
        }
    }
}

/// One album's photos, with rename, delete and the activity of a shared album.
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
    @State private var confirmsDelete = false

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
        _timeline = State(initialValue: Timeline(.album(id)))
    }

    var body: some View {
        AssetGrid(timeline: timeline)
            .navigationTitle(name)
            .navigationSubtitle(timeline.months == nil ? "" : "\(timeline.count.formatted()) Items")
            .toolbar {
                if album?.shared == true || album?.isActivityEnabled == true {
                    Button("Activity", systemImage: "bubble.left.and.bubble.right") { showsActivity = true }
                }
                Menu("More", systemImage: "ellipsis") {
                    Button("Rename", systemImage: "pencil") {
                        newName = name
                        renaming = true
                    }
                    Button("Delete Album", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
            }
            .alert("Rename Album", isPresented: $renaming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    Task {
                        try? await session.client?.updateAlbum(id, ["albumName": newName])
                        name = newName
                    }
                }
            }
            .confirmationDialog("The photos stay in your library.", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) {
                    Task {
                        try? await session.client?.deleteAlbum(id)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showsActivity) { ActivitySheet(album: id) }
            .task { album = try? await session.client?.album(id) }
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
