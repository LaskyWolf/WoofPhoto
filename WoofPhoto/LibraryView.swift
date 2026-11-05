import SwiftUI

/// The timeline like the Photos app: one square grid, oldest at the top, newest at the bottom.
/// Each month's photos are fetched the first time one of its cells scrolls into view.
@MainActor @Observable
final class Library {
    var months: [TimeBucket]?
    /// The last failure while loading months or thumbnails, shown under the grid.
    var problem: String?
    private(set) var assets: [String: BucketAssets] = [:]
    private var loading: Set<String> = []

    func loadMonths(with client: ImmichClient) async throws {
        months = try await client.buckets().sorted { $0.timeBucket < $1.timeBucket }
    }

    func loadMonth(_ key: String, with client: ImmichClient) async {
        guard assets[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        // a failed or cancelled month stays grey and is retried when its cells appear again
        do {
            assets[key] = try await client.bucket(key, order: "asc")
        } catch {
            report(error, while: "loading \(key.prefix(7))")
        }
    }

    func report(_ error: Error, while step: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let code = (error as? URLError).map { " (URLError \($0.code.rawValue))" }
            ?? (error is DecodingError ? "\n\(String(describing: error).prefix(300))" : "")
        problem = "Failed \(step): \(error.explanation)\(code)"
    }
}

struct LibraryView: View {
    /// Pinching steps through these column counts, like the Photos grid.
    static let columnSteps = [3, 5, 9]

    @Environment(Session.self) private var session
    @State private var library = Library()
    @State private var error: String?
    @State private var showsAccount = false
    @AppStorage("library.columns") private var columns = 5

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .navigationSubtitle(library.months.map { "\($0.reduce(0) { $0 + $1.count }.formatted()) Items" } ?? "")
                .toolbar {
                    Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
                }
                .sheet(isPresented: $showsAccount) {
                    NavigationStack {
                        SpikesView().toolbar {
                            Button("Done", role: .close) { showsAccount = false }
                        }
                    }
                }
        }
        .task { await loadMonths() }
    }

    @ViewBuilder private var content: some View {
        if let months = library.months, let client = session.client {
            if months.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("Photos uploaded to your Immich server appear here."))
            } else {
                grid(months, client: client)
            }
        } else if let error {
            ContentUnavailableView {
                Label("Can't Load the Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await loadMonths() } }
            }
        } else {
            ProgressView()
        }
    }

    private func grid(_ months: [TimeBucket], client: ImmichClient) -> some View {
        let spacing = 1.5
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                ForEach(months, id: \.timeBucket) { month in
                    let assets = library.assets[month.timeBucket]
                    ForEach(0..<(assets?.id.count ?? month.count), id: \.self) { index in
                        Thumbnail(assets: assets, index: index)
                            .task {
                                if assets == nil { await library.loadMonth(month.timeBucket, with: client) }
                            }
                    }
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
            if let problem = library.problem {
                Text(problem)
                    .font(.footnote)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .onTapGesture { library.problem = nil }
            }
        }
        .environment(library)
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            let steps = Self.columnSteps
            let current = steps.firstIndex(of: columns) ?? 1
            let next = value.magnification > 1.15 ? current - 1 : value.magnification < 0.87 ? current + 1 : current
            withAnimation(.snappy) { columns = steps[min(max(next, 0), steps.count - 1)] }
        })
    }

    private func loadMonths() async {
        guard let client = session.client else { return }
        error = nil
        do {
            try await library.loadMonths(with: client)
        } catch ImmichError.http(401, _) {
            session.signOut()
        } catch {
            self.error = error.explanation
        }
    }
}

/// One grid cell: grey until its month loads, then the blurred thumbhash, then the real thumbnail.
struct Thumbnail: View {
    let assets: BucketAssets?
    let index: Int

    @Environment(Session.self) private var session
    @Environment(Library.self) private var library
    @State private var loaded: UIImage?

    private var id: String? { assets?.id[index] }

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = loaded ?? id.flatMap(ImageCache.thumbnail) ?? placeholder {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(isImage ? "Photo" : "Video")
            .task(id: id) { await load() }
    }

    private var isImage: Bool { assets?.isImage?[index] ?? true }

    private var placeholder: UIImage? {
        guard let id, let hash = assets?.thumbhash?[index] else { return nil }
        return ImageCache.placeholder(id: id, hash: hash)
    }

    /// "0:01:05.120000" becomes "1:05", like the Photos grid.
    private var duration: String? {
        guard !isImage, let text = assets?.duration?[index] ?? nil else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        let seconds = Int(parts[0] * 3600 + parts[1] * 60 + parts[2].rounded())
        let clock = Duration.seconds(seconds)
        return clock.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func load() async {
        guard let id, let client = session.client, ImageCache.thumbnail(id) == nil else { return }
        if let hash = assets?.thumbhash?[index] ?? nil, placeholder == nil {
            library.problem = "Failed to decode the thumbhash \(hash)"
        }
        do {
            let data = try await client.thumbnail(id)
            guard let image = UIImage(data: data) else {
                library.problem = "Failed to read a thumbnail: \(data.count) bytes that aren't an image"
                return
            }
            let ready = await image.byPreparingForDisplay() ?? image
            ImageCache.store(ready, for: id)
            loaded = ready
        } catch {
            library.report(error, while: "loading a thumbnail")
        }
    }
}

/// Decoded images kept in memory, so scrolling back doesn't decode them again. iOS empties it under memory pressure.
/// The downloaded files themselves stay in URLCache on disk (see WoofPhotoApp).
enum ImageCache {
    private static let images = NSCache<NSString, UIImage>()

    static func thumbnail(_ id: String) -> UIImage? { images.object(forKey: id as NSString) }
    static func store(_ image: UIImage, for id: String) { images.setObject(image, forKey: id as NSString) }

    static func placeholder(id: String, hash: String) -> UIImage? {
        let key = "hash:\(id)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = ThumbHash.image(base64: hash) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}
