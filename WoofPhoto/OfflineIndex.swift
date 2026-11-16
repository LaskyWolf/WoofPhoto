import Foundation

/// The text of every photo the app has seen details for, so search still works without the server.
/// It learns from photos opened in the viewer, kept offline, and returned by any search.
/// It cannot match what the server reads from the picture itself (smart search, text in photos).
actor OfflineIndex {
    static let shared = OfflineIndex()

    struct Entry: Codable {
        var id: String
        var video: Bool
        var hash: String?
        var taken: Date?
        var text: String
        /// True once the text came from the full details, not a search result.
        var detailed: Bool
    }

    private var entries: [String: Entry]?
    private var saving = false
    private static let file = URL.applicationSupportDirectory.appending(path: "offline/index.json")

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let list = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: Self.file))) ?? []
        let loaded = Dictionary(list.map { ($0.id, $0) }) { $1 }
        entries = loaded
        return loaded
    }

    func learn(_ assets: [Asset]) {
        // changed in place: a local copy of the whole index would be copied again on its first write, for every photo opened
        _ = load()
        var changed = false
        for asset in assets {
            let detailed = asset.exifInfo != nil
            // a search result has no description or place: it never replaces what the details said
            if entries?[asset.id]?.detailed == true, !detailed { continue }
            entries?[asset.id] = Entry(id: asset.id, video: asset.type == "VIDEO", hash: asset.thumbhash, taken: asset.date,
                                  text: Self.text(of: asset), detailed: detailed)
            changed = true
        }
        guard changed else { return }
        scheduleSave()
    }

    func search(_ text: String) -> [AssetRef] {
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        return load().values.filter { Self.matches($0.text, words) }
            .sorted { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
            .prefix(2000)
            .map { AssetRef(id: $0.id, isImage: !$0.video, thumbhash: $0.hash, date: $0.taken) }
    }

    func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// Writes at most once every few seconds, however many photos were opened meanwhile.
    private func scheduleSave() {
        guard !saving else { return }
        saving = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            saving = false
            guard let entries else { return }
            OfflineFiles.prepare()
            try? JSONEncoder().encode(Array(entries.values)).write(to: Self.file, options: .completeFileProtection)
        }
    }

    // MARK: Text

    /// File name, caption, place, camera, people and the date as words ("2024 may"), all lowercase.
    nonisolated static func text(of asset: Asset) -> String {
        var parts = [asset.originalFileName, asset.exifInfo?.description, asset.exifInfo?.city, asset.exifInfo?.state,
                     asset.exifInfo?.country, asset.exifInfo?.make, asset.exifInfo?.model]
        parts += (asset.people ?? []).map(\.name)
        parts.append(asset.date?.formatted(.dateTime.year().month(.wide)))
        return parts.compactMap { $0 }.joined(separator: " ").lowercased()
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    nonisolated static func matches(_ text: String, _ words: [String]) -> Bool {
        words.allSatisfy { text.contains($0) }
    }

    #if DEBUG
    static func selfCheck() {
        let text = "img_0042.heic a day in rome italy apple iphone 15 2024 may"
        assert(matches(text, words("Rome 2024")))
        assert(!matches(text, words("paris")))
        assert(words("  ").isEmpty)
    }
    #endif
}
