import CoreLocation
import MediaPlayer
import SwiftUI
import Vision

// MARK: - Pets

/// Cats and dogs found on the device with Apple's Vision, because Immich recognises only people.
/// The scan reads each thumbnail once and remembers the result, so later scans only look at new photos.
@MainActor @Observable
final class Pets {
    static let shared = Pets()

    struct Record: Codable {
        var scanned: Set<String> = []
        var cats: [String] = []
        var dogs: [String] = []
    }

    private(set) var record: Record
    private(set) var progress: (done: Int, total: Int)?
    private var task: Task<Void, Never>?
    private static let url = URL.applicationSupportDirectory.appending(path: "pets.json")

    private init() {
        record = (try? JSONDecoder().decode(Record.self, from: Data(contentsOf: Self.url))) ?? Record()
    }

    var isScanning: Bool { task != nil }

    func scan(with client: ImmichClient) {
        guard task == nil else { return }
        task = Task {
            defer { task = nil; progress = nil }
            let timeline = Timeline(.library)
            guard (try? await timeline.reload(with: client)) != nil else { return }
            for month in timeline.months ?? [] { await timeline.loadMonth(month.key, with: client) }
            let photos = timeline.assets.filter { $0.isImage && $0.localID == nil && !record.scanned.contains($0.id) }
            for (done, asset) in photos.enumerated() {
                if Task.isCancelled { break }
                progress = (done, photos.count)
                guard let data = try? await client.image(asset.id) else { continue }
                let animals = await Self.animals(in: data)
                if animals.contains("Cat") { record.cats.append(asset.id) }
                if animals.contains("Dog") { record.dogs.append(asset.id) }
                record.scanned.insert(asset.id)
                if done % 50 == 0 { save() }
            }
            save()
        }
    }

    func stop() { task?.cancel() }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: Self.url)
    }

    /// "Cat" and "Dog" labels Vision is fairly sure about.
    nonisolated static func animals(in data: Data) async -> Set<String> {
        let request = VNRecognizeAnimalsRequest()
        try? VNImageRequestHandler(data: data).perform([request])
        let labels = (request.results ?? []).flatMap(\.labels).filter { $0.confidence > 0.7 }.map(\.identifier)
        return Set(labels)
    }
}

/// The Pets part of People: one group per kind of animal.
struct PetsSection: View {
    @Environment(Session.self) private var session
    @State private var pets = Pets.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pets").font(.title3.bold())
            HStack(spacing: 16) {
                pet("Cats", ids: pets.record.cats, symbol: "cat")
                pet("Dogs", ids: pets.record.dogs, symbol: "dog")
            }
            if let progress = pets.progress {
                ProgressView("Looking for pets in \(progress.done) of \(progress.total) photos", value: Double(progress.done), total: Double(max(progress.total, 1)))
                Button("Stop", role: .destructive) { pets.stop() }
            } else {
                Button(pets.record.scanned.isEmpty ? "Find Pets in My Photos" : "Look for New Pets") {
                    if let client = session.client { pets.scan(with: client) }
                }
                Text("WoofPhoto looks at each photo on this iPhone. Telling two dogs apart isn't possible yet, so pets are grouped by kind.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.cardRadius))
        .padding(.horizontal, Tokens.screenPadding)
    }

    private func pet(_ title: String, ids: [String], symbol: String) -> some View {
        NavigationLink {
            FixedGridScreen(title: title, assets: ids.map { AssetRef(id: $0) })
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let first = ids.last {
                        Thumbnail(asset: AssetRef(id: first))
                    } else {
                        Image(systemName: symbol).font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(.circle)
                Text("\(title) (\(ids.count))").font(.subheadline)
            }
        }
        .buttonStyle(.plain)
        .disabled(ids.isEmpty)
    }
}

// MARK: - Trips

/// Trips: runs of photos taken far from home, grouped by date. Home is where most photos were taken.
struct TripsView: View {
    struct Trip: Identifiable {
        var title: String
        var start: Date
        var assets: [AssetRef]
        var id: String { assets.first?.id ?? title }
    }

    /// Finding trips reads every month, so the result is kept for the session.
    static var found: [Trip]?

    @Environment(Session.self) private var session
    @State private var trips = TripsView.found
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(trips ?? []) { TripCard(trip: $0) }
            }
            .padding()
        }
        .overlay {
            if trips == nil, error == nil { ProgressView("Finding trips…") }
            if trips?.isEmpty == true { ContentUnavailableView("No Trips", systemImage: "airplane", description: Text("Trips appear when photos have a location far from home.")) }
            if let error { ContentUnavailableView("Can't Find Trips", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
        .navigationTitle("Trips")
        .task {
            guard trips == nil, let client = session.client else { return }
            do {
                trips = try await Self.find(client)
                Self.found = trips
            } catch {
                self.error = error.explanation
            }
        }
    }

    private struct Place {
        var ref: AssetRef
        var latitude: Double
        var longitude: Double
        var city: String?
        var country: String?
    }

    static func find(_ client: ImmichClient) async throws -> [Trip] {
        var query = TimelineQuery.library
        query.params["withCoordinates"] = "true"
        var places: [Place] = []
        for bucket in try await client.buckets(query) {
            let month: LocatedBucket = try await client.get("/timeline/bucket", query: query.params.merging(["timeBucket": bucket.timeBucket, "order": "asc"]) { $1 })
            let refs = month.assets.refs
            for (i, ref) in refs.enumerated() {
                guard let lat = month.latitude?[safe: i] ?? nil, let lon = month.longitude?[safe: i] ?? nil else { continue }
                places.append(Place(ref: ref, latitude: lat, longitude: lon, city: month.city?[safe: i] ?? nil, country: month.country?[safe: i] ?? nil))
            }
        }
        places.sort { ($0.ref.date ?? .distantPast) < ($1.ref.date ?? .distantPast) }

        // home: the 50 km cell with the most photos
        func cell(_ place: Place) -> String { "\(Int(place.latitude * 2)),\(Int(place.longitude * 2))" }
        let counts = Dictionary(places.map { (cell($0), 1) }, uniquingKeysWith: +)
        let homeCell = counts.max { $0.value < $1.value }?.key
        guard let home = places.first(where: { cell($0) == homeCell }) else { return [] }
        let homeLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)

        var trips: [Trip] = []
        var current: [Place] = []
        func close() {
            // a trip needs at least 10 photos; its title is the place that appears most
            if current.count >= 10, let start = current.first?.ref.date {
                let names = current.compactMap { $0.city ?? $0.country }
                let title = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key ?? "Trip"
                trips.append(Trip(title: title, start: start, assets: current.map(\.ref)))
            }
            current = []
        }
        for place in places {
            let away = CLLocation(latitude: place.latitude, longitude: place.longitude).distance(from: homeLocation) > 100_000
            let gap = (place.ref.date ?? .distantPast).timeIntervalSince(current.last?.ref.date ?? .distantPast) > 3 * 86400
            if !away || gap { close() }
            if away { current.append(place) }
        }
        close()
        return trips.reversed()
    }
}

/// A trip's first photo, wide, with its place and date on it.
struct TripCard: View {
    let trip: TripsView.Trip
    var width: CGFloat?

    var body: some View {
        NavigationLink {
            FixedGridScreen(title: trip.title, assets: trip.assets)
        } label: {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(width: width)
                .overlay { Thumbnail(asset: trip.assets.first, size: "preview") }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(trip.start.formatted(.dateTime.month(.wide).year())) · \(trip.assets.count) items").font(.caption)
                        Text(trip.title).font(.title3.bold()).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(.rect(cornerRadius: Tokens.cardRadius))
        }
        .buttonStyle(ZoomPressStyle(scale: 0.97))
    }
}

/// The Trips section of Collections: wide cards in a row.
struct TripsRow: View {
    @Environment(Session.self) private var session
    @State private var trips = TripsView.found

    var body: some View {
        Group {
            if let trips, trips.isEmpty {
                Text("Trips appear when photos have a location far from home.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.screenPadding)
            } else if let trips {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(trips.prefix(10)) { TripCard(trip: $0, width: 260) }
                    }
                    .padding(.horizontal, Tokens.screenPadding)
                }
                .scrollIndicators(.hidden)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task {
            guard trips == nil, let client = session.client else { return }
            trips = (try? await TripsView.find(client)) ?? []
            TripsView.found = trips
        }
    }
}

/// A timeline month with the location columns Trips needs.
private struct LocatedBucket: Decodable {
    var assets: BucketAssets
    var latitude: [Double?]?
    var longitude: [Double?]?
    var city: [String?]?
    var country: [String?]?

    init(from decoder: Decoder) throws {
        assets = try BucketAssets(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        latitude = try? container.decode([Double?].self, forKey: .latitude)
        longitude = try? container.decode([Double?].self, forKey: .longitude)
        city = try? container.decode([String?].self, forKey: .city)
        country = try? container.decode([String?].self, forKey: .country)
    }

    private enum Keys: String, CodingKey {
        case latitude, longitude, city, country
    }
}

// MARK: - Memory movies

/// A memory played as a movie: a title card, then each photo slowly zooming and cross-fading,
/// with a song from the Music library if one was chosen.
struct MemoryMovie: View {
    let title: String
    let assets: [AssetRef]

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var index = -1
    @State private var image: UIImage?
    @State private var zoomed = false
    @State private var picksSong = false
    @State private var song: MPMediaItemCollection?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if index < 0 {
                VStack(spacing: 8) {
                    Text(title).font(.largeTitle.bold())
                    if let date = assets.first?.date { Text(date.formatted(.dateTime.day().month(.wide).year())).font(.title3) }
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(zoomed ? 1.15 : 1)
                    .ignoresSafeArea()
                    .id(index)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                Button("Music", systemImage: "music.note") { picksSong = true }
                Button("Close", systemImage: "xmark") { dismiss() }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .foregroundStyle(.white)
            .padding()
        }
        .statusBarHidden()
        .sheet(isPresented: $picksSong) {
            SongPicker { collection in
                song = collection
                let player = MPMusicPlayerController.applicationMusicPlayer
                player.setQueue(with: collection)
                player.play()
            }
        }
        .onDisappear { if song != nil { MPMusicPlayerController.applicationMusicPlayer.stop() } }
        .task {
            let photos = assets.filter(\.isImage)
            guard !photos.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                let next = (index + 1) % photos.count
                let loaded = await Still.load(photos[next].id, size: "preview", client: session.client)
                zoomed = false
                withAnimation(.easeInOut(duration: 1.2)) {
                    image = loaded
                    index = next
                }
                withAnimation(.linear(duration: 4)) { zoomed = true }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

struct SongPicker: UIViewControllerRepresentable {
    let onPick: (MPMediaItemCollection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItemCollection) -> Void
        init(onPick: @escaping (MPMediaItemCollection) -> Void) { self.onPick = onPick }

        func mediaPicker(_ picker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            onPick(collection)
            picker.dismiss(animated: true)
        }

        func mediaPickerDidCancel(_ picker: MPMediaPickerController) { picker.dismiss(animated: true) }
    }
}
