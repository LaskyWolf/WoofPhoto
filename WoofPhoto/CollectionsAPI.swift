import Foundation

/// Endpoints and models behind the Collections tab: albums, people, places, memories, search-based collections,
/// Recently Deleted, Hidden, Duplicates and partner sharing.
extension ImmichClient {
    // MARK: Albums

    /// Every album the user owns or was invited to. The filter parameter was renamed between server versions,
    /// so shared albums are picked out on the device with `Album.shared`.
    func albums() async throws -> [Album] {
        try await get("/albums")
    }

    func album(_ id: String) async throws -> Album {
        try await get("/albums/\(id)")
    }

    func createAlbum(_ name: String, assets: [String] = []) async throws -> Album {
        try await fetch("POST", "/albums", body: ["albumName": name, "assetIds": assets])
    }

    /// albumName, description, albumThumbnailAssetId, isActivityEnabled.
    func updateAlbum(_ id: String, _ fields: [String: Any]) async throws {
        try await call("PATCH", "/albums/\(id)", body: fields)
    }

    func deleteAlbum(_ id: String) async throws {
        try await call("DELETE", "/albums/\(id)")
    }

    func addToAlbum(_ id: String, assets: [String]) async throws {
        try await call("PUT", "/albums/\(id)/assets", body: ["ids": assets])
        await History.shared.record(.addedToAlbum, assets, albumID: id)
    }

    func removeFromAlbum(_ id: String, assets: [String]) async throws {
        try await call("DELETE", "/albums/\(id)/assets", body: ["ids": assets])
        await History.shared.record(.removedFromAlbum, assets, albumID: id)
    }

    func activities(album: String) async throws -> [Activity] {
        try await get("/activities", query: ["albumId": album])
    }

    /// A like when `comment` is nil.
    func addActivity(album: String, comment: String?) async throws {
        var body: [String: Any] = ["albumId": album, "type": comment == nil ? "like" : "comment"]
        if let comment { body["comment"] = comment }
        try await call("POST", "/activities", body: body)
    }

    func deleteActivity(_ id: String) async throws {
        try await call("DELETE", "/activities/\(id)")
    }

    func me() async throws -> User {
        try await get("/users/me")
    }

    // MARK: People

    func people() async throws -> [Person] {
        let response: PeopleResponse = try await get("/people", query: ["withHidden": "true", "size": "1000"])
        return response.people
    }

    /// name, birthDate ("yyyy-MM-dd" or NSNull), isHidden, isFavorite.
    func updatePerson(_ id: String, _ fields: [String: Any]) async throws {
        try await call("PUT", "/people/\(id)", body: fields)
    }

    /// Moves every face of `others` into `id`; the others disappear.
    func merge(_ others: [String], into id: String) async throws {
        try await call("POST", "/people/\(id)/merge", body: ["ids": others])
    }

    func personImage(_ id: String) async throws -> Data {
        var request = request("/people/\(id)/thumbnail")
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    // MARK: Places and memories

    func mapMarkers() async throws -> [MapMarker] {
        try await get("/map/markers")
    }

    /// Immich's memories, newest first. The server makes them each night; without any yet,
    /// this week's photos from each past year stand in.
    func memories() async throws -> [Memory] {
        let saved: [Memory] = try await get("/memories")
        if !saved.isEmpty { return saved.sorted { ($0.memoryAt ?? "") > ($1.memoryAt ?? "") } }
        let calendar = Calendar.current
        let found = await withTaskGroup(of: Memory?.self) { group in
            for yearsAgo in 1...20 {
                group.addTask {
                    guard let day = calendar.date(byAdding: .year, value: -yearsAgo, to: .now),
                          let assets = try? await self.firstAssets(["takenAfter": (day - 3 * 86400).formatted(.iso8601),
                                                                    "takenBefore": (day + 4 * 86400).formatted(.iso8601)], count: 30),
                          !assets.isEmpty else { return nil }
                    return Memory(id: "week-\(yearsAgo)", type: "on_this_day", memoryAt: day.formatted(.iso8601),
                                  data: Memory.Info(year: calendar.component(.year, from: day)), assets: assets)
                }
            }
            return await group.reduce(into: [Memory]()) { if let memory = $1 { $0.append(memory) } }
        }
        return found.sorted { ($0.memoryAt ?? "") > ($1.memoryAt ?? "") }
    }

    // MARK: Search

    /// Every asset matching exact filters (type, isMotion, originalFileName…), newest first.
    func searchMetadata(_ filters: [String: Any], limit: Int = 5000) async throws -> [Asset] {
        var assets: [Asset] = []
        var page = 1
        while assets.count < limit {
            let response: SearchResponse = try await fetch("POST", "/search/metadata",
                                                          body: filters.merging(["page": page, "size": 1000, "withExif": false]) { $1 })
            assets += response.assets.items
            guard response.assets.nextPage != nil else { break }
            page += 1
        }
        return assets
    }

    /// The assets that best match a description, most similar first.
    func searchSmart(_ query: String, filters: [String: Any] = [:], limit: Int = 300) async throws -> [Asset] {
        var assets: [Asset] = []
        var page = 1
        while assets.count < limit {
            let response: SearchResponse = try await fetch("POST", "/search/smart",
                                                          body: filters.merging(["query": query, "page": page, "size": 100]) { $1 })
            assets += response.assets.items
            guard response.assets.nextPage != nil else { break }
            page += 1
        }
        return assets
    }

    // MARK: Utilities

    func restoreTrash(_ ids: [String]? = nil) async throws {
        if let ids {
            try await call("POST", "/trash/restore/assets", body: ["ids": ids])
            await History.shared.record(.recovered, ids)
        } else {
            try await call("POST", "/trash/restore")
        }
    }

    func emptyTrash() async throws {
        try await call("POST", "/trash/empty")
    }

    func authStatus() async throws -> AuthStatus {
        try await get("/auth/status")
    }

    func setUpPIN(_ pin: String) async throws {
        try await call("POST", "/auth/pin-code", body: ["pinCode": pin])
    }

    /// Opens the locked folder for this session; `lockSession` closes it again.
    func unlockSession(pin: String) async throws {
        try await call("POST", "/auth/session/unlock", body: ["pinCode": pin])
    }

    func lockSession() async throws {
        try await call("POST", "/auth/session/lock")
    }

    /// The first few assets matching exact filters, for a cover.
    func firstAssets(_ filters: [String: Any], count: Int) async throws -> [Asset] {
        let response: SearchResponse = try await fetch("POST", "/search/metadata", body: filters.merging(["size": count, "withExif": false]) { $1 })
        return response.assets.items
    }

    func favoriteCount() async throws -> Int {
        struct Statistics: Decodable { var total: Int }
        let statistics: Statistics = try await get("/assets/statistics", query: ["isFavorite": "true"])
        return statistics.total
    }

    func duplicates() async throws -> [DuplicateGroup] {
        try await get("/duplicates")
    }

    func resolveDuplicates(_ group: String, keep: [String], trash: [String]) async throws {
        try await call("POST", "/duplicates/resolve", body: ["groups": [["duplicateId": group, "keepAssetIds": keep, "trashAssetIds": trash]]])
    }

    /// Marks a group as not duplicates.
    func dismissDuplicates(_ group: String) async throws {
        try await call("DELETE", "/duplicates/\(group)")
    }

    /// People who share their library with this user.
    func partners() async throws -> [User] {
        try await get("/partners", query: ["direction": "shared-with"])
    }
}

extension TimelineQuery {
    static func partner(_ id: String) -> TimelineQuery { TimelineQuery(params: ["userId": id, "visibility": "timeline"]) }

    var albumID: String? { params["albumId"] }
    var isTrash: Bool { params["isTrashed"] == "true" }
}

struct Album: Decodable, Identifiable, Hashable {
    var id: String
    var albumName: String
    var description: String?
    var albumThumbnailAssetId: String?
    var assetCount: Int?
    var shared: Bool?
    var isActivityEnabled: Bool?
    var ownerId: String?
    var startDate: String?
    var endDate: String?
}

struct Activity: Decodable, Identifiable {
    var id: String
    var type: String
    var comment: String?
    var assetId: String?
    var createdAt: String?
    var user: User
}

struct User: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var email: String?
    var profileImagePath: String?
    var quotaUsageInBytes: Int64?
    var quotaSizeInBytes: Int64?
}

struct MapMarker: Decodable, Identifiable {
    var id: String
    var lat: Double
    var lon: Double
    var city: String?
    var country: String?
}

struct Memory: Decodable, Identifiable {
    var id: String
    var type: String?
    var memoryAt: String?
    var data: Info?
    var assets: [Asset]

    struct Info: Decodable {
        var year: Int?
        var personName: String?
    }

    var title: String {
        if let name = data?.personName { return "\(name)'s Birthday" }
        guard let year = data?.year else { return "Memory" }
        let years = Calendar.current.component(.year, from: .now) - year
        return years == 1 ? "1 Year Ago" : "\(years) Years Ago"
    }
}

struct AuthStatus: Decodable {
    var pinCode: Bool
    var isElevated: Bool?
}

struct DuplicateGroup: Decodable, Identifiable {
    var duplicateId: String
    var assets: [Asset]
    var suggestedKeepAssetIds: [String]?
    var id: String { duplicateId }
}

struct SearchResponse: Decodable {
    var assets: Page

    struct Page: Decodable {
        var items: [Asset]
        var nextPage: String?
    }
}

private struct PeopleResponse: Decodable {
    var people: [Person]
}
