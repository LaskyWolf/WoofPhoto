import Foundation

/// The assets a grid shows, month by month, oldest first like Photos.
/// A server timeline loads each month the first time it is needed; a fixed list (search results, a memory) is one loaded month.
@MainActor @Observable
final class Timeline {
    struct Month: Identifiable {
        let key: String
        var count: Int
        var assets: [AssetRef]?
        var id: String { key }
    }

    let query: TimelineQuery?
    private(set) var months: [Month]?
    /// The last failure, shown under the grid until tapped.
    var problem: String?
    private var loading: Set<String> = []

    init(_ query: TimelineQuery) {
        self.query = query
    }

    init(assets: [AssetRef]) {
        query = nil
        months = [Month(key: "all", count: assets.count, assets: assets)]
    }

    var assets: [AssetRef] { months?.flatMap { $0.assets ?? [] } ?? [] }

    /// Photos only on this iPhone, shown in the Library next to the server's.
    private var local: [String: [AssetRef]] { query == .library ? Backup.shared.pendingByMonth : [:] }
    var count: Int { months?.reduce(0) { $0 + $1.count } ?? 0 }

    func reload(with client: ImmichClient) async throws {
        guard let query else { return }
        var counts = Dictionary(try await client.buckets(query).map { ($0.timeBucket, $0.count) }) { $0 + $1 }
        for (key, assets) in local { counts[key, default: 0] += assets.count }
        // keep months already loaded, so a reload after an edit doesn't blank the screen
        let old = Dictionary(uniqueKeysWithValues: (months ?? []).map { ($0.key, $0) })
        months = counts.keys.sorted().map { key in
            let kept = old[key].flatMap { $0.count == counts[key] ? $0.assets : nil }
            return Month(key: key, count: counts[key] ?? 0, assets: kept)
        }
    }

    func loadMonth(_ key: String, with client: ImmichClient) async {
        guard let query, let index = months?.firstIndex(where: { $0.key == key }), months?[index].assets == nil,
              !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        // a failed or cancelled month stays grey and is retried when its cells appear again
        do {
            var assets = try await client.bucket(key, query, order: "asc").refs
            if let device = local[key] {
                assets = (assets + device).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            }
            if let index = months?.firstIndex(where: { $0.key == key }) {
                months?[index].assets = assets
                months?[index].count = assets.count
            }
        } catch {
            report(error, while: "loading \(key.prefix(7))")
        }
    }

    /// Loads the months before and after the one holding `id`, so the viewer can page across months.
    func loadNeighbours(of id: String, with client: ImmichClient) async {
        guard let months, let index = months.firstIndex(where: { $0.assets?.contains { $0.id == id } == true }) else { return }
        for neighbour in [index - 1, index + 1] where months.indices.contains(neighbour) {
            await loadMonth(months[neighbour].key, with: client)
        }
    }

    func update(_ id: String, _ change: (inout AssetRef) -> Void) {
        guard let months else { return }
        for m in months.indices {
            if let a = months[m].assets?.firstIndex(where: { $0.id == id }) {
                change(&self.months![m].assets![a])
                return
            }
        }
    }

    /// Takes assets out after they were deleted, hidden or moved, without reloading.
    func remove(_ ids: Set<String>) {
        guard months != nil else { return }
        for m in months!.indices {
            guard let assets = months![m].assets else { continue }
            let kept = assets.filter { !ids.contains($0.id) }
            months![m].assets = kept
            months![m].count = kept.count
        }
        months!.removeAll { $0.count == 0 && $0.assets != nil }
    }

    func report(_ error: Error, while step: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let code = (error as? URLError).map { " (URLError \($0.code.rawValue))" }
            ?? (error is DecodingError ? "\n\(String(describing: error).prefix(300))" : "")
        problem = "Failed \(step): \(error.explanation)\(code)"
    }
}
