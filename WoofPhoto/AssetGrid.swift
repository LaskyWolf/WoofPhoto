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

    @Environment(Session.self) private var session
    @AppStorage("library.columns") private var columns = 5
    @State private var level = Level.all
    @State private var target: String?
    @State private var error: String?
    @State private var viewing: AssetRef?
    @Namespace private var zoom

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
                    if showsLevels, timeline.months?.isEmpty == false {
                        Picker("Show", selection: $level) {
                            ForEach(Level.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                        .padding(.bottom, 4)
                    }
                }
            }
            .environment(timeline)
            .task { await reload() }
            .fullScreenCover(item: $viewing) { asset in
                Viewer(timeline: timeline, start: asset)
                    .navigationTransition(.zoom(sourceID: asset.id, in: zoom))
            }
    }

    @ViewBuilder private var content: some View {
        if let months = timeline.months, let client = session.client {
            if months.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
            } else {
                switch level {
                case .all: grid(months, client: client)
                case .months: cards(months.map { CardGroup(key: $0.key, title: Self.monthTitle($0.key), months: [$0]) }, client: client)
                case .years: cards(Self.years(months), client: client)
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

    private func grid(_ months: [Timeline.Month], client: ImmichClient) -> some View {
        let spacing = 1.5
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(months) { month in
                        ForEach(0..<(month.assets?.count ?? month.count), id: \.self) { index in
                            let asset = month.assets?[index]
                            Thumbnail(asset: asset)
                                .matchedTransitionSource(id: asset?.id ?? "\(month.key)#\(index)", in: zoom)
                                .id("\(month.key)#\(index)")
                                .onTapGesture { viewing = asset }
                                .task {
                                    if month.assets == nil { await timeline.loadMonth(month.key, with: client) }
                                }
                        }
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .trailing) {
                if months.count > 1 { Scrubber(months: months, proxy: proxy) }
            }
            .task {
                guard let target else { return }
                await Task.yield()
                proxy.scrollTo("\(target)#0", anchor: .top)
                self.target = nil
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            let steps = Self.columnSteps
            let current = steps.firstIndex(of: columns) ?? 1
            let next = value.magnification > 1.15 ? current - 1 : value.magnification < 0.87 ? current + 1 : current
            withAnimation(.snappy) { columns = steps[min(max(next, 0), steps.count - 1)] }
        })
    }

    /// A Years or Months card: the group's first photo, large, with its title.
    struct CardGroup {
        var key: String
        var title: String
        var months: [Timeline.Month]
    }

    private func cards(_ groups: [CardGroup], client: ImmichClient) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groups, id: \.key) { group in
                        let month = group.months.last!
                        Button {
                            target = month.key
                            withAnimation(.snappy) { level = level == .years ? .months : .all }
                        } label: {
                            Thumbnail(asset: month.assets?.first, size: "preview", square: false)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .overlay(alignment: .bottomLeading) {
                                    Text(group.title)
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.6), radius: 6)
                                        .padding()
                                }
                                .clipShape(.rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .id(month.key)
                        .task { await timeline.loadMonth(month.key, with: client) }
                    }
                }
                .padding(.horizontal)
            }
            .defaultScrollAnchor(.bottom)
            .task {
                guard let target else { return }
                await Task.yield()
                proxy.scrollTo(target, anchor: .center)
                self.target = nil
            }
        }
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

    @Environment(Session.self) private var session
    @Environment(Timeline.self) private var timeline: Timeline?
    @State private var loaded: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(square ? 1 : nil, contentMode: .fit)
            .overlay {
                if let image = loaded ?? asset.flatMap({ ImageCache.image($0.id, size: size) }) ?? placeholder {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(duration).overlayBadge()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset?.isFavorite == true {
                    Image(systemName: "heart.fill").overlayBadge()
                }
            }
            .overlay(alignment: .topTrailing) {
                if let count = asset?.stackCount, count > 1 {
                    Label("\(count)", systemImage: "square.stack.fill").overlayBadge()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(asset?.isImage == false ? "Video" : "Photo")
            .task(id: asset?.id) { await load() }
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
        loaded = nil
        guard let asset, let client = session.client, ImageCache.image(asset.id, size: size) == nil else { return }
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

    static func placeholder(id: String, hash: String) -> UIImage? {
        let key = "hash:\(id)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = ThumbHash.image(base64: hash) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}
