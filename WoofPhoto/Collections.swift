import MapKit
import SwiftUI

/// Everything the Collections tab can open, and what Pinned stores.
enum Shelf: Hashable, Codable {
    case favorites, recentlySaved, map
    case videos, livePhotos, selfies, portraits, panoramas, screenshots, raw
    case receipts, handwriting, illustrations, qrCodes
    case recentlyDeleted, hidden, duplicates, archive
    case album(id: String, name: String)
    case person(id: String, name: String)
    case partner(id: String, name: String)

    static let mediaTypes: [Shelf] = [.videos, .livePhotos, .selfies, .portraits, .panoramas, .screenshots, .raw]
    static let utilities: [Shelf] = [.recentlyDeleted, .hidden, .duplicates, .archive, .receipts, .handwriting, .illustrations, .qrCodes]

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .recentlySaved: "Recently Saved"
        case .map: "Map"
        case .videos: "Videos"
        case .livePhotos: "Live Photos"
        case .selfies: "Selfies"
        case .portraits: "Portrait"
        case .panoramas: "Panoramas"
        case .screenshots: "Screenshots"
        case .raw: "RAW"
        case .receipts: "Receipts"
        case .handwriting: "Handwriting"
        case .illustrations: "Illustrations"
        case .qrCodes: "QR Codes"
        case .recentlyDeleted: "Recently Deleted"
        case .hidden: "Hidden"
        case .duplicates: "Duplicates"
        case .archive: "Archive"
        case let .album(_, name), let .person(_, name), let .partner(_, name): name.isEmpty ? "Unnamed" : name
        }
    }

    var symbol: String {
        switch self {
        case .favorites: "heart"
        case .recentlySaved: "clock"
        case .map: "map"
        case .videos: "video"
        case .livePhotos: "livephoto"
        case .selfies: "person.crop.square"
        case .portraits: "cube"
        case .panoramas: "pano"
        case .screenshots: "camera.viewfinder"
        case .raw: "r.square"
        case .receipts: "doc.text"
        case .handwriting: "pencil.and.scribble"
        case .illustrations: "paintbrush"
        case .qrCodes: "qrcode"
        case .recentlyDeleted: "trash"
        case .hidden: "eye.slash"
        case .duplicates: "square.on.square"
        case .archive: "archivebox"
        case .album: "rectangle.stack"
        case .person: "person.crop.circle"
        case .partner: "person.2"
        }
    }

    /// The screen this shelf opens.
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .favorites: TimelineScreen(title: title, query: .favorites)
        case .recentlySaved:
            SearchedGrid(title: title) { client in
                try await client.searchMetadata(["createdAfter": Date.now.addingTimeInterval(-30 * 86400).formatted(.iso8601)])
            }
        case .map: PlacesView()
        case .videos: SearchedGrid(title: title) { try await $0.searchMetadata(["type": "VIDEO"]) }
        case .livePhotos: SearchedGrid(title: title) { try await $0.searchMetadata(["isMotion": true]) }
        case .raw: SearchedGrid(title: title) { try await $0.searchMetadata(["originalFileName": ".dng"]) }
        // Immich has no classifier for these; smart search finds them by their look.
        case .selfies: SearchedGrid(title: title) { try await $0.searchSmart("selfie") }
        case .portraits: SearchedGrid(title: title) { try await $0.searchSmart("portrait photo with blurred background") }
        case .panoramas: SearchedGrid(title: title) { try await $0.searchSmart("wide panorama") }
        case .screenshots: SearchedGrid(title: title) { try await $0.searchSmart("screenshot of a phone screen") }
        case .receipts: SearchedGrid(title: title) { try await $0.searchSmart("receipt") }
        case .handwriting: SearchedGrid(title: title) { try await $0.searchSmart("handwritten note") }
        case .illustrations: SearchedGrid(title: title) { try await $0.searchSmart("illustration or drawing") }
        case .qrCodes: SearchedGrid(title: title) { try await $0.searchSmart("QR code") }
        case .recentlyDeleted: TrashView()
        case .hidden: HiddenView()
        case .duplicates: DuplicatesView()
        case .archive: TimelineScreen(title: title, query: .archive)
        case let .album(id, name): AlbumView(id: id, name: name)
        case let .person(id, name): PersonView(id: id, name: name)
        case let .partner(id, name): TimelineScreen(title: name, query: .partner(id))
        }
    }
}

/// The Collections tab: sections of albums, people, memories, places, media types and utilities.
/// Sections can be reordered and hidden, and any album, person or shelf can be pinned to the top.
struct CollectionsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case pinned = "Pinned", albums = "Albums", shared = "Shared Albums", people = "People"
        case memories = "Memories", trips = "Trips", places = "Places", mediaTypes = "Media Types", utilities = "Utilities"
        var id: String { rawValue }
    }

    @Environment(Session.self) private var session
    @AppStorage("collections.order") private var order = Section.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("collections.hidden") private var hiddenSections = ""
    @AppStorage("collections.collapsed") private var collapsed = ""
    @State private var pins = Pins()
    @State private var albums: [Album] = []
    @State private var people: [Person] = []
    @State private var partners: [User] = []
    @State private var memories: [Memory] = []
    @State private var markers: [MapMarker] = []
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Collections")
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) {
                SectionEditor(order: $order, hidden: $hiddenSections)
            }
            .navigationDestination(for: Shelf.self) { $0.destination }
            .task { await load() }
            .refreshable { await load() }
        }
        .environment(pins)
    }

    private var sections: [Section] {
        order.split(separator: ",").compactMap { Section(rawValue: String($0)) }
            .filter { !hiddenSections.split(separator: ",").contains(Substring($0.rawValue)) }
    }

    @ViewBuilder private func sectionView(_ section: Section) -> some View {
        let isCollapsed = collapsed.split(separator: ",").contains(Substring(section.rawValue))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let all = seeAll(section) {
                    NavigationLink(value: all) {
                        Label(section.rawValue, systemImage: "chevron.right")
                            .labelStyle(TrailingIcon())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(section.rawValue)
                }
                Spacer()
                Button(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "chevron.down" : "chevron.up") {
                    withAnimation(.snappy) { collapsed = toggled(section.rawValue, in: collapsed) }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            }
            .font(.title3.bold())
            .padding(.horizontal)
            if !isCollapsed { content(section) }
        }
    }

    /// The full list a section header opens, if it has one.
    private func seeAll(_ section: Section) -> Shelf? {
        switch section {
        case .places: .map
        default: nil
        }
    }

    @ViewBuilder private func content(_ section: Section) -> some View {
        switch section {
        case .pinned:
            row(pins.items) { ShelfTile(shelf: $0) }
        case .albums:
            NavigationLink("See All Albums") { AlbumsView(shared: false) }.padding(.horizontal)
            row(albums.filter { $0.shared != true }) { AlbumTile(album: $0) }
        case .shared:
            NavigationLink("See All Shared Albums") { AlbumsView(shared: true) }.padding(.horizontal)
            row(albums.filter { $0.shared == true }) { AlbumTile(album: $0) }
            if !partners.isEmpty {
                row(partners) { partner in
                    NavigationLink(value: Shelf.partner(id: partner.id, name: partner.name)) {
                        Label("\(partner.name)'s Library", systemImage: "person.2").padding().background(.quaternary, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .people:
            NavigationLink("See All People and Pets") { PeopleView() }.padding(.horizontal)
            row(people.filter { $0.isHidden != true && !$0.name.isEmpty }) { PersonTile(person: $0) }
        case .memories:
            if memories.isEmpty {
                Text("No memories for today.").foregroundStyle(.secondary).padding(.horizontal)
            } else {
                row(memories) { MemoryTile(memory: $0) }
            }
        case .trips:
            NavigationLink("See All Trips") { TripsView() }.padding(.horizontal)
        case .places:
            NavigationLink(value: Shelf.map) {
                Map(interactionModes: []) {
                    ForEach(markers.prefix(200)) { Marker("", coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
                }
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: 16))
                .allowsHitTesting(false)
            }
            .padding(.horizontal)
        case .mediaTypes:
            ShelfList(shelves: [.favorites, .recentlySaved] + Shelf.mediaTypes)
        case .utilities:
            ShelfList(shelves: Shelf.utilities)
        }
    }

    private func row<Item: Identifiable, Tile: View>(_ items: [Item], @ViewBuilder tile: @escaping (Item) -> Tile) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { tile($0) }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    private func load() async {
        guard let client = session.client else { return }
        error = nil
        do {
            async let albums = client.albums()
            async let people = client.people()
            async let partners = client.partners()
            async let memories = client.memories()
            async let markers = client.mapMarkers()
            self.albums = try await albums.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
            self.people = try await people
            self.partners = (try? await partners) ?? []
            self.memories = (try? await memories) ?? []
            self.markers = (try? await markers) ?? []
        } catch ImmichError.http(401, _) {
            session.signOut()
        } catch {
            self.error = error.explanation
        }
    }
}

/// Adds or removes a name from a comma-separated list stored in AppStorage.
func toggled(_ name: String, in list: String) -> String {
    var names = list.split(separator: ",").map(String.init)
    if let index = names.firstIndex(of: name) { names.remove(at: index) } else { names.append(name) }
    return names.joined(separator: ",")
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.subheadline.bold()).foregroundStyle(.secondary)
        }
    }
}

/// The shelves pinned to the top of Collections, stored on the device.
@MainActor @Observable
final class Pins {
    private(set) var items: [PinnedShelf]

    init() {
        let data = UserDefaults.standard.data(forKey: "collections.pins") ?? Data()
        items = (try? JSONDecoder().decode([PinnedShelf].self, from: data))
            ?? [Shelf.favorites, .recentlySaved, .map, .videos].map(PinnedShelf.init)
    }

    func contains(_ shelf: Shelf) -> Bool { items.contains { $0.shelf == shelf } }

    func toggle(_ shelf: Shelf) {
        if contains(shelf) { items.removeAll { $0.shelf == shelf } } else { items.append(PinnedShelf(shelf: shelf)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "collections.pins")
    }
}

struct PinnedShelf: Codable, Identifiable, Hashable {
    var shelf: Shelf
    var id: Shelf { shelf }
}

extension View {
    /// The Pin / Unpin item for a shelf's context menu.
    func pinnable(_ shelf: Shelf, pins: Pins) -> some View {
        contextMenu {
            Button(pins.contains(shelf) ? "Unpin" : "Pin", systemImage: pins.contains(shelf) ? "pin.slash" : "pin") {
                pins.toggle(shelf)
            }
        }
    }
}

/// A square tile with the shelf's symbol and name; albums and people show their own picture.
struct ShelfTile: View {
    let shelf: PinnedShelf
    @Environment(Pins.self) private var pins

    var body: some View {
        NavigationLink(value: shelf.shelf) {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 110, height: 110)
                    .overlay {
                        switch shelf.shelf {
                        case let .person(id, _): PersonPhoto(id: id).clipShape(.rect(cornerRadius: 12))
                        default: Image(systemName: shelf.shelf.symbol).font(.largeTitle).foregroundStyle(.tint)
                        }
                    }
                Text(shelf.shelf.title).font(.subheadline).lineLimit(1).frame(width: 110, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .pinnable(shelf.shelf, pins: pins)
    }
}

/// The Media Types and Utilities lists.
struct ShelfList: View {
    let shelves: [Shelf]
    @Environment(Pins.self) private var pins

    var body: some View {
        VStack(spacing: 0) {
            ForEach(shelves, id: \.self) { shelf in
                NavigationLink(value: shelf) {
                    HStack {
                        Label(shelf.title, systemImage: shelf.symbol)
                        Spacer()
                        if shelf == .hidden { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pinnable(shelf, pins: pins)
                if shelf != shelves.last { Divider().padding(.leading, 52) }
            }
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }
}

struct MemoryTile: View {
    let memory: Memory

    var body: some View {
        NavigationLink {
            MemoryScreen(memory: memory)
        } label: {
            Thumbnail(asset: memory.assets.first?.ref, size: "preview", square: false)
                .frame(width: 260, height: 180)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(alignment: .bottomLeading) {
                    Text(memory.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        .padding()
                }
        }
        .buttonStyle(.plain)
    }
}

/// A memory's photos, with a button that plays them as a movie.
struct MemoryScreen: View {
    let memory: Memory
    @State private var plays = false

    var body: some View {
        FixedGridScreen(title: memory.title, assets: memory.assets.map(\.ref))
            .toolbar {
                Button("Play Movie", systemImage: "play.fill") { plays = true }
            }
            .fullScreenCover(isPresented: $plays) {
                MemoryMovie(title: memory.title, assets: memory.assets.map(\.ref))
            }
    }
}

/// Reorder the sections and switch them on or off.
struct SectionEditor: View {
    @Binding var order: String
    @Binding var hidden: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(order.split(separator: ",").map(String.init), id: \.self) { name in
                    Toggle(name, isOn: Binding {
                        !hidden.split(separator: ",").contains(Substring(name))
                    } set: { _ in
                        hidden = toggled(name, in: hidden)
                    })
                }
                .onMove { from, to in
                    var names = order.split(separator: ",").map(String.init)
                    names.move(fromOffsets: from, toOffset: to)
                    order = names.joined(separator: ",")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done", role: .confirm) { dismiss() }
            }
        }
    }
}

// MARK: - Grid screens

/// A server timeline with a title and item count: Favorites, Archive, a partner's library.
struct TimelineScreen: View {
    let title: String
    @State private var timeline: Timeline

    init(title: String, query: TimelineQuery) {
        self.title = title
        _timeline = State(initialValue: Timeline(query))
    }

    var body: some View {
        AssetGrid(timeline: timeline)
            .navigationTitle(title)
            .navigationSubtitle(timeline.months == nil ? "" : "\(timeline.count.formatted()) Items")
    }
}

/// A grid of a fixed list of assets, oldest first.
struct FixedGridScreen: View {
    let title: String
    @State private var timeline: Timeline

    init(title: String, assets: [AssetRef]) {
        self.title = title
        _timeline = State(initialValue: Timeline(assets: assets))
    }

    var body: some View {
        AssetGrid(timeline: timeline)
            .navigationTitle(title)
            .navigationSubtitle("\(timeline.count.formatted()) Items")
    }
}

/// A grid of search results; the best match ends up at the bottom, next to the thumb.
struct SearchedGrid: View {
    let title: String
    let search: (ImmichClient) async throws -> [Asset]

    @Environment(Session.self) private var session
    @State private var timeline: Timeline?
    @State private var error: String?

    var body: some View {
        Group {
            if let timeline {
                AssetGrid(timeline: timeline)
            } else if let error {
                ContentUnavailableView("Can't Load \(title)", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(timeline.map { "\($0.count.formatted()) Items" } ?? "")
        .task {
            guard timeline == nil, let client = session.client else { return }
            do {
                timeline = Timeline(assets: try await search(client).reversed().map(\.ref))
            } catch {
                self.error = error.explanation
            }
        }
    }
}
