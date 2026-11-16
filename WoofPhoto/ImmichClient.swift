import AVFoundation
import CryptoKit
import Foundation

/// The app's endpoints. The struct, the request and the upload are in Shared/ImmichCore.swift, shared with the share extension.
extension ImmichClient {
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(request(path, query: query))
    }

    /// Saves every answer. With a saved copy, a weak or missing connection costs at most a few seconds, and then nothing:
    /// offline, or just after a timeout, the saved copy is returned without asking the server.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let file = offlineFile(request)
        let saved = try? Data(contentsOf: file)
        if let saved, !Connection.shared.isUsable { return try JSONDecoder().decode(T.self, from: saved) }
        guard saved != nil || Connection.shared.isOnline else { throw URLError(.notConnectedToInternet) }
        var request = request
        if saved != nil { request.timeoutInterval = 4 }
        let data: Data
        do {
            let (fresh, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, fresh)
            Connection.shared.markFast()
            data = fresh
            try? fresh.write(to: file, options: .completeFileProtection)
        } catch let error as URLError where Connection.isUnreachable(error) {
            Connection.shared.markSlow()
            guard let saved else { throw error }
            data = saved
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Application Support, not Caches: iOS empties Caches when storage runs low, and this is the offline library.
    static let offlineFolder = URL.applicationSupportDirectory.appending(path: "api")

    /// Named after the main address even when the local one answered, so either finds the same saved copy.
    func offlineFile(_ request: URLRequest) -> URL {
        if !FileManager.default.fileExists(atPath: Self.offlineFolder.path) {
            try? FileManager.default.createDirectory(at: Self.offlineFolder, withIntermediateDirectories: true)
            // the server has these answers; a device backup needn't carry them
            var folder = Self.offlineFolder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        let key = request.url!.absoluteString.replacingOccurrences(of: address.absoluteString, with: server.absoluteString)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.offlineFolder.appending(path: name + ".json")
    }

    /// Saves every month of a timeline, newest first, so the whole library opens offline, not only the months scrolled to.
    /// Each month is one request through `send`, which keeps the answer. Months saved in the last day are read from disk, not asked again.
    /// ponytail: one day-long refresh for every month; the server's sync API would fetch only what changed.
    func saveMonthsForOffline(_ query: TimelineQuery, keys: [String]) async {
        // 90% of the thumbnail limit, so the launch cleanup has nothing to remove
        var budget = OfflineFiles.thumbCap * 9 / 10 - OfflineFiles.bytes(in: OfflineFiles.thumbs)
        for key in keys.sorted(by: >) {
            guard !Task.isCancelled, Connection.shared.isCheap, Connection.shared.isUsable else { return }
            let file = offlineFile(request("/timeline/bucket", query: query.params.merging(["timeBucket": key, "order": "asc"]) { $1 }))
            let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var month: BucketAssets?
            if let saved, saved > .now - 86400, let data = try? Data(contentsOf: file) {
                // saved today: read from disk, but its photos may still need their thumbnails
                month = try? JSONDecoder().decode(BucketAssets.self, from: data)
            }
            if month == nil { month = try? await bucket(key, query, order: "asc") }
            guard let month else { continue }
            guard await saveThumbnails(month.id, budget: &budget) else { return }
        }
    }

    /// Fetches the thumbnails not on this iPhone yet, a few at a time. Returns false when the space limit is reached.
    /// `image` writes each one into the offline folder.
    private func saveThumbnails(_ ids: [String], budget: inout Int64) async -> Bool {
        let missing = ids.filter { !OfflineFiles.hasThumbnail($0) }
        for start in stride(from: 0, to: missing.count, by: 6) {
            guard !Task.isCancelled, budget > 0, Connection.shared.isCheap, Connection.shared.isUsable else { return budget > 0 }
            let bytes = await withTaskGroup(of: Int.self) { group in
                for id in missing[start..<min(start + 6, missing.count)] {
                    group.addTask { (try? await self.image(id))?.count ?? 0 }
                }
                return await group.reduce(0, +)
            }
            budget -= Int64(bytes)
        }
        return true
    }

    // MARK: Endpoints

    func ping() async throws {
        let _: Pong = try await get("/server/ping")
    }

    /// Asks the server directly with a short wait. `ping()` can answer from the offline copy, so it can't tell.
    func isReachable() async -> Bool {
        var request = request("/server/ping")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        let answered = (response as? HTTPURLResponse)?.statusCode == 200
        // Retry and the return to the foreground end the saved-copy-only pause
        if answered { Connection.shared.markFast() }
        return answered
    }

    func login(email: String, password: String) async throws -> String {
        let response: LoginResponse = try await fetch("POST", "/auth/login", body: ["email": email, "password": password])
        return response.accessToken
    }

    /// SSO, with PKCE: the server answers with its login page, and the browser comes back to `redirect`.
    static let redirect = "app.immich:///oauth-callback"

    func ssoLogin(browser: (URL) async throws -> URL) async throws -> String {
        let verifier = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = UUID().uuidString
        let start: SSOStart = try await fetch("POST", "/oauth/authorize",
                                              body: ["redirectUri": Self.redirect, "state": state, "codeChallenge": challenge])
        guard let page = URL(string: start.url) else { throw ImmichError.http(0, "The server sent a bad SSO address.") }
        let callback = try await browser(page)
        let response: LoginResponse = try await fetch("POST", "/oauth/callback",
                                                      body: ["url": callback.absoluteString, "state": state, "codeVerifier": verifier])
        return response.accessToken
    }

    /// Months that have assets matching the query.
    func buckets(_ query: TimelineQuery = .library) async throws -> [TimeBucket] {
        try await get("/timeline/buckets", query: query.params)
    }

    func bucket(_ key: String, _ query: TimelineQuery = .library, order: String = "desc") async throws -> BucketAssets {
        try await get("/timeline/bucket", query: query.params.merging(["timeBucket": key, "order": order]) { $1 })
    }

    /// iOS opens only 4 connections per server by default; a screen of grid cells over plain HTTP waits in line behind them.
    private static let images: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: configuration)
    }()

    /// "thumbnail" is about 250 px, "preview" about 1440 px, "fullsize" the whole image as JPEG.
    /// A cached copy wins: an asset's images change only when it is edited, and editing gives a new asset.
    func image(_ id: String, size: String = "thumbnail") async throws -> Data {
        var request = request("/assets/\(id)/thumbnail", query: ["size": size])
        // no route: only a saved copy can answer, so a missing image fails now instead of after the timeout
        request.cachePolicy = Connection.shared.isOnline ? .returnCacheDataElseLoad : .returnCacheDataDontLoad
        request.timeoutInterval = 15
        // our own copy first: URLCache may have dropped it, and kept photos must open offline
        if let stored = OfflineFiles.image(id, size: size) { return stored }
        let (data, response) = try await Self.images.data(for: request)
        try Self.check(response, data)
        OfflineFiles.save(data, id: id, size: size)
        return data
    }

    func asset(_ id: String) async throws -> Asset {
        let asset: Asset = try await get("/assets/\(id)")
        await OfflineIndex.shared.learn([asset])
        return asset
    }

    /// Keeps a photo or video on this iPhone: the original, its details, thumbnail and preview, and a Live Photo's motion.
    func keepOffline(_ id: String) async throws {
        let detail = try await asset(id)
        try await downloadOriginal(id, keep: true)
        if let motion = detail.livePhotoVideoId { try await downloadOriginal(motion, keep: true) }
        for size in ["thumbnail", "preview"] { _ = try await image(id, size: size) }
    }

    /// A change made without a connection waits in the Outbox and goes out when the server answers again.
    private func changeOrQueue(_ method: String, _ path: String, _ body: [String: Any]) async throws {
        // older changes still waiting go first, or a late replay would undo this one
        if Connection.shared.isUsable, await Outbox.shared.items.isEmpty {
            do {
                try await call(method, path, body: body)
                return
            } catch let error as URLError where Connection.isUnreachable(error) {
                Connection.shared.markSlow()
            }
        }
        await Outbox.shared.add(method, path, body: try JSONSerialization.data(withJSONObject: body))
        // the slow pause lasts 30 s; try again just after it, in case the server was reachable all along
        Task {
            try? await Task.sleep(for: .seconds(31))
            await Outbox.shared.flush(with: self)
        }
    }

    /// Changes the same fields on several assets: isFavorite, visibility, description, dateTimeOriginal, latitude…
    func updateAssets(_ ids: [String], _ fields: [String: Any]) async throws {
        try await changeOrQueue("PUT", "/assets", fields.merging(["ids": ids]) { $1 })
        let kind: HistoryEntry.Kind? = switch (fields["isFavorite"] as? Bool, fields["visibility"] as? String) {
        case (true?, _): .favorited
        case (false?, _): .unfavorited
        case (_, "locked"?): .hidden
        case (_, "archive"?): .archived
        // Library's own visibility: back from Hidden or Archive
        case (_, "timeline"?): .unhidden
        default: nil
        }
        if let kind { await History.shared.record(kind, ids) }
    }

    /// Moves to Recently Deleted, or deletes for good with `force`.
    func deleteAssets(_ ids: [String], force: Bool = false) async throws {
        try await changeOrQueue("DELETE", "/assets", ["ids": ids, "force": force])
        await History.shared.record(force ? .deletedForGood : .deleted, ids)
        // the same photo on this iPhone goes too
        await Backup.shared.deleteOnDevice(serverIDs: ids)
    }

    func stack(_ id: String) async throws -> Stack {
        try await get("/stacks/\(id)")
    }

    /// The server transcodes videos to a format every iPhone plays.
    func video(_ id: String) -> AVURLAsset {
        if let kept = OfflineFiles.original(id) { return AVURLAsset(url: kept) }
        // the token and any proxy headers, as every other request sends them
        let request = request("/assets/\(id)/video/playback")
        return AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
    }

    /// Downloads the original file once and keeps the server's file name, so its extension says what it is.
    /// `keep` puts it in the offline folder, which iOS doesn't empty; otherwise it goes to the temporary folder.
    @discardableResult
    func downloadOriginal(_ id: String, keep: Bool = false) async throws -> URL {
        if let kept = OfflineFiles.original(id) { return kept }
        if keep { OfflineFiles.prepare() }
        let folder = keep ? OfflineFiles.originals.appending(path: id) : FileManager.default.temporaryDirectory.appending(path: "originals/\(id)")
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
            return existing
        }
        let (temp, response) = try await URLSession.shared.download(for: request("/assets/\(id)/original"))
        try Self.check(response, Data())
        let name = response.suggestedFilename ?? id
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        do {
            try FileManager.default.moveItem(at: temp, to: file)
        } catch where FileManager.default.fileExists(atPath: file.path) {
            // a second download of the same original finished first
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        return file
    }
}

/// Which assets a timeline shows. The server filters every month with the same parameters.
struct TimelineQuery: Hashable {
    var params: [String: String]

    static let library = TimelineQuery(params: ["visibility": "timeline", "withStacked": "true"])
    static let favorites = TimelineQuery(params: ["visibility": "timeline", "isFavorite": "true"])
    static let trash = TimelineQuery(params: ["isTrashed": "true"])
    static let archive = TimelineQuery(params: ["visibility": "archive"])
    static let hidden = TimelineQuery(params: ["visibility": "locked"])
    static func album(_ id: String) -> TimelineQuery { TimelineQuery(params: ["albumId": id]) }
    static func person(_ id: String) -> TimelineQuery { TimelineQuery(params: ["personId": id, "visibility": "timeline"]) }
}

struct TimeBucket: Decodable {
    var timeBucket: String
    var count: Int
}

/// One month of the timeline. The server sends one array per field, all in the same order.
struct BucketAssets: Decodable {
    var id: [String]
    var isImage: [Bool]?
    var isFavorite: [Bool]?
    var thumbhash: [String?]?
    /// Milliseconds, for videos and GIFs.
    var duration: [Int?]?
    var livePhotoVideoId: [String?]?
    /// [stack id, number of assets] for the top asset of a stack.
    var stack: [[String]?]?
    var fileCreatedAt: [String]?

    var refs: [AssetRef] {
        id.indices.map { i in
            let stack = self.stack?[safe: i] ?? nil
            return AssetRef(id: id[i], isImage: isImage?[safe: i] ?? true, isFavorite: isFavorite?[safe: i] ?? false,
                            thumbhash: thumbhash?[safe: i] ?? nil, duration: duration?[safe: i] ?? nil,
                            livePhotoVideoId: livePhotoVideoId?[safe: i] ?? nil,
                            stackID: stack?.first, stackCount: stack.flatMap { Int($0.last ?? "") } ?? 0,
                            date: fileCreatedAt?[safe: i].flatMap(Date.init(immich:)))
        }
    }
}

private struct Pong: Decodable { var res: String }
private struct LoginResponse: Decodable { var accessToken: String }
private struct SSOStart: Decodable { var url: String }

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
