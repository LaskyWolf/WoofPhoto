import SwiftUI

/// Endpoints behind tags, folders and Search's structured filters (Immich 3.2+).
extension ImmichClient {
    // MARK: Tags

    func tags() async throws -> [AssetTag] {
        try await get("/tags")
    }

    /// Creates "Trips/Japan" and any missing parent, and returns the innermost tag.
    func createTag(_ path: String) async throws -> AssetTag? {
        let made: [AssetTag] = try await fetch("PUT", "/tags", body: ["tags": [path]])
        return made.last
    }

    /// Renames the last part of the path; a name can't contain "/".
    func renameTag(_ id: String, to name: String) async throws {
        try await call("PUT", "/tags/\(id)", body: ["name": name])
    }

    /// The photos keep existing; the server also deletes the tags inside this one.
    func deleteTag(_ id: String) async throws {
        try await call("DELETE", "/tags/\(id)")
    }

    func tag(_ id: String, assets: [String]) async throws {
        try await call("PUT", "/tags/\(id)/assets", body: ["ids": assets])
    }

    func untag(_ id: String, assets: [String]) async throws {
        try await call("DELETE", "/tags/\(id)/assets", body: ["ids": assets])
    }

    /// `GET /assets/{id}` carries the tags, which `Asset` leaves out.
    func assetTags(_ id: String) async throws -> [AssetTag] {
        struct Tagged: Decodable { var tags: [AssetTag]? }
        let asset: Tagged = try await get("/assets/\(id)")
        return asset.tags ?? []
    }

    // MARK: Folders

    /// Every folder that directly holds assets, as the server stores the path.
    func folderPaths() async throws -> [String] {
        try await get("/view/folder/unique-paths")
    }

    func folderAssets(_ path: String) async throws -> [Asset] {
        try await get("/view/folder", query: ["path": path])
    }

    // MARK: Search v2

    /// Every asset matching a structured `filter`, newest first, page by page with the server's cursor.
    /// The flat fields of `searchMetadata` can't be sent together with `filter`.
    func searchAssets(filter: [String: Any], limit: Int = 2000) async throws -> [Asset] {
        var assets: [Asset] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": filter, "size": 1000, "withExif": false]
            if let cursor { body["cursor"] = cursor }
            let response: FilteredSearch = try await fetch("POST", "/search/metadata", body: body)
            assets += response.assets.items
            cursor = response.assets.nextCursor
        } while cursor != nil && assets.count < limit
        return assets
    }

    /// The assets that best match a description among those matching `filter`, most similar first.
    /// Smart search has no cursor, so this is one page.
    func searchAssets(matching text: String, filter: [String: Any], limit: Int = 300) async throws -> [Asset] {
        let response: FilteredSearch = try await fetch("POST", "/search/smart",
                                                       body: ["query": text, "filter": filter, "size": min(limit, 1000), "withExif": false])
        return response.assets.items
    }

    /// Values the server has seen: type is country, state, city, camera-make, camera-model or camera-lens-model.
    /// `parents` narrows them, such as ["country": "Italy"] for states.
    func suggestions(_ type: String, _ parents: [String: String] = [:]) async throws -> [String] {
        let values: [String?] = try await get("/search/suggestions", query: parents.filter { !$0.value.isEmpty }.merging(["type": type]) { $1 })
        return values.compactMap { $0 }.filter { !$0.isEmpty }
    }
}

private struct FilteredSearch: Decodable {
    var assets: Page

    struct Page: Decodable {
        var items: [Asset]
        var nextCursor: String?
    }
}

extension TimelineQuery {
    static func tag(_ id: String) -> TimelineQuery { TimelineQuery(params: ["tagId": id, "visibility": "timeline"]) }
}

/// One Immich tag. `value` is the whole path, such as "Trips/Japan"; `name` its last part.
struct AssetTag: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var value: String?
    var color: String?
    var parentId: String?

    var path: String { value ?? name ?? "" }
    var parts: [String] { path.split(separator: "/").map(String.init) }
    var title: String { name ?? parts.last ?? "Untitled" }
    var depth: Int { max(parts.count - 1, 0) }

    /// The server's "#RRGGBB", or grey.
    var tint: Color {
        guard let hex = color?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), hex.count == 6,
              let rgb = Int(hex, radix: 16) else { return .gray }
        return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// Parents right before their children, each level in name order.
    static func tree(_ tags: [AssetTag]) -> [AssetTag] {
        tags.sorted { $0.parts.lexicographicallyPrecedes($1.parts) { $0.localizedStandardCompare($1) == .orderedAscending } }
    }
}

/// A tag in the tree: indented under its parent, in its colour, with a checkmark when chosen.
struct TagRow: View {
    let tag: AssetTag
    var checked = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag.fill").foregroundStyle(tag.tint)
            Text(tag.title).foregroundStyle(.primary)
            Spacer()
            if checked { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
        }
        .padding(.leading, CGFloat(tag.depth) * 20)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag.path)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// Settings > Immich > Tags, saved on the server. Off by default, as in Immich.
@MainActor func tagsEnabled(_ client: ImmichClient?) async -> Bool {
    let prefs = ServerPreferences()
    await prefs.load(client)
    return prefs.value("tags", "enabled", default: false)
}

// MARK: - Tags page

/// Tags: every tag as an indented tree. Open one for its photos, swipe to rename or delete, + to create.
struct TagsView: View {
    @Environment(Session.self) private var session
    @State private var tags: [AssetTag]?
    @State private var error: String?
    @State private var creating = false
    @State private var renaming: AssetTag?
    @State private var deleting: AssetTag?
    @State private var name = ""
    @State private var message: String?

    var body: some View {
        Group {
            if let tags {
                List(AssetTag.tree(tags)) { tag in
                    NavigationLink {
                        TimelineScreen(title: tag.title, query: .tag(tag.id))
                    } label: {
                        TagRow(tag: tag)
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag }
                        Button("Rename", systemImage: "pencil") {
                            name = tag.title
                            renaming = tag
                        }
                    }
                }
                .overlay {
                    if tags.isEmpty {
                        ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Tap + to make one, or tag photos from their menu."))
                    }
                }
                .refreshable { await load() }
            } else if let error {
                ContentUnavailableView("Can't Load Tags", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            Button("New Tag", systemImage: "plus") {
                name = ""
                creating = true
            }
        }
        .alert("New Tag", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") { Task { await perform { _ = try await $0.createTag(name) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use / for a tag inside another, for example Trips/Japan.")
        }
        .alert("Rename Tag", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }, presenting: renaming) { tag in
            TextField("Name", text: $name)
            Button("Rename") { Task { await perform { try await $0.renameTag(tag.id, to: name) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("The photos stay; tags inside this one are deleted too.",
                            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                            titleVisibility: .visible, presenting: deleting) { tag in
            Button("Delete \(tag.title)", role: .destructive) { Task { await perform { try await $0.deleteTag(tag.id) } } }
        }
        .messageAlert($message)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            tags = try await client.tags()
            error = nil
        } catch {
            self.error = error.explanation
        }
    }

    /// Runs a change, then shows the server's tags again.
    private func perform(_ change: (ImmichClient) async throws -> Void) async {
        guard let client = session.client else { return }
        do {
            try await change(client)
        } catch {
            message = error.explanation
        }
        await load()
    }
}

// MARK: - Tag picker

/// "Tag…": checks the tags every given asset has. Tapping one adds it to all of them, or takes it off.
struct TagPicker: View {
    let assetIDs: [String]

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [AssetTag]?
    @State private var applied: Set<String> = []
    @State private var enabled = true
    @State private var newTag = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !enabled {
                    ContentUnavailableView("Tags Are Off", systemImage: "tag.slash", description: Text("Turn them on in Settings > Immich."))
                } else if let tags {
                    List {
                        Section {
                            TextField("New Tag, for example Trips/Japan", text: $newTag)
                                .submitLabel(.done)
                                .onSubmit { Task { await create() } }
                        }
                        Section {
                            ForEach(AssetTag.tree(tags)) { tag in
                                Button { Task { await toggle(tag) } } label: { TagRow(tag: tag, checked: applied.contains(tag.id)) }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(assetIDs.count == 1 ? "Tags" : "Tag \(assetIDs.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", role: .confirm) { dismiss() } }
            .messageAlert($error)
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let client = session.client else { return }
        enabled = await tagsEnabled(client)
        guard enabled else { return }
        do {
            tags = try await client.tags()
            // ponytail: one request per asset, so a big selection starts unchecked; a bulk endpoint would lift the cap
            guard assetIDs.count <= 50 else { return }
            let sets = try await withThrowingTaskGroup(of: Set<String>.self) { group in
                for id in assetIDs { group.addTask { try await Set(client.assetTags(id).map(\.id)) } }
                return try await group.reduce(into: [Set<String>]()) { $0.append($1) }
            }
            applied = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
        } catch {
            tags = tags ?? []
            self.error = error.explanation
        }
    }

    private func toggle(_ tag: AssetTag) async {
        guard let client = session.client else { return }
        let removes = applied.contains(tag.id)
        do {
            if removes {
                try await client.untag(tag.id, assets: assetIDs)
                applied.remove(tag.id)
            } else {
                try await client.tag(tag.id, assets: assetIDs)
                applied.insert(tag.id)
            }
        } catch {
            self.error = error.explanation
        }
    }

    private func create() async {
        let path = newTag.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let client = session.client else { return }
        do {
            if let tag = try await client.createTag(path) {
                try await client.tag(tag.id, assets: assetIDs)
                applied.insert(tag.id)
            }
            newTag = ""
            tags = try await client.tags()
        } catch {
            self.error = error.explanation
        }
    }
}

/// Search's tag filter: every tag as a tree, with a checkmark on the chosen ones.
struct TagChecklist: View {
    let tags: [AssetTag]
    @Binding var selection: [AssetTag]

    var body: some View {
        List(AssetTag.tree(tags)) { tag in
            let index = selection.firstIndex { $0.id == tag.id }
            Button {
                if let index { selection.remove(at: index) } else { selection.append(tag) }
            } label: {
                TagRow(tag: tag, checked: index != nil)
            }
        }
        .overlay { if tags.isEmpty { ContentUnavailableView("No Tags", systemImage: "tag") } }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The viewer's details: the photo's tags in a card; tapping opens the tag picker. Nothing while tags are off.
struct AssetTagsCard: View {
    let assetID: String

    @Environment(Session.self) private var session
    @State private var tags: [AssetTag]?
    @State private var picks = false

    var body: some View {
        if let tags {
            Button { picks = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Tags", systemImage: "tag").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Text(tags.isEmpty ? "Add a tag" : AssetTag.tree(tags).map(\.path).joined(separator: ", "))
                        .foregroundStyle(tags.isEmpty ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.cardRadius))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit tags")
            .sheet(isPresented: $picks, onDismiss: { Task { await load() } }) { TagPicker(assetIDs: [assetID]) }
        } else {
            Color.clear.frame(height: 0).task(id: assetID) { await load() }
        }
    }

    private func load() async {
        guard let client = session.client, await tagsEnabled(client) else { return }
        tags = (try? await client.assetTags(assetID)) ?? []
    }
}

// MARK: - Folders

/// Folders: the server's folder tree one level per page, with the photos of the open folder under its subfolders.
struct FoldersView: View {
    /// "photos/2024/Trip" without leading or trailing slashes; empty at the top.
    var key = ""
    /// Each key with the path as the server spells it. Loaded by the top page and handed down.
    var paths: [String: String]?

    @Environment(Session.self) private var session
    @State private var loaded: [String: String]?
    @State private var timeline: Timeline?
    @State private var error: String?

    var body: some View {
        Group {
            if let timeline, let all = paths ?? loaded {
                AssetGrid(timeline: timeline, hero: AnyView(subfolders(all)))
            } else if let error {
                ContentUnavailableView("Can't Load Folders", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(key.isEmpty ? "Folders" : String(key.split(separator: "/").last ?? ""))
        .task { await load() }
    }

    /// Rows like Media Types: a folder icon, the name and a chevron.
    @ViewBuilder private func subfolders(_ all: [String: String]) -> some View {
        let children = Self.children(of: key, in: all.keys)
        if !children.isEmpty {
            VStack(spacing: 0) {
                ForEach(children, id: \.self) { child in
                    NavigationLink {
                        FoldersView(key: key.isEmpty ? child : key + "/" + child, paths: all)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint).frame(width: 32, height: 32)
                            Text(child).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if child != children.last { Divider().padding(.leading, 56) }
                }
            }
            .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.cardRadius))
            .padding(.horizontal, Tokens.screenPadding)
            .padding(.vertical, 12)
        }
    }

    /// The names one level under `key`, from every folder path below it.
    static func children(of key: String, in keys: some Sequence<String>) -> [String] {
        let prefix = key.isEmpty ? "" : key + "/"
        let names = keys.filter { $0.count > prefix.count && $0.hasPrefix(prefix) }
            .compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    #if DEBUG
    static func selfCheck() {
        let keys = ["a/b", "a/b/c", "a/d", "ab/e", "x"]
        assert(children(of: "", in: keys) == ["a", "ab", "x"])
        assert(children(of: "a", in: keys) == ["b", "d"])
        assert(children(of: "a/b", in: keys) == ["c"])
        assert(children(of: "x", in: keys).isEmpty)
    }
    #endif

    private func load() async {
        guard timeline == nil, let client = session.client else { return }
        do {
            var all = paths
            if all == nil {
                let list = try await client.folderPaths()
                // "/mnt/photos/" and "mnt/photos" are the same folder in the tree
                all = Dictionary(list.map { ($0.split(separator: "/").joined(separator: "/"), $0) }) { first, _ in first }
                loaded = all
            }
            var assets: [Asset] = []
            if let path = all?[key] { assets = try await client.folderAssets(path) }
            timeline = Timeline(assets: assets.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }.map(\.ref))
        } catch {
            self.error = error.explanation
        }
    }
}
