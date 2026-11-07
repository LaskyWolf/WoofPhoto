import SwiftUI

/// A timeline as a square grid, with the Library's Years / Months / All levels, a month scrubber,
/// pinch to change the column count, and the viewer opening from the tapped cell.
struct AssetGrid: View {
    enum Level: String, CaseIterable {
        case years = "Years", months = "Months", all = "All"
    }

    /// Pinching steps through these column counts, like the Photos grid.
    static let columnSteps = [3, 5, 9]

    let timeline: Timeline
    /// Only the Library shows Years and Months.
    var showsLevels = false
    /// A tab's own title: the grid draws WoofMusic's header instead of the navigation bar.
    var title: String?
    /// Scrolls above the photos, like an album's cover. The grid then opens at the top.
    var hero: AnyView?

    @Environment(Session.self) private var session
    @AppStorage("library.columns") private var columns = 5
    @State private var level = Level.all
    @State private var target: String?
    @State private var error: String?
    /// nil outside Select mode.
    @State private var selection: Set<String>?
    @State private var drag: (start: Int, base: Set<String>, adds: Bool)?
    @State private var gridWidth: CGFloat = 0
    @Environment(\.photoZoom) private var zoom
    @Environment(\.libraryReselects) private var reselects
    /// The pinch in progress, shown as a scale before the column count changes.
    @GestureState private var pinch: CGFloat = 1
    /// The long-press menu's actions.
    @State private var actions = AssetActions()

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let problem = timeline.problem {
                        Text(problem)
                            .font(.footnote)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .onTapGesture { timeline.problem = nil }
                    }
                    if selection == nil, title == nil, showsLevels, timeline.months?.isEmpty == false {
                        Picker("Show", selection: $level) {
                            ForEach(Level.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                        .padding(.bottom, 4)
                    }
                }
            }
            .stickyHeader { if let title { header(title) } }
            .toolbar(title == nil ? .automatic : .hidden, for: .navigationBar)
            .toolbar { if title == nil { selectionToolbar } }
            .sensoryFeedback(.selection, trigger: selection ?? [])
            .environment(timeline)
            .assetActions(actions)
            .onAppear {
                // an action on the selection ends Select mode, as in WoofMusic's playlists
                actions.done = { selection = nil }
            }
            .task(id: ObjectIdentifier(timeline)) {
                // a new search or a refreshed trash swaps the timeline, so the actions follow it
                actions.timeline = timeline
                await reload()
            }
    }

    /// Selecting acts on the server, so it needs one.
    private var canSelect: Bool { session.client != nil && level == .all && timeline.months?.isEmpty == false }

    /// What Select All picks: the server's items that have loaded.
    private var selectable: Set<String> { Set(timeline.assets.filter { $0.localID == nil }.map(\.id)) }
    private var allSelected: Bool { !selectable.isEmpty && selection == selectable }

    private func toggleSelect() {
        withAnimation(.snappy) { selection = selection == nil ? [] : nil }
    }

    /// WoofMusic's playlist toolbar: Select, then Select All, the actions menu and Done while selecting.
    @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
        if let selection {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(allSelected ? "Deselect All" : "Select All", systemImage: allSelected ? "checklist.unchecked" : "checklist.checked") {
                    self.selection = allSelected ? [] : selectable
                }
                Menu {
                    AssetMenuItems(actions: actions, ids: Array(selection))
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("Actions for \(selection.count) selected")
                }
                .disabled(selection.isEmpty)
                Button("Done") { toggleSelect() }
            }
        } else if canSelect {
            ToolbarItem(placement: .primaryAction) {
                Button("Select", systemImage: "checkmark.circle") { toggleSelect() }
            }
        }
    }

    /// WoofMusic's title row and chips. While selecting, the title counts the selection and the buttons act on it.
    private func header(_ title: String) -> some View {
        Group {
            TabHeader(title: selection.map { "\($0.count) Selected" } ?? title, showsCommon: selection == nil) {
                if let selection {
                    HeaderButton(label: allSelected ? "Deselect All" : "Select All",
                                 systemImage: allSelected ? "checklist.unchecked" : "checklist.checked") {
                        self.selection = allSelected ? [] : selectable
                    }
                    Menu {
                        AssetMenuItems(actions: actions, ids: Array(selection))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .tapArea(outset: 4)
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Actions for \(selection.count) selected")
                    Button("Done") { toggleSelect() }
                        .font(.headline)
                        .frame(height: 36)
                        .tapArea(outset: 4)
                } else if canSelect {
                    HeaderButton(label: "Select", systemImage: "checkmark.circle") { toggleSelect() }
                }
            }
            if showsLevels, selection == nil, timeline.months?.isEmpty == false {
                FilterChips(items: Level.allCases, selection: $level) { $0.rawValue }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let months = timeline.months {
            let client = session.client
            if months.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
            } else {
                // All stays alive under Years and Months, so going back to it keeps its place
                ZStack {
                    grid(months, client: client)
                        .opacity(level == .all ? 1 : 0)
                        .allowsHitTesting(level == .all)
                        .accessibilityHidden(level != .all)
                    switch level {
                    case .all: EmptyView()
                    case .months: monthsView(months, client: client).background(Color(.systemBackground))
                    case .years: yearsView(Self.years(months), client: client).background(Color(.systemBackground))
                    }
                }
            }
        } else if let error {
            ContentUnavailableView {
                Label("Can't Load the Photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        } else {
            ProgressView()
        }
    }

    private func grid(_ months: [Timeline.Month], client: ImmichClient?) -> some View {
        // Apple Photos' square cells with 2-point gaps
        let spacing: CGFloat = 2
        return ScrollViewReader { proxy in
            ScrollView {
                hero
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(0..<leadingBlanks(months), id: \.self) { _ in Color.clear }
                    ForEach(months) { month in
                        ForEach(0..<(month.assets?.count ?? month.count), id: \.self) { index in
                            let asset = month.assets?[index]
                            Thumbnail(asset: asset)
                                .overlay(alignment: .bottomTrailing) {
                                    if let selection, let id = asset?.id {
                                        let selected = selection.contains(id)
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(.white, .tint)
                                            .shadow(radius: 2)
                                            .padding(4)
                                            .background(selected ? Color.white.opacity(0.25) : .clear)
                                    }
                                }
                                .contentShape(.contextMenuPreview, .rect)
                                .liftedMenu(background: nil) {
                                    if let asset, asset.localID == nil, client != nil {
                                        AssetMenuItems(actions: actions, ids: [asset.id], isFavorite: asset.isFavorite)
                                    }
                                }
                                .zoomSource(asset?.id ?? "\(month.key)#\(index)", in: zoom)
                                .id("\(month.key)#\(index)")
                                .onTapGesture {
                                    guard let asset else { return }
                                    if selection != nil {
                                        selection = toggled(asset.id, in: selection ?? [])
                                    } else {
                                        OpenPhoto.shared.open(asset, in: timeline)
                                    }
                                }
                                .accessibilityAddTraits(selection?.contains(asset?.id ?? "") == true ? [.isButton, .isSelected] : .isButton)
                                .task {
                                    if let client { await timeline.loadMonth(around: month.key, with: client) }
                                }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                // in Select mode, a drag that starts sideways selects every cell it crosses
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                    dragSelect(value, months: months, spacing: spacing)
                }.onEnded { _ in
                    drag = nil
                }, including: selection == nil ? .subviews : .all)
                .padding(.horizontal, spacing)
                .scaleEffect(pinch)
                .animation(.snappy, value: columns)
            }
            .defaultScrollAnchor(hero == nil ? .bottom : .top)
            // Photos opens at the newest, so tapping the tab again goes back down to it
            .onChange(of: reselects) {
                guard title != nil, let last = months.last else { return }
                withAnimation(.smooth) { proxy.scrollTo("\(last.key)#\((last.assets?.count ?? last.count) - 1)", anchor: .bottom) }
            }
            .overlay(alignment: .trailing) {
                if months.count > 1, selection == nil { Scrubber(months: months, proxy: proxy) }
            }
            // a day tapped in Months
            .onChange(of: target) {
                guard let target, level == .all else { return }
                proxy.scrollTo("\(target)#0", anchor: .top)
                self.target = nil
            }
        }
        .simultaneousGesture(MagnifyGesture().updating($pinch) { value, pinch, _ in
            pinch = min(max(value.magnification, 0.6), 1.6)
        }.onEnded { value in
            let steps = Self.columnSteps
            let current = steps.firstIndex(of: columns) ?? 1
            let next = value.magnification > 1.15 ? current - 1 : value.magnification < 0.87 ? current + 1 : current
            withAnimation(.snappy) { columns = steps[min(max(next, 0), steps.count - 1)] }
        })
    }

    /// Empty cells before the oldest photo, so the newest row at the bottom is full, as in Photos.
    private func leadingBlanks(_ months: [Timeline.Month]) -> Int {
        guard hero == nil else { return 0 }
        let total = months.reduce(0) { $0 + ($1.assets?.count ?? $1.count) }
        return (columns - total % columns) % columns
    }

    private func toggled(_ id: String, in set: Set<String>) -> Set<String> {
        set.contains(id) ? set.subtracting([id]) : set.union([id])
    }

    private func dragSelect(_ value: DragGesture.Value, months: [Timeline.Month], spacing: CGFloat) {
        guard let selection, gridWidth > 0 else { return }
        let cell = (gridWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns) + spacing
        func index(_ point: CGPoint) -> Int {
            max(Int(point.y / cell), 0) * columns + min(max(Int(point.x / cell), 0), columns - 1)
        }
        // every cell in grid order, nil where the month isn't loaded yet
        let flat = Array(repeating: nil, count: leadingBlanks(months)) + months.flatMap { month in month.assets.map { $0.map(Optional.some) } ?? Array(repeating: nil, count: month.count) }
        if drag == nil {
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let start = index(value.startLocation)
            let startID = (flat[safe: start] ?? nil)?.id
            drag = (start, selection, !(startID.map(selection.contains) ?? false))
        }
        guard let drag else { return }
        let end = index(value.location)
        let ids = (min(drag.start, end)...max(drag.start, end)).compactMap { (flat[safe: $0] ?? nil)?.id }
        self.selection = drag.adds ? drag.base.union(ids) : drag.base.subtracting(ids)
    }

    /// A year in the Years view.
    struct CardGroup {
        var key: String
        var title: String
        var months: [Timeline.Month]
    }

    /// Photos' Years: one large card per year, the year on its top corner. A tap opens that year in Months.
    private func yearsView(_ groups: [CardGroup], client: ImmichClient?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(groups, id: \.key) { group in
                        let month = group.months.last!
                        Button {
                            target = month.key
                            withAnimation(.snappy) { level = .months }
                        } label: {
                            Thumbnail(asset: month.assets?.first, size: "preview", square: false, cornerRadius: Tokens.tileRadius)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .overlay(alignment: .topLeading) {
                                    Text(group.title)
                                        .font(.title.bold())
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.5), radius: 6)
                                        .padding(16)
                                }
                        }
                        .buttonStyle(ZoomPressStyle(scale: 0.97))
                        .id(group.key)
                        .task { if let client { await timeline.loadMonth(month.key, with: client) } }
                    }
                }
                .padding(.horizontal, Tokens.screenPadding)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: reselects) { scrollToNewest(groups.last?.key, proxy) }
            .task {
                guard let target else { return }
                await Task.yield()
                proxy.scrollTo(String(target.prefix(4)), anchor: .center)
                self.target = nil
            }
        }
    }

    /// Photos' Months: under each month's title, a mosaic of its days, each with the day's number.
    /// A tap opens the grid at that month.
    private func monthsView(_ months: [Timeline.Month], client: ImmichClient?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                    ForEach(months) { month in
                        Section {
                            DayMosaic(tiles: DayMosaic.tiles(month.assets ?? [])) {
                                target = month.key
                                withAnimation(.snappy) { level = .all }
                            }
                            .frame(minHeight: month.assets == nil ? 240 : 0, alignment: .top)
                            .task { if let client { await timeline.loadMonth(month.key, with: client) } }
                        } header: {
                            Text(Self.shortMonthTitle(month.key))
                                .font(.title2.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background {
                                    LinearGradient(colors: [Color(.systemBackground).opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                                        .padding(.horizontal, -Tokens.screenPadding)
                                }
                        }
                        .id(month.key)
                    }
                }
                .padding(.horizontal, Tokens.screenPadding)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: reselects) { scrollToNewest(months.last?.key, proxy) }
            .task {
                guard let target else { return }
                await Task.yield()
                proxy.scrollTo(target, anchor: .top)
                self.target = nil
            }
        }
    }

    /// Tapping the Library tab again goes down to the newest, as in the All grid.
    private func scrollToNewest(_ key: String?, _ proxy: ScrollViewProxy) {
        guard title != nil, let key else { return }
        withAnimation(.smooth) { proxy.scrollTo(key, anchor: .bottom) }
    }

    private func reload() async {
        guard let client = session.client, timeline.query != nil else { return }
        error = nil
        do {
            try await timeline.reload(with: client)
        } catch ImmichError.http(401, _) {
            session.signOut()
        } catch {
            self.error = error.explanation
        }
    }

    /// "Nov 2024", as in Photos' Months.
    static func shortMonthTitle(_ key: String) -> String {
        guard let date = TimeBucket(timeBucket: key, count: 0).date else { return key }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).year())
    }

    static func monthTitle(_ key: String) -> String {
        guard let date = TimeBucket(timeBucket: key, count: 0).date else { return key }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide).year())
    }

    private static func years(_ months: [Timeline.Month]) -> [CardGroup] {
        var groups: [CardGroup] = []
        for month in months {
            let year = String(month.key.prefix(4))
            if groups.last?.key == year {
                groups[groups.count - 1].months.append(month)
            } else {
                groups.append(CardGroup(key: year, title: year, months: [month]))
            }
        }
        return groups
    }
}

/// Drag along the right edge to jump through the months; a label shows the month under the finger.
struct Scrubber: View {
    let months: [Timeline.Month]
    let proxy: ScrollViewProxy
    @State private var position: (y: CGFloat, title: String)?

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(max(value.location.y / geometry.size.height, 0), 1)
                    let month = months[Int(fraction * Double(months.count - 1))]
                    if position?.title != AssetGrid.monthTitle(month.key) {
                        proxy.scrollTo("\(month.key)#0", anchor: .top)
                    }
                    position = (value.location.y, AssetGrid.monthTitle(month.key))
                }.onEnded { _ in
                    position = nil
                })
                .overlay(alignment: .topTrailing) {
                    if let position {
                        Text(position.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: .capsule)
                            .fixedSize()
                            .offset(x: -24, y: position.y - 16)
                    }
                }
        }
        .frame(width: 20)
        .sensoryFeedback(.selection, trigger: position?.title)
    }
}

/// One grid cell: grey until its month loads, then the blurred thumbhash, then the real image.
struct Thumbnail: View {
    let asset: AssetRef?
    var size = "thumbnail"
    /// Cards keep the photo's own shape; grid cells are square.
    var square = true
    var cornerRadius: CGFloat = 0
    /// Off in the viewer's strip, where the cells are too small for them.
    var showsBadges = true

    @Environment(Session.self) private var session
    @Environment(Timeline.self) private var timeline: Timeline?
    @State private var loaded: UIImage?
    @AppStorage("grid.backupBadge") private var backupBadge = true

    var body: some View {
        // a nil ratio still makes a square (a colour's ideal size is square), so a card fills the frame it's given instead
        Group {
            if square { Color(.secondarySystemFill).aspectRatio(1, contentMode: .fit) } else { Color(.secondarySystemFill) }
        }
            .overlay {
                if let image = loaded ?? asset.flatMap({ ImageCache.image($0.id, size: size) }) ?? placeholder {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            // the filled image spills past the cell; without the shape a tap there opens the neighbour drawn on top
            .clipShape(.rect(cornerRadius: cornerRadius))
            .contentShape(.rect(cornerRadius: cornerRadius))
            .overlay(alignment: .bottomTrailing) {
                if showsBadges, let duration {
                    Text(duration).overlayBadge()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsBadges, asset?.isFavorite == true {
                    Image(systemName: "heart.fill").overlayBadge()
                }
            }
            .overlay(alignment: .topLeading) {
                if showsBadges, backupBadge, asset?.localID != nil {
                    Image(systemName: "icloud.slash").overlayBadge()
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsBadges, let count = asset?.stackCount, count > 1 {
                    Label("\(count)", systemImage: "square.stack.fill").overlayBadge()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(spokenLabel)
            .task(id: asset?.id) { await load() }
    }

    /// "Video, 1:05, Favorite, March 3, 2024" for VoiceOver.
    private var spokenLabel: String {
        guard let asset else { return "Photo, loading" }
        var parts = [asset.isImage ? "Photo" : "Video"]
        if let duration { parts.append(duration) }
        if asset.isFavorite { parts.append("Favorite") }
        if asset.localID != nil { parts.append("Not backed up") }
        if asset.stackCount > 1 { parts.append("Stack of \(asset.stackCount)") }
        if let date = asset.date { parts.append(date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))) }
        return parts.joined(separator: ", ")
    }

    private var placeholder: UIImage? {
        guard let asset, let hash = asset.thumbhash else { return nil }
        return ImageCache.placeholder(id: asset.id, hash: hash)
    }

    /// 65,120 ms becomes "1:05", like the Photos grid.
    private var duration: String? {
        guard let asset, !asset.isImage, let milliseconds = asset.duration else { return nil }
        return Self.clock(milliseconds)
    }

    static func clock(_ milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func load() async {
        // held here too: the cache drops images when the viewer needs memory, and nothing would load them again
        loaded = asset.flatMap { ImageCache.image($0.id, size: size) }
        guard let asset, loaded == nil else { return }
        if let localID = asset.localID {
            loaded = await DeviceLibrary.image(localID, side: size == "thumbnail" ? 300 : 1200)
            if let loaded { ImageCache.store(loaded, for: asset.id, size: size) }
            return
        }
        guard let client = session.client else { return }
        if asset.thumbhash != nil, placeholder == nil {
            timeline?.problem = "Failed to decode the thumbhash \(asset.thumbhash ?? "")"
        }
        do {
            let data = try await client.image(asset.id, size: size)
            guard let image = UIImage(data: data) else {
                timeline?.problem = "Failed to read a thumbnail: \(data.count) bytes that aren't an image"
                return
            }
            let ready = await image.byPreparingForDisplay() ?? image
            ImageCache.store(ready, for: asset.id, size: size)
            loaded = ready
        } catch {
            timeline?.report(error, while: "loading a thumbnail")
        }
    }
}

private extension View {
    /// White text with a soft shadow, readable on any photo.
    func overlayBadge() -> some View {
        font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(4)
    }
}

/// Decoded images kept in memory, so scrolling back doesn't decode them again. iOS empties it under memory pressure.
/// The downloaded files themselves stay in URLCache on disk (see WoofPhotoApp).
enum ImageCache {
    private static let images = NSCache<NSString, UIImage>()

    static func image(_ id: String, size: String) -> UIImage? { images.object(forKey: "\(size):\(id)" as NSString) }
    static func store(_ image: UIImage, for id: String, size: String) { images.setObject(image, forKey: "\(size):\(id)" as NSString) }

    /// Drops every saved image of an asset after an edit changed it, in memory and on disk.
    static func forget(_ id: String, client: ImmichClient) {
        for size in ["thumbnail", "preview", "fullsize"] {
            images.removeObject(forKey: "\(size):\(id)" as NSString)
            URLCache.shared.removeCachedResponse(for: client.request("/assets/\(id)/thumbnail", query: ["size": size]))
        }
    }

    /// Everything in memory, at sign-out.
    static func removeAll() { images.removeAllObjects() }

    static func placeholder(id: String, hash: String) -> UIImage? {
        let key = "hash:\(id)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = ThumbHash.image(base64: hash) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

/// One month in Photos' Months view: a tile per day with photos, its number on the top corner.
/// The tiles alternate between one wide day, three square days, and a big day beside two small ones.
struct DayMosaic: View {
    struct Tile: Identifiable {
        let day: Int
        let asset: AssetRef
        var id: Int { day }
    }

    private enum Row {
        case wide(Tile), three([Tile]), big([Tile]), two([Tile])
    }

    let tiles: [Tile]
    let onTap: () -> Void
    @State private var width: CGFloat = 0
    private static let gap: CGFloat = 6

    /// The first photo of each day, in day order.
    static func tiles(_ assets: [AssetRef]) -> [Tile] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var seen = Set<Int>()
        let tiles = assets.compactMap { asset -> Tile? in
            guard let date = asset.date else { return nil }
            let day = calendar.component(.day, from: date)
            return seen.insert(day).inserted ? Tile(day: day, asset: asset) : nil
        }
        return tiles.sorted { $0.day < $1.day }
    }

    /// A count that leaves one over starts with a wide day, then threes take turns, and two left over share a row.
    private var rows: [Row] {
        var rows: [Row] = []
        var index = 0
        if tiles.count % 3 == 1 {
            rows.append(.wide(tiles[0]))
            index = 1
        }
        var big = rows.isEmpty
        while index < tiles.count {
            let rest = Array(tiles[index..<min(index + 3, tiles.count)])
            switch rest.count {
            case 3: rows.append(big ? .big(rest) : .three(rest))
            case 2: rows.append(.two(rest))
            default: rows.append(.wide(rest[0]))
            }
            big.toggle()
            index += rest.count
        }
        return rows
    }

    var body: some View {
        let small = max((width - Self.gap * 2) / 3, 0)
        VStack(spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case let .wide(tile):
                    tileView(tile, width: width, height: (width * 2 / 3).rounded(), size: "preview")
                case let .three(tiles):
                    HStack(spacing: Self.gap) { ForEach(tiles) { tileView($0, width: small, height: small) } }
                case let .big(tiles):
                    HStack(spacing: Self.gap) {
                        tileView(tiles[0], width: small * 2 + Self.gap, height: small * 2 + Self.gap, size: "preview")
                        VStack(spacing: Self.gap) { ForEach(tiles.dropFirst()) { tileView($0, width: small, height: small) } }
                    }
                case let .two(tiles):
                    let half = (width - Self.gap) / 2
                    HStack(spacing: Self.gap) { ForEach(tiles) { tileView($0, width: half, height: half) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func tileView(_ tile: Tile, width: CGFloat, height: CGFloat, size: String = "thumbnail") -> some View {
        Button(action: onTap) {
            Thumbnail(asset: tile.asset, size: size, square: false, cornerRadius: Tokens.tileRadius)
                .frame(width: width, height: height)
                .overlay(alignment: .topLeading) {
                    Text("\(tile.day)")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .padding(10)
                }
        }
        .buttonStyle(ZoomPressStyle(scale: 0.97))
        .accessibilityLabel("Day \(tile.day)")
    }
}
