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
    /// Hidden and Duplicates are the shortcut tiles at the top of Collections.
    static let utilities: [Shelf] = [.recentlyDeleted, .archive, .receipts, .handwriting, .illustrations, .qrCodes]

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
        case albums = "Albums", shared = "Shared Albums", people = "People"
        case memories = "Memories", trips = "Trips", places = "Places", mediaTypes = "Media Types", utilities = "Utilities"
        var id: String { rawValue }
    }

    @Environment(Session.self) private var session
    @AppStorage("collections.order") private var order = Section.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("collections.hidden") private var hiddenSections = ""
    @AppStorage("collections.collapsed") private var collapsed = ""
    /// WoofMusic's library layout: covers in a grid, or rows.
    @AppStorage("collections.list") private var listLayout = false
    @Namespace private var shelfZoom
    @State private var albums: [Album] = []
    @State private var people: [Person] = []
    @State private var partners: [User] = []
    @State private var memories: [Memory] = []
    @State private var markers: [MapMarker] = []
    @State private var editing = false
    @State private var error: String?
    /// WoofMusic's library filter: one section, or every section when off.
    @State private var chip: Section?
    @State private var favoriteCovers: [String] = []
    @State private var favoriteCount: Int?
    @State private var duplicates: [DuplicateGroup] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    shortcuts
                    if let error {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Tokens.screenPadding)
                            .padding(.top, 12)
                    }
                    ForEach(sections.filter { chip == nil || $0 == chip }) { section in
                        sectionView(section)
                    }
                }
                .animation(.smooth(duration: 0.4), value: chip)
            }
            // on the list only: on the whole page the chips above would pull to refresh too
            .refreshable { await load() }
            .stickyHeader {
                TabHeader(title: "Collections") {
                    HeaderButton(label: listLayout ? "Show as Grid" : "Show as List", systemImage: listLayout ? "square.grid.2x2" : "list.bullet") {
                        withAnimation(.snappy) { listLayout.toggle() }
                    }
                    HeaderButton(label: "Edit Sections", systemImage: "slider.horizontal.3") { editing = true }
                }
                FilterChips(items: sections, selection: $chip) { $0.rawValue }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: sections) { if let chip, !sections.contains(chip) { self.chip = nil } }
            .sheet(isPresented: $editing) {
                SectionEditor(order: $order, hidden: $hiddenSections)
            }
            .navigationDestination(for: Shelf.self) { shelf in
                shelf.destination.navigationTransition(.zoom(sourceID: shelf, in: shelfZoom))
            }
            .task { await load() }
        }
        // on the stack, so See All pages zoom from their tiles too
        .environment(\.shelfZoom, shelfZoom)
    }

    private var sections: [Section] {
        order.split(separator: ",").compactMap { Section(rawValue: String($0)) }
            .filter { !hiddenSections.split(separator: ",").contains(Substring($0.rawValue)) }
    }

    /// WoofMusic's library section: a bold title with its count, See All, and the content under it.
    @ViewBuilder private func sectionView(_ section: Section) -> some View {
        let isCollapsed = chip == nil && collapsed.split(separator: ",").contains(Substring(section.rawValue))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    withAnimation(.snappy) { collapsed = toggled(section.rawValue, in: collapsed) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(section.rawValue).font(.title3.bold())
                        Image(systemName: "chevron.down")
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(chip != nil)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(isCollapsed ? "Shows the section" : "Hides the section")
                Spacer()
                if let count = count(section) {
                    Text("\(count)").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                seeAll(section).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, Tokens.screenPadding)
            .padding(.vertical, 8)
            if !isCollapsed { content(section) }
        }
        .padding(.bottom, Tokens.sectionGap)
    }

    private func count(_ section: Section) -> Int? {
        switch section {
        case .albums: albums.filter { $0.shared != true }.count
        case .shared: albums.filter { $0.shared == true }.count
        case .people: shownPeople.count
        default: nil
        }
    }

    // MARK: Shortcuts

    /// WoofMusic's and WoofTube's shortcut tiles, right under the filters.
    private var shortcuts: some View {
        HStack(spacing: 10) {
            NavigationLink(value: Shelf.favorites) {
                ShortcutTile(title: "Favorites", subtitle: favoriteCount.map { "\($0.formatted()) items" }, icon: "heart.fill",
                             tint: .red, covers: favoriteCovers)
            }
            .zoomSource(Shelf.favorites, in: shelfZoom)
            NavigationLink(value: Shelf.duplicates) {
                ShortcutTile(title: "Duplicates", subtitle: duplicates.isEmpty ? "None found" : "\(duplicates.count) groups",
                             icon: "square.fill.on.square.fill", tint: .teal,
                             covers: duplicates.prefix(2).compactMap { $0.assets.first?.id })
            }
            .zoomSource(Shelf.duplicates, in: shelfZoom)
            // locked, so no covers give it away
            NavigationLink(value: Shelf.hidden) {
                ShortcutTile(title: "Hidden", subtitle: "Locked", icon: "eye.slash.fill", tint: .indigo, covers: [])
            }
            .zoomSource(Shelf.hidden, in: shelfZoom)
        }
        .buttonStyle(ZoomPressStyle())
        .padding(.horizontal, Tokens.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, Tokens.sectionGap)
    }

    /// The See All link a section header shows, if it has a full list.
    @ViewBuilder private func seeAll(_ section: Section) -> some View {
        switch section {
        case .albums: NavigationLink("See All") { AlbumsView(shared: false) }
        case .shared: NavigationLink("See All") { AlbumsView(shared: true) }
        case .people: NavigationLink("See All") { PeopleView() }
        case .trips: NavigationLink("See All") { TripsView() }
        case .places: NavigationLink("See All", value: Shelf.map)
        default: EmptyView()
        }
    }

    @ViewBuilder private func content(_ section: Section) -> some View {
        switch section {
        case .albums:
            grid(albums.filter { $0.shared != true }.prefix(6), columns: 2) { AlbumTile(album: $0, size: nil, isRow: listLayout) }
        case .shared:
            grid(albums.filter { $0.shared == true }.prefix(6), columns: 2) { AlbumTile(album: $0, size: nil, isRow: listLayout) }
            if !partners.isEmpty {
                row(partners) { partner in
                    NavigationLink(value: Shelf.partner(id: partner.id, name: partner.name)) {
                        Label("\(partner.name)'s Library", systemImage: "person.2").padding().background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.tileRadius))
                    }
                    .buttonStyle(ZoomPressStyle())
                }
            }
        case .people:
            if shownPeople.isEmpty {
                Text("People appear once Immich finds faces in your photos.").foregroundStyle(.secondary).padding(.horizontal, Tokens.screenPadding)
            } else {
                grid(shownPeople.prefix(8), columns: 4) { PersonTile(person: $0, size: nil, isRow: listLayout) }
            }
        case .memories:
            if memories.isEmpty {
                Text("Memories from this day in past years appear here.").foregroundStyle(.secondary).padding(.horizontal, Tokens.screenPadding)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(memories.prefix(9)) { MemoryTile(memory: $0) }
                }
                .padding(.horizontal, Tokens.screenPadding)
            }
        case .trips:
            TripsRow()
        case .places:
            NavigationLink(value: Shelf.map) {
                Map(interactionModes: []) {
                    ForEach(markers.prefix(200)) { Marker("", coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
                }
                .frame(height: 200)
                .clipShape(.rect(cornerRadius: Tokens.cardRadius))
                .allowsHitTesting(false)
            }
            .zoomSource(Shelf.map, in: shelfZoom)
            .buttonStyle(ZoomPressStyle(scale: 0.97))
            .padding(.horizontal, Tokens.screenPadding)
        case .mediaTypes:
            ShelfList(shelves: [.recentlySaved] + Shelf.mediaTypes)
        case .utilities:
            ShelfList(shelves: Shelf.utilities)
        }
    }

    /// Named people first; unnamed ones too, so faces Immich found but nobody named still show.
    private var shownPeople: [Person] {
        people.filter { $0.isHidden != true }.sorted { !$0.name.isEmpty && $1.name.isEmpty }
    }

    /// WoofMusic's library grid: equal columns, 16 points apart, or rows in list layout; See All has the rest.
    private func grid<Items: RandomAccessCollection, Tile: View>(_ items: Items, columns: Int, @ViewBuilder tile: @escaping (Items.Element) -> Tile) -> some View
    where Items.Element: Identifiable {
        Group {
            if listLayout {
                LazyVStack(alignment: .leading, spacing: 8) { ForEach(items) { tile($0) } }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns), spacing: 16) {
                    ForEach(items) { tile($0) }
                }
            }
        }
        .padding(.horizontal, Tokens.screenPadding)
    }

    private func row<Item: Identifiable, Tile: View>(_ items: [Item], @ViewBuilder tile: @escaping (Item) -> Tile) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { tile($0) }
            }
            .padding(.horizontal, Tokens.screenPadding)
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
            favoriteCovers = ((try? await client.firstAssets(["isFavorite": true], count: 2)) ?? []).map(\.id)
            favoriteCount = try? await client.favoriteCount()
            duplicates = (try? await client.duplicates()) ?? []
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

/// The Media Types and Utilities lists.
struct ShelfList: View {
    let shelves: [Shelf]
    @Environment(\.shelfZoom) private var shelfZoom

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
                .zoomSource(shelf, in: shelfZoom)
                if shelf != shelves.last { Divider().padding(.leading, 52) }
            }
        }
        .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.cardRadius))
        .padding(.horizontal, Tokens.screenPadding)
    }
}

struct MemoryTile: View {
    let memory: Memory

    var body: some View {
        NavigationLink {
            MemoryScreen(memory: memory)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { Thumbnail(asset: memory.assets.first?.ref, size: "preview") }
                .overlay(alignment: .bottomLeading) {
                    Text(memory.title)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(.rect(cornerRadius: Tokens.tileRadius))
        }
        .buttonStyle(ZoomPressStyle())
        .accessibilityLabel(memory.title)
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

/// WoofMusic's shortcut tile: a card in its colour, two photos fanned at the top, over a big white symbol the corner crops.
struct ShortcutTile: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let covers: [String]

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private static let coverSide: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fannedCovers
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 116)
        .background {
            ZStack {
                // a colour gradient and light from above
                LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                // larger than the corner and tilted left, so the card's edge crops it
                Image(systemName: icon)
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(-18))
                    .offset(x: 19, y: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .clipShape(Self.shape)
            .shadow(color: tint.opacity(0.4), radius: 6, y: 4)
            .accessibilityHidden(true)
        }
        .contentShape(Self.shape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var fannedCovers: some View {
        if let first = covers.first {
            ZStack(alignment: .topLeading) {
                if covers.count > 1 {
                    cover(covers[1])
                        .rotationEffect(.degrees(-8))
                        .offset(x: 2, y: 6)
                }
                cover(first)
                    .rotationEffect(.degrees(covers.count > 1 ? 6 : 0))
                    .offset(x: covers.count > 1 ? 24 : 2, y: 2)
            }
        }
    }

    private func cover(_ id: String) -> some View {
        Thumbnail(asset: AssetRef(id: id), cornerRadius: 7)
            .frame(width: Self.coverSide, height: Self.coverSide)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }
}
