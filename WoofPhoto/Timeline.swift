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
    private(set) var months: [Month]? {
        // kept ready: the viewer and grid read `assets` many times per frame
        didSet { assets = Self.flatten(months) }
    }
    private(set) var assets: [AssetRef] = []
    /// The last failure, shown under the grid until tapped.
    var problem: String?
    /// Month loads in flight. They belong to the timeline, not to the cell that asked, so scrolling past that cell doesn't cancel them.
    private var loading: [String: Task<Void, Never>] = [:]
    private var saving: Task<Void, Never>?

    init(_ query: TimelineQuery) {
        self.query = query
    }

    init(assets: [AssetRef]) {
        query = nil
        months = [Month(key: "all", count: assets.count, assets: assets)]
        self.assets = assets
    }

    /// Months that are already complete, like the photos on this iPhone.
    init(months: [Month]) {
        query = nil
        self.months = months
        assets = Self.flatten(months)
    }

    private static func flatten(_ months: [Month]?) -> [AssetRef] { months?.flatMap { $0.assets ?? [] } ?? [] }

    /// Photos only on this iPhone, shown in the Library next to the server's.
    private var local: [String: [AssetRef]] { query == .library ? Backup.shared.pendingByMonth : [:] }
    var count: Int { months?.reduce(0) { $0 + $1.count } ?? 0 }

    func reload(with client: ImmichClient) async throws {
        guard let query else { return }
        var counts = Dictionary(try await client.buckets(query).map { ($0.timeBucket, $0.count) }) { $0 + $1 }
        for (key, assets) in local { counts[key, default: 0] += assets.count }
        // keep months already loaded, so a reload after an edit doesn't blank the screen
        let old = Dictionary(uniqueKeysWithValues: (months ?? []).map { ($0.key, $0) })
        // nothing new on the server: leave the grid alone, so it doesn't redraw for the same answer
        // a month whose photos only on this iPhone changed (a backup uploaded them) is stale even when its total is the same
        func localChanged(_ month: Month) -> Bool {
            month.assets.map { $0.filter { $0.localID != nil }.count != (local[month.key]?.count ?? 0) } ?? false
        }
        if let months, months.count == counts.count, months.allSatisfy({ counts[$0.key] == $0.count && !localChanged($0) }) {
            startSavingForOffline(client)
            return
        }
        months = counts.keys.sorted().map { key in
            let kept = old[key].flatMap { $0.count == counts[key] && !localChanged($0) ? $0.assets : nil }
            return Month(key: key, count: counts[key] ?? 0, assets: kept)
        }
        startSavingForOffline(client)
    }

    /// On Wi-Fi, in the background, saves the months not scrolled to yet so the whole library opens offline.
    /// Off the main actor, so scrolling never waits for it, and started once per reload, not once per change in the grid.
    private func startSavingForOffline(_ client: ImmichClient) {
        guard query == .library, let keys = months?.map(\.key) else { return }
        saving?.cancel()
        saving = Task.detached(priority: .utility) { await client.saveMonthsForOffline(.library, keys: keys) }
    }

    func loadMonth(_ key: String, with client: ImmichClient) async {
        guard let query, let index = months?.firstIndex(where: { $0.key == key }), months?[index].assets == nil else { return }
        // a cell that appears while another is still loading the month waits for that load; before, it gave up and the month stayed grey
        if let running = loading[key] { return await running.value }
        let task = Task {
            defer { loading[key] = nil }
            // a failed month stays grey and is retried when its cells appear again
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
        loading[key] = task
        await task.value
    }

    /// A month and the two beside it, so scrolling into the next month already shows its thumbhashes.
    func loadMonth(around key: String, with client: ImmichClient) async {
        await loadMonth(key, with: client)
        guard let months, let index = months.firstIndex(where: { $0.key == key }) else { return }
        for neighbour in [index + 1, index - 1] where months.indices.contains(neighbour) {
            guard !Task.isCancelled else { return }
            await loadMonth(months[neighbour].key, with: client)
        }
    }

    /// Loads the months before and after the one holding `id`, so the viewer can page across months.
    func loadNeighbours(of id: String, with client: ImmichClient) async {
        guard let months, let index = months.firstIndex(where: { $0.assets?.contains { $0.id == id } == true }) else { return }
        for neighbour in [index - 1, index + 1] where months.indices.contains(neighbour) {
            await loadMonth(months[neighbour].key, with: client)
        }
    }

    func update(_ id: String, _ change: (inout AssetRef) -> Void) { update([id], change) }

    /// Changes several assets at once. `months` is assigned once: each assignment flattens the whole library.
    func update(_ ids: Set<String>, _ change: (inout AssetRef) -> Void) {
        guard var changed = months else { return }
        for m in changed.indices {
            guard let assets = changed[m].assets else { continue }
            for a in assets.indices where ids.contains(assets[a].id) { change(&changed[m].assets![a]) }
        }
        months = changed
    }

    /// Forgets the loaded month holding `id`, so its cells load it again.
    func invalidate(containing id: String) {
        guard let index = months?.firstIndex(where: { $0.assets?.contains { $0.id == id } == true }) else { return }
        months?[index].assets = nil
    }

    /// Takes assets out after they were deleted, hidden or moved, without reloading.
    func remove(_ ids: Set<String>) {
        guard var changed = months else { return }
        for m in changed.indices {
            guard let assets = changed[m].assets else { continue }
            let kept = assets.filter { !ids.contains($0.id) }
            changed[m].assets = kept
            changed[m].count = kept.count
        }
        changed.removeAll { $0.count == 0 && $0.assets != nil }
        months = changed
    }

    func report(_ error: Error, while step: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let code = (error as? URLError).map { " (URLError \($0.code.rawValue))" }
            ?? (error is DecodingError ? "\n\(String(describing: error).prefix(300))" : "")
        problem = "Failed \(step): \(error.explanation)\(code)"
    }
}
