import Foundation

/// How the app tells a photo on this iPhone from the same photo on the server. Foundation only, so it runs in tests.
enum Matching {
    /// One answer of the server's duplicate check (POST /assets/bulk-upload-check).
    struct Check: Decodable {
        /// What the app sent: the iPhone photo's identifier.
        var id: String?
        /// "accept" (new) or "reject" (the server has it).
        var action: String
        var assetId: String?
        var isTrashed: Bool?
    }

    /// The iPhone photos that the server has (by checksum), as iPhone id → server id; a copy in the server's trash doesn't count.
    /// `checked` is every iPhone photo that got an answer, so it isn't hashed again.
    static func duplicates(in results: [Check]) -> (checked: [String], found: [String: String]) {
        var checked: [String] = [], found: [String: String] = [:]
        for result in results {
            guard let id = result.id else { continue }
            checked.append(id)
            if result.action == "reject", result.isTrashed != true, let server = result.assetId, !server.isEmpty { found[id] = server }
        }
        return (checked, found)
    }

    /// How many cells a month has: the server's photos, plus the iPhone photos only here, minus those that look like a server photo.
    static func cellCount(server: Int, pending: Set<String>, duplicates: Set<String>) -> Int {
        server + pending.count - duplicates.intersection(pending).count
    }

    /// True when a loaded month shows iPhone photos that are no longer the ones only here (a backup uploaded them, or the checksum check found them).
    static func isStale(shown: Set<String>, duplicates: Set<String>, pending: Set<String>) -> Bool {
        shown.union(duplicates.intersection(pending)) != pending
    }

    /// Splits the iPhone's not-backed-up photos into the ones the server really lacks and the ones it seems to have,
    /// told apart by kind and capture time (within a second), one server photo per iPhone photo.
    /// It is a guess for photos the checksum check hasn't reached yet; the backup itself always decides by checksum.
    static func separate(_ device: [AssetRef], from server: [AssetRef]) -> (only: [AssetRef], same: Set<String>, serverIDs: Set<String>) {
        func second(_ date: Date?) -> Int { Int((date ?? .distantPast).timeIntervalSince1970.rounded()) }
        var free: [Int: [AssetRef]] = [:]
        for asset in server where asset.date != nil { free[second(asset.date), default: []].append(asset) }
        var only: [AssetRef] = [], same = Set<String>(), serverIDs = Set<String>()
        for asset in device {
            let near = (-1...1).map { second(asset.date) + $0 }
            let found = near.lazy.compactMap { key in
                free[key]?.firstIndex { $0.isImage == asset.isImage && abs($0.date!.timeIntervalSince(asset.date ?? .distantPast)) < 1 }.map { (key, $0) }
            }.first
            if let (key, index) = found, let localID = asset.localID {
                serverIDs.insert(free[key]![index].id)
                free[key]!.remove(at: index)
                same.insert(localID)
            } else {
                only.append(asset)
            }
        }
        return (only, same, serverIDs)
    }
}
