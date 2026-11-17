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
    /// The column step a pinch started from, so one pinch moves at most one or two steps.
    @State private var pinchStart: Int?
    /// The cell under the pinching fingers and where it was on screen (0 top, 1 bottom): it stays there as the columns change.
    @State private var pinchAnchor: (id: String, fraction: CGFloat)?
    /// Where the grid is scrolled, for the scrubber's handle; a class, so its changes redraw only the scrubber.
    @State private var metrics = ScrollMetrics()
    /// The month scrubber on the right edge: only while the grid scrolls and a moment after, as in Photos,
    /// so at rest that edge belongs to the photos under it (a tap there opened another month).
    @State private var showsScrubber = false
    @State private var scrollMoving = false
    @State private var scrubbing = false
    /// Every cell in grid order, built once when a drag-select starts instead of on every move.
    @State private var dragCells: [AssetRef?] = []
    /// True until the first touch of the scroll: until then the grid keeps itself at the newest photos while it fills in.
    @State private var followsEnd = true
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
            // photos the checksum check found on the server, or a finished backup, change what the Library merges
            .onChange(of: Backup.shared.revision) { if timeline.query == .library { Task { await reload() } } }
            .task(id: ObjectIdentifier(timeline)) {
                // a new search or a refreshed trash swaps the timeline, so the actions follow it
                actions.timeline = timeline
                await reload()
            }
    }

    /// Selecting acts on the server, so it needs one.
    private var canSelect: Bool { session.client != nil && level == .all && timeline.months?.isEmpty == false }

    /// What Select All picks: every item that has loaded, on the server or only on this iPhone.
    private var selectable: Set<String> { Set(timeline.assets.map(\.id)) }
    /// Counts instead of building the whole set: the header reads this on every drag-select move.
    private var allSelected: Bool {
        let count = timeline.assets.count
        return count > 0 && selection?.count == count
    }

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
                    // one glass capsule around the three controls
                    HStack(spacing: 4) {
                    HeaderButton(label: allSelected ? "Deselect All" : "Select All",
                                 systemImage: allSelected ? "checklist.unchecked" : "checklist.checked") {
                        self.selection = allSelected ? [] : selectable
                    }
                    Menu {
                        AssetMenuItems(actions: actions, ids: Array(selection))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            // dimmed by hand while nothing is selected: .disabled would grey it out much further
                            .opacity(selection.isEmpty ? 0.55 : 1)
                            .frame(width: 36, height: 36)
                            .tapArea(outset: 4)
                    }
                    .allowsHitTesting(!selection.isEmpty)
                    .accessibilityLabel("Actions for \(selection.count) selected")
                    .accessibilityHint(selection.isEmpty ? "Select photos first" : "")
                    Button("Done") { toggleSelect() }
                        .font(.headline)
                        .frame(height: 36)
                        .tapArea(outset: 4)
                    }
                    .padding(.horizontal, 10)
                    .glassEffect(.regular, in: .capsule)
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
            // WoofMusic's loading layout: the shape of the grid, with a light sweep, instead of a lone spinner
            GridSkeleton(columns: columns)
        }
    }

    /// One grid cell. Its own function: inside the grid's ForEach the modifier chain is too long for the type checker.
    private func cell(_ asset: AssetRef?, month: Timeline.Month, index: Int, client: ImmichClient?) -> some View {
        Thumbnail(asset: asset)
            .overlay(alignment: .bottomTrailing) {
                if let selection, let id = asset?.id {
                    let selected = selection.contains(id)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white, .tint)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .contentShape(.contextMenuPreview, .rect)
            .liftedMenu(background: nil) {
                if let asset, client != nil {
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
            // again when the month is forgotten, which a changed backup record does.
            // A loaded month asks only from its first and last cells, where the neighbouring months are needed next.
            .task(id: month.assets == nil) {
                guard let client, month.assets == nil || index == 0 || index == month.count - 1 else { return }
                await timeline.loadMonth(around: month.key, with: client)
            }
    }

    private func grid(_ months: [Timeline.Month], client: ImmichClient?) -> some View {
        // Apple Photos' square cells with 2-point gaps
        let spacing: CGFloat = 2
        return ScrollViewReader { proxy in
            following(ScrollView {
                hero
                cells(months, client: client, spacing: spacing)
            }, months: months, proxy: proxy)
        }
    }

    /// The cells with their gestures. In functions of their own: as one chain the grid was too long for the type checker.
    private func cells(_ months: [Timeline.Month], client: ImmichClient?, spacing: CGFloat) -> some View {
        // a view of its own, compared before drawing: scrolling, the scrubber and the gestures change this view's
        // state many times a second, and the cells must not be rebuilt for any of it
        GridCells(months: months, revision: timeline.revision, columns: columns, blanks: leadingBlanks(months),
                  spacing: spacing, selection: selection, menus: client != nil) { asset, month, index in
            cell(asset, month: month, index: index, client: client)
        }
        .equatable()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        // in Select mode a drag that starts sideways selects every cell it crosses; an upright one scrolls
        .gesture(SelectPan(isEnabled: selection != nil) { start, location in
            dragSelect(start: start, location: location, months: months, spacing: spacing)
        } ended: {
            drag = nil
        })
        // a representable takes .gesture only; it needs two fingers, the selection one, so the two never compete
        .gesture(ColumnPinch { location, fraction in
            pinchStart = Self.columnSteps.firstIndex(of: columns) ?? 1
            pinchAnchor = cellID(at: cellIndex(location, spacing: spacing), in: months).map { (id: $0, fraction: fraction) }
        } changed: { scale in
            pinch(scale)
        } ended: {
            pinchStart = nil
            pinchAnchor = nil
        })
        .padding(.horizontal, spacing)
        .sensoryFeedback(.selection, trigger: columns)
    }

    /// How far down the grid is scrolled, 0 to 1.
    private static func scrollFraction(_ geometry: ScrollGeometry) -> CGFloat {
        let top: CGFloat = geometry.contentInsets.top
        let range: CGFloat = geometry.contentSize.height + top + geometry.contentInsets.bottom - geometry.containerSize.height
        guard range > 0 else { return 1 }
        let offset: CGFloat = geometry.contentOffset.y + top
        return min(max(offset / range, 0), 1)
    }

    /// Where the scroll view starts and moves: the newest photos, the scrubber, a pinch's anchor, a day tapped in Months.
    private func following(_ scroll: some View, months: [Timeline.Month], proxy: ScrollViewProxy) -> some View {
        scroll
            // the scrubber's handle shows the position; the system's bar beside it made two
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(hero == nil ? .bottom : .top)
            // the anchor only holds for the first layout; the months filling in and the thumbnails loading move it
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, followsEnd { followsEnd = false }
                let moving = phase != .idle
                if moving != scrollMoving { scrollMoving = moving }
            }
            .onScrollGeometryChange(for: CGFloat.self, of: Self.scrollFraction) { _, fraction in
                metrics.fraction = fraction
            }
            .task(id: scrollMoving || scrubbing) {
                if scrollMoving || scrubbing { showsScrubber = true; return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { showsScrubber = false }
            }
            .overlay(alignment: .trailing) {
                // the fade only on the scrubber: on the scroll view it would animate the grid too
                Group {
                    if months.count > 1, showsScrubber {
                        Scrubber(months: months, proxy: proxy, metrics: metrics, scrubbing: $scrubbing)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showsScrubber)
            }
            .modifier(Jumps(grid: self, months: months, proxy: proxy, reselects: reselects))
    }

    /// The jumps to a cell: to the newest, to a pinch's anchor, to a day tapped in Months.
    private struct Jumps: ViewModifier {
        let grid: AssetGrid
        let months: [Timeline.Month]
        let proxy: ScrollViewProxy
        /// Passed in: an environment value read through a copy of the grid isn't guaranteed to be current.
        let reselects: Int

        func body(content: Content) -> some View {
            content
                .onChange(of: months.reduce(0) { $0 + ($1.assets?.count ?? $1.count) }) {
                    if grid.followsEnd { grid.scrollToEnd(months, proxy) }
                }
                .task {
                    for delay in [0.0, 0.25, 0.6] {
                        try? await Task.sleep(for: .seconds(delay))
                        guard grid.followsEnd else { return }
                        grid.scrollToEnd(months, proxy)
                    }
                }
                // the photo under the fingers stays under them while the cells change size
                .onChange(of: grid.columns) {
                    guard let anchor = grid.pinchAnchor else { return }
                    proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0.5, y: anchor.fraction))
                }
                // Photos opens at the newest, so tapping the tab again goes back down to it
                .onChange(of: reselects) {
                    guard grid.title != nil, let last = months.last else { return }
                    withAnimation(.smooth) { proxy.scrollTo("\(last.key)#\((last.assets?.count ?? last.count) - 1)", anchor: .bottom) }
                }
                // a day tapped in Months
                .onChange(of: grid.target) {
                    guard let target = grid.target, grid.level == .all else { return }
                    proxy.scrollTo("\(target)#0", anchor: .top)
                    grid.target = nil
                }
        }
    }

    /// Steps through the column counts as the fingers spread or close: no scaling in between, which made a tall lazy grid jump.
    private func pinch(_ scale: CGFloat) {
        guard let base = pinchStart else { return }
        let steps = Self.columnSteps
        let move = scale > 2 ? -2 : scale > 1.3 ? -1 : scale < 0.5 ? 2 : scale < 0.75 ? 1 : 0
        let next = steps[min(max(base + move, 0), steps.count - 1)]
        if next != columns { columns = next }
    }

    /// The cell at a point of the grid, counting the empty cells before the oldest photo.
    private func cellIndex(_ point: CGPoint, spacing: CGFloat) -> Int {
        guard gridWidth > 0 else { return 0 }
        let cell = (gridWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns) + spacing
        return max(Int(point.y / cell), 0) * columns + min(max(Int(point.x / cell), 0), columns - 1)
    }

    /// The id a cell has in the grid ("2024-05-01#3"), from its place in grid order.
    private func cellID(at index: Int, in months: [Timeline.Month]) -> String? {
        var rest = index - leadingBlanks(months)
        for month in months {
            let count = month.assets?.count ?? month.count
            if rest < count { return "\(month.key)#\(max(rest, 0))" }
            rest -= count
        }
        return months.last.map { "\($0.key)#\(max(($0.assets?.count ?? $0.count) - 1, 0))" }
    }

    private func scrollToEnd(_ months: [Timeline.Month], _ proxy: ScrollViewProxy) {
        guard hero == nil, let last = months.last else { return }
        proxy.scrollTo("\(last.key)#\((last.assets?.count ?? last.count) - 1)", anchor: .bottom)
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

    private func dragSelect(start startPoint: CGPoint, location: CGPoint, months: [Timeline.Month], spacing: CGFloat) {
        guard let selection, gridWidth > 0 else { return }
        func index(_ point: CGPoint) -> Int { cellIndex(point, spacing: spacing) }
        if drag == nil {
            // every cell in grid order, nil where the month isn't loaded yet
            dragCells = Array(repeating: nil, count: leadingBlanks(months)) + months.flatMap { month in month.assets.map { $0.map(Optional.some) } ?? Array(repeating: nil, count: month.count) }
            let flat = dragCells
            let start = index(startPoint)
            let startID = (flat[safe: start] ?? nil)?.id
            drag = (start, selection, !(startID.map(selection.contains) ?? false))
        }
        guard let drag else { return }
        let end = index(location)
        let ids = (min(drag.start, end)...max(drag.start, end)).compactMap { (dragCells[safe: $0] ?? nil)?.id }
        let next = drag.adds ? drag.base.union(ids) : drag.base.subtracting(ids)
        // only when it changed: every assignment redraws the grid's cells
        if next != self.selection { self.selection = next }
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
            session.expire()
        } catch {
            // empty for a cancelled load (the timeline changed): that's no failure to show
            let message = error.explanation
            if !message.isEmpty { self.error = message }
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

/// Where a grid is scrolled, 0 at the top and 1 at the bottom. A class of its own: it changes on every frame of a scroll,
/// and only the scrubber reads it, so the grid isn't redrawn for it.
@MainActor @Observable
final class ScrollMetrics {
    var fraction: CGFloat = 1
}

/// The cells of the grid, apart from the grid's own state, so they are rebuilt only when what they show changes.
/// `cell` is left out of the comparison: it reads the same timeline and selection the other fields stand for.
private struct GridCells<Cell: View>: View, Equatable {
    let months: [Timeline.Month]
    /// Stands for `months`, which is too large to compare on every redraw.
    let revision: Int
    let columns: Int
    let blanks: Int
    let spacing: CGFloat
    let selection: Set<String>?
    let menus: Bool
    @ViewBuilder let cell: (AssetRef?, Timeline.Month, Int) -> Cell

    static func == (a: Self, b: Self) -> Bool {
        a.revision == b.revision && a.columns == b.columns && a.blanks == b.blanks && a.spacing == b.spacing
            && a.selection == b.selection && a.menus == b.menus
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
            ForEach(0..<blanks, id: \.self) { _ in Color.clear }
            ForEach(months) { month in
                ForEach(0..<(month.assets?.count ?? month.count), id: \.self) { index in
                    cell(month.assets?[index], month, index)
                }
            }
        }
    }
}

/// Photos' scrubber: a handle on the right edge that shows where the grid is and, dragged, jumps through the months
/// with the month's name beside the finger. Only the handle takes touches, so a scroll that starts near the edge stays a scroll.
struct Scrubber: View {
    let months: [Timeline.Month]
    let proxy: ScrollViewProxy
    let metrics: ScrollMetrics
    /// Tells the grid to keep the scrubber while the finger is on it.
    @Binding var scrubbing: Bool
    /// Where the finger holds the handle, 0 to 1, and the month there.
    @State private var held: (fraction: CGFloat, title: String)?
    /// Goes false when the finger lifts or the touch is cancelled, which onEnded misses.
    @GestureState private var touching = false
    private static let handle: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let track = max(geometry.size.height - Self.handle, 1)
            let fraction = held?.fraction ?? metrics.fraction
            Capsule()
                .fill(.thinMaterial)
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                .frame(width: 8, height: Self.handle)
                .frame(width: 32, height: Self.handle, alignment: .trailing)
                .padding(.trailing, 4)
                .contentShape(.rect)
                .overlay(alignment: .trailing) {
                    if let held {
                        Text(held.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: .capsule)
                            .fixedSize()
                            .offset(x: -40)
                            .allowsHitTesting(false)
                    }
                }
                .offset(y: fraction * track)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        let fraction = min(max((value.location.y - Self.handle / 2) / track, 0), 1)
                        let month = Self.month(at: fraction, in: months)
                        let title = AssetGrid.monthTitle(month.key)
                        if held?.title != title { proxy.scrollTo("\(month.key)#0", anchor: .top) }
                        held = (fraction, title)
                    })
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
        }
        .coordinateSpace(.named("scrubber"))
        .frame(width: 44)
        .padding(.vertical, 8)
        .onChange(of: touching) { _, down in
            scrubbing = down
            if !down { held = nil }
        }
        .sensoryFeedback(.selection, trigger: held?.title)
        .accessibilityElement()
        .accessibilityLabel("Scroll through months")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 0.05 : -0.05
            let month = Self.month(at: min(max(metrics.fraction + step, 0), 1), in: months)
            proxy.scrollTo("\(month.key)#0", anchor: .top)
        }
    }

    /// The month at a point of the track, by cells rather than months: a month of 500 photos takes more of the track
    /// than one of 3, as it takes more of the scroll.
    static func month(at fraction: CGFloat, in months: [Timeline.Month]) -> Timeline.Month {
        let total = months.reduce(0) { $0 + ($1.assets?.count ?? $1.count) }
        var rest = Int(fraction * CGFloat(max(total - 1, 0)))
        for month in months {
            let count = month.assets?.count ?? month.count
            if rest < count { return month }
            rest -= count
        }
        return months[months.count - 1]
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
                if showsBadges {
                    HStack(spacing: 0) {
                        if let duration { Text(duration).overlayBadge() }
                        if let place { Image(systemName: place.symbol).overlayBadge() }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showsBadges, asset?.isFavorite == true {
                    Image(systemName: "heart.fill").overlayBadge()
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

    /// Where the photo lives; nothing to show when the server and this iPhone both have it.
    private var place: (symbol: String, spoken: String)? {
        guard backupBadge, let asset else { return nil }
        if asset.localID != nil { return ("iphone", "Only on this iPhone") }
        let backup = Backup.shared
        if backup.tracksDevice, !backup.onDeviceIDs.contains(asset.id), !backup.matchedOnDevice.contains(asset.id) { return ("icloud", "Only on the server") }
        return nil
    }

    /// "Video, 1:05, Favorite, March 3, 2024" for VoiceOver.
    private var spokenLabel: String {
        guard let asset else { return "Photo, loading" }
        var parts = [asset.isImage ? "Photo" : "Video"]
        if let duration { parts.append(duration) }
        if asset.isFavorite { parts.append("Favorite") }
        if let place { parts.append(place.spoken) }
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
            let image = await DeviceLibrary.image(localID, side: size == "thumbnail" ? 300 : 1200)
            if let image { ImageCache.store(image, for: asset.id, size: size) }
            // the cell may show another photo by now (a delete shifted the month): an old answer must not land on it
            guard !Task.isCancelled else { return }
            loaded = image
            return
        }
        guard let client = session.client else { return }
        if asset.thumbhash != nil, placeholder == nil {
            timeline?.problem = "Failed to decode the thumbhash \(asset.thumbhash ?? "")"
        }
        // a weak connection drops some requests; asking again beats leaving a grey square until the next launch
        for attempt in 0..<3 {
            do {
                let data = try await client.image(asset.id, size: size)
                guard let image = UIImage(data: data) else {
                    timeline?.problem = "Failed to read a thumbnail: \(data.count) bytes that aren't an image"
                    return
                }
                let ready = await image.byPreparingForDisplay() ?? image
                ImageCache.store(ready, for: asset.id, size: size)
                guard !Task.isCancelled else { return }
                loaded = ready
                return
            } catch let error as URLError where error.code != .cancelled && attempt < 2 {
                do { try await Task.sleep(for: .seconds(Double(attempt + 1) * 1.5)) } catch { return }
            } catch ImmichError.http(404, _) where attempt < 2 {
                // just uploaded, so the server hasn't made the thumbnail yet; or deleted on the server since this list was saved
                do { try await Task.sleep(for: .seconds(Double(attempt + 1) * 3)) } catch { return }
            } catch ImmichError.http(404, _) {
                return // stays grey: the next reload drops an item the server deleted
            } catch {
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    timeline?.report(error, while: "loading a thumbnail")
                }
                return
            }
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
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // decoded bitmaps are large; iOS empties the cache under pressure, but a fast scroll can outrun it
        cache.countLimit = 2000
        return cache
    }()

    static func image(_ id: String, size: String) -> UIImage? { images.object(forKey: "\(size):\(id)" as NSString) }
    static func store(_ image: UIImage, for id: String, size: String) { images.setObject(image, forKey: "\(size):\(id)" as NSString) }

    /// Drops every saved image of an asset after an edit changed it, in memory and on disk.
    static func forget(_ id: String, client: ImmichClient) {
        OfflineFiles.forget(id)
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

/// The scroll view a gesture's touch is in: the nearest one above the view under the finger.
@MainActor private func scrollView(under gesture: UIGestureRecognizer) -> UIScrollView? {
    guard let window = gesture.view?.window else { return nil }
    var view = window.hitTest(gesture.location(in: window), with: nil)
    while let current = view {
        if let scroll = current as? UIScrollView { return scroll }
        view = current.superview
    }
    return nil
}

/// Select mode's one-finger drag, as in Photos: a drag that starts sideways selects, one that starts upright scrolls.
/// The scroll view waits for this gesture to decide, so a drag is never both. Held near the top or bottom edge,
/// the grid scrolls on by itself and the selection follows, so it can run past the screen.
struct SelectPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    let moved: (_ start: CGPoint, _ location: CGPoint) -> Void
    let ended: () -> Void

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start = CGPoint.zero
        /// The grid's origin in the scroll view's content: a point in the scroll view minus this is a point in the grid.
        var origin = CGPoint.zero
        weak var scroll: UIScrollView?
        weak var pan: UIPanGestureRecognizer?
        var link: CADisplayLink?
        var moved: (CGPoint, CGPoint) -> Void = { _, _ in }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let move = pan.translation(in: pan.view)
            return abs(move.x) > abs(move.y)
        }

        /// Scroll views wait for this one: if it fails (an upright drag), they scroll as usual.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gesture.isEnabled && other.view is UIScrollView && other is UIPanGestureRecognizer
        }

        func startScrolling() {
            guard link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stopScrolling() {
            link?.invalidate()
            link = nil
        }

        /// Scrolls while the finger is within 70 points of the top or bottom edge, faster the closer it is.
        @objc private func tick(_ link: CADisplayLink) {
            guard let pan, let scroll, pan.state == .began || pan.state == .changed else { return stopScrolling() }
            let finger = pan.location(in: scroll)
            let onScreen = finger.y - scroll.contentOffset.y
            let top = scroll.adjustedContentInset.top + 70
            let bottom = scroll.bounds.height - scroll.adjustedContentInset.bottom - 70
            let depth = onScreen < top ? onScreen - top : onScreen > bottom ? onScreen - bottom : 0
            guard depth != 0 else { return }
            let lowest = -scroll.adjustedContentInset.top
            let highest = max(lowest, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            // up to 900 points a second
            let step = min(max(depth, -70), 70) / 70 * 900 * CGFloat(link.targetTimestamp - link.timestamp)
            let y = min(max(scroll.contentOffset.y + step, lowest), highest)
            guard y != scroll.contentOffset.y else { return }
            scroll.contentOffset.y = y
            // the finger stayed still and the cells moved under it
            let point = pan.location(in: scroll)
            moved(start, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        context.coordinator.pan = pan
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
        context.coordinator.moved = moved
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let c = context.coordinator
        c.moved = moved
        let location = context.converter.localLocation
        switch pan.state {
        case .began:
            // where the finger first touched: the gesture begins only after it has moved a little
            let travelled = pan.translation(in: pan.view)
            c.start = CGPoint(x: location.x - travelled.x, y: location.y - travelled.y)
            c.scroll = scrollView(under: pan)
            if let scroll = c.scroll {
                let point = pan.location(in: scroll)
                c.origin = CGPoint(x: point.x - location.x, y: point.y - location.y)
            }
            c.startScrolling()
            moved(c.start, location)
        case .changed:
            moved(c.start, location)
        default:
            c.stopScrolling()
            ended()
        }
    }
}

/// Two fingers pinching the grid. Stops the scroll the fingers started, and reports the point between them and how high
/// on screen it is, so the grid can keep that photo under them while the columns change.
struct ColumnPinch: UIGestureRecognizerRepresentable {
    let began: (_ location: CGPoint, _ fraction: CGFloat) -> Void
    let changed: (_ scale: CGFloat) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer { UIPinchGestureRecognizer() }

    func handleUIGestureRecognizerAction(_ pinch: UIPinchGestureRecognizer, context: Context) {
        switch pinch.state {
        case .began:
            var fraction: CGFloat = 0.5
            if let scroll = scrollView(under: pinch) {
                // turning the pan off and on cancels the scroll the two fingers began, which moved the grid under the pinch
                scroll.panGestureRecognizer.isEnabled = false
                scroll.panGestureRecognizer.isEnabled = true
                let point = pinch.location(in: scroll)
                fraction = min(max((point.y - scroll.contentOffset.y) / max(scroll.bounds.height, 1), 0), 1)
            }
            began(context.converter.localLocation, fraction)
        case .changed:
            changed(pinch.scale)
        default:
            ended()
        }
    }
}
