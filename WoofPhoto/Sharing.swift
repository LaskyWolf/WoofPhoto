import SwiftUI

/// Endpoints behind sharing: public links, and the people an album is shared with.
extension ImmichClient {
    // MARK: Shared links

    func sharedLinks() async throws -> [SharedLink] {
        try await get("/shared-links")
    }

    /// An album link when `album` is set, else a link to `assets`. type, albumId and assetIds are added here.
    func createSharedLink(album: String?, assets: [String], _ fields: [String: Any]) async throws -> SharedLink {
        var body = fields
        if let album {
            body["type"] = "ALBUM"
            body["albumId"] = album
        } else {
            body["type"] = "INDIVIDUAL"
            body["assetIds"] = assets
        }
        return try await fetch("POST", "/shared-links", body: body)
    }

    /// description, expiresAt, password (NSNull clears them), allowDownload, allowUpload, showMetadata.
    func updateSharedLink(_ id: String, _ fields: [String: Any]) async throws -> SharedLink {
        try await fetch("PATCH", "/shared-links/\(id)", body: fields)
    }

    func deleteSharedLink(_ id: String) async throws {
        try await call("DELETE", "/shared-links/\(id)")
    }

    /// Where links point: the server's External Domain setting when the admin set one, since the app's own
    /// address may be a LAN or VPN one that people outside can't open.
    func sharedLinkBase() async -> URL {
        struct Config: Decodable { var externalDomain: String? }
        let config: Config? = try? await get("/server/config")
        if let domain = config?.externalDomain, !domain.isEmpty, let url = URL(string: domain) { return url }
        return server
    }

    // MARK: Album users

    func albumMembers(_ id: String) async throws -> AlbumMembers {
        try await get("/albums/\(id)")
    }

    /// Every user on the server, to share an album with.
    func users() async throws -> [User] {
        try await get("/users")
    }

    /// role: "viewer" or "editor".
    func addAlbumUsers(_ album: String, _ users: [String], role: String) async throws {
        try await call("PUT", "/albums/\(album)/users", body: ["albumUsers": users.map { ["userId": $0, "role": role] }])
    }

    func setAlbumUserRole(_ album: String, user: String, role: String) async throws {
        try await call("PUT", "/albums/\(album)/user/\(user)", body: ["role": role])
    }

    func removeAlbumUser(_ album: String, user: String) async throws {
        try await call("DELETE", "/albums/\(album)/user/\(user)")
    }
}

struct SharedLink: Decodable, Identifiable {
    var id: String
    var key: String?
    var slug: String?
    var type: String?
    var description: String?
    var password: String?
    var expiresAt: String?
    var allowDownload: Bool?
    var allowUpload: Bool?
    var showMetadata: Bool?
    var album: Album?
    var assets: [Asset]?

    /// The web app's addresses: /s/<slug> for a custom slug, else /share/<key>.
    func url(base: URL) -> URL {
        if let slug, !slug.isEmpty { return base.appending(path: "s/\(slug)") }
        return base.appending(path: "share/\(key ?? "")")
    }

    var title: String {
        if let name = album?.albumName { return name }
        if let description, !description.isEmpty { return description }
        let count = assets?.count ?? 0
        return count == 1 ? "1 Item" : "\(count) Items"
    }

    var isExpired: Bool { expiresAt.flatMap(Date.init(immich:)).map { $0 < .now } ?? false }
}

/// An album's owner and members. Immich 3.3 sends the owner apart; newer servers list it in albumUsers as "owner".
struct AlbumMembers: Decodable {
    var ownerId: String?
    var owner: User?
    var albumUsers: [AlbumMember]?

    var ownerID: String? { ownerId ?? owner?.id ?? albumUsers?.first { $0.role == "owner" }?.user.id }

    /// The owner first.
    var everyone: [AlbumMember] {
        var members = albumUsers ?? []
        if let owner, !members.contains(where: { $0.user.id == owner.id }) {
            members.insert(AlbumMember(user: owner, role: "owner"), at: 0)
        }
        return members.sorted { ($0.role == "owner" ? 0 : 1) < ($1.role == "owner" ? 0 : 1) }
    }
}

struct AlbumMember: Decodable, Identifiable {
    var user: User
    var role: String?
    var id: String { user.id }
}

// MARK: Shared links

/// Every public link the user made: tap to edit, swipe to delete, long press to copy or share.
struct SharedLinksView: View {
    @Environment(Session.self) private var session
    @State private var links: [SharedLink]?
    @State private var base: URL?
    @State private var editing: SharedLink?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(links ?? []) { link in
                let url = base.map { link.url(base: $0) }
                Button { editing = link } label: { SharedLinkRow(link: link, url: url) }
                    .buttonStyle(.plain)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete(link) } }
                    }
                    .contextMenu {
                        if let url {
                            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                            ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await delete(link) } }
                    }
            }
        }
        .overlay {
            if links == nil, error == nil { ProgressView() }
            if links?.isEmpty == true {
                ContentUnavailableView("No Shared Links", systemImage: "link",
                                       description: Text("Share Link in an album's or a photo's menu makes one."))
            }
        }
        .navigationTitle("Shared Links")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .sheet(item: $editing) { SharedLinkEditor(link: $0) { Task { await load() } } }
        .messageAlert($error)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            if base == nil { base = await client.sharedLinkBase() }
            links = try await client.sharedLinks()
        } catch {
            self.error = error.explanation
        }
    }

    private func delete(_ link: SharedLink) async {
        do {
            try await session.client?.deleteSharedLink(link.id)
            links?.removeAll { $0.id == link.id }
        } catch {
            self.error = error.explanation
        }
    }
}

/// A link's cover, title, address and expiry.
private struct SharedLinkRow: View {
    let link: SharedLink
    let url: URL?

    var body: some View {
        HStack {
            Thumbnail(asset: (link.album?.albumThumbnailAssetId ?? link.assets?.first?.id).map { AssetRef(id: $0) })
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title).lineLimit(1)
                if let url { Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if link.isExpired {
                    Text("Expired").font(.footnote).foregroundStyle(.red)
                } else if let date = link.expiresAt.flatMap(Date.init(immich:)) {
                    Text("Expires \(date.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if link.password?.isEmpty == false { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
        }
        .contentShape(.rect)
    }
}

/// Makes a public link to an album or some photos, or edits one. After Create it stays open with the link to copy or share.
struct SharedLinkEditor: View {
    var albumID: String?
    var assets: [String] = []
    var onSave: () -> Void = {}

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var link: SharedLink?
    @State private var url: URL?
    @State private var description: String
    @State private var expires: Bool
    @State private var expiresAt: Date
    @State private var password: String
    @State private var allowDownload: Bool
    @State private var allowUpload: Bool
    @State private var showMetadata: Bool
    @State private var saving = false
    @State private var error: String?

    init(albumID: String? = nil, assets: [String] = [], link: SharedLink? = nil, onSave: @escaping () -> Void = {}) {
        self.albumID = albumID
        self.assets = assets
        self.onSave = onSave
        let expiry = link?.expiresAt.flatMap(Date.init(immich:))
        _link = State(initialValue: link)
        _description = State(initialValue: link?.description ?? "")
        _expires = State(initialValue: expiry != nil)
        _expiresAt = State(initialValue: expiry ?? .now.addingTimeInterval(7 * 86400))
        _password = State(initialValue: link?.password ?? "")
        _allowDownload = State(initialValue: link?.allowDownload ?? true)
        _allowUpload = State(initialValue: link?.allowUpload ?? false)
        _showMetadata = State(initialValue: link?.showMetadata ?? true)
    }

    private var isAlbum: Bool { albumID != nil || link?.type == "ALBUM" }

    var body: some View {
        NavigationStack {
            Form {
                if let url {
                    Section {
                        Text(url.absoluteString).font(.callout).textSelection(.enabled)
                        Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                        ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    }
                }
                Section {
                    TextField("Description", text: $description)
                }
                Section {
                    Toggle("Expires", isOn: $expires.animation())
                    if expires {
                        DatePicker("Expires On", selection: $expiresAt, displayedComponents: [.date, .hourAndMinute])
                    }
                    SecureField("Password (Optional)", text: $password)
                }
                Section {
                    Toggle("Allow Download", isOn: $allowDownload)
                    if isAlbum { Toggle("Allow Upload", isOn: $allowUpload) }
                    Toggle("Show Metadata", isOn: $showMetadata)
                } footer: {
                    Text("Anyone with the link can see \(isAlbum ? "this album" : "these photos") without an Immich account.")
                }
            }
            .disabled(saving)
            .navigationTitle(link == nil ? "New Shared Link" : "Shared Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(link == nil ? "Cancel" : "Done", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(link == nil ? "Create" : "Save") { Task { await save() } }
                }
            }
        }
        .messageAlert($error)
        .task {
            if let link, let client = session.client { url = link.url(base: await client.sharedLinkBase()) }
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        saving = true
        defer { saving = false }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: Any] = ["allowDownload": allowDownload, "showMetadata": showMetadata]
        if isAlbum { fields["allowUpload"] = allowUpload }
        do {
            if let link {
                // NSNull clears a field the user emptied
                fields["description"] = text.isEmpty ? NSNull() : text
                fields["password"] = password.isEmpty ? NSNull() : password
                fields["expiresAt"] = expires ? expiresAt.formatted(.iso8601) : NSNull()
                _ = try await client.updateSharedLink(link.id, fields)
                onSave()
                dismiss()
            } else {
                if !text.isEmpty { fields["description"] = text }
                if !password.isEmpty { fields["password"] = password }
                if expires { fields["expiresAt"] = expiresAt.formatted(.iso8601) }
                let created = try await client.createSharedLink(album: albumID, assets: assets, fields)
                link = created
                url = created.url(base: await client.sharedLinkBase())
                onSave()
            }
        } catch {
            self.error = error.explanation
        }
    }
}

// MARK: Album users

/// Who an album is shared with and their role. The owner adds people, changes roles and removes them; others only see the list.
struct AlbumMembersView: View {
    let album: String

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var members: AlbumMembers?
    @State private var me: User?
    @State private var error: String?

    private var isOwner: Bool { me != nil && members?.ownerID == me?.id }

    var body: some View {
        NavigationStack {
            List {
                ForEach(members?.everyone ?? []) { member in
                    if isOwner, member.role != "owner" {
                        Picker(selection: Binding { member.role ?? "viewer" } set: { role in Task { await setRole(member, role) } }) {
                            Text("Viewer").tag("viewer")
                            Text("Editor").tag("editor")
                        } label: {
                            UserLabel(user: member.user)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Remove", systemImage: "person.badge.minus", role: .destructive) { Task { await remove(member) } }
                        }
                    } else {
                        LabeledContent {
                            Text(member.role?.capitalized ?? "Viewer")
                        } label: {
                            UserLabel(user: member.user)
                        }
                    }
                }
                if isOwner {
                    NavigationLink {
                        AlbumUserPicker(excluded: Set(members?.everyone.map(\.id) ?? [])) { users, role in
                            Task { await add(users, role: role) }
                        }
                    } label: {
                        Label("Add People", systemImage: "person.badge.plus")
                    }
                }
            }
            .overlay { if members == nil, error == nil { ProgressView() } }
            .navigationTitle("Shared With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .messageAlert($error)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            if me == nil { me = try await client.me() }
            members = try await client.albumMembers(album)
        } catch {
            self.error = error.explanation
        }
    }

    private func perform(_ action: (ImmichClient) async throws -> Void) async {
        guard let client = session.client else { return }
        do {
            try await action(client)
        } catch {
            self.error = error.explanation
        }
        await load()
    }

    private func add(_ users: [String], role: String) async {
        await perform { try await $0.addAlbumUsers(album, users, role: role) }
    }

    private func setRole(_ member: AlbumMember, _ role: String) async {
        await perform { try await $0.setAlbumUserRole(album, user: member.id, role: role) }
    }

    private func remove(_ member: AlbumMember) async {
        await perform { try await $0.removeAlbumUser(album, user: member.id) }
    }
}

/// Every server user not already in the album; tap one to add them as a viewer or an editor.
private struct AlbumUserPicker: View {
    let excluded: Set<String>
    let onAdd: ([String], String) -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var users: [User]?
    @State private var error: String?

    var body: some View {
        List {
            ForEach((users ?? []).filter { !excluded.contains($0.id) }) { user in
                Menu {
                    Button("Add as Viewer", systemImage: "eye") { add(user, role: "viewer") }
                    Button("Add as Editor", systemImage: "pencil") { add(user, role: "editor") }
                } label: {
                    UserLabel(user: user).contentShape(.rect)
                }
                .tint(.primary)
            }
        }
        .overlay {
            if users == nil, error == nil { ProgressView() }
            if let users, users.allSatisfy({ excluded.contains($0.id) }) {
                ContentUnavailableView("No One to Add", systemImage: "person.2", description: Text("Everyone on this server already has this album."))
            }
        }
        .navigationTitle("Add People")
        .navigationBarTitleDisplayMode(.inline)
        .messageAlert($error)
        .task {
            do { users = try await session.client?.users() } catch { self.error = error.explanation }
        }
    }

    private func add(_ user: User, role: String) {
        onAdd([user.id], role)
        dismiss()
    }
}

/// A user's name and email beside a person icon.
private struct UserLabel: View {
    let user: User

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                if let email = user.email { Text(email).font(.footnote).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
        }
    }
}
