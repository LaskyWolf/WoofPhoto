import AVFoundation
import CryptoKit
import Foundation

/// The app's endpoints. The struct, the request and the upload are in Shared/ImmichCore.swift, shared with the share extension.
extension ImmichClient {
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(request(path, query: query))
    }

    /// Saves every answer; without a connection, returns the last saved one so the library still opens offline.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let file = offlineFile(request)
        let data: Data
        do {
            let (fresh, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, fresh)
            data = fresh
            try? fresh.write(to: file, options: .completeFileProtection)
        } catch let error as URLError {
            guard let saved = try? Data(contentsOf: file) else { throw error }
            data = saved
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static let offlineFolder = URL.cachesDirectory.appending(path: "api")

    /// Named after the main address even when the local one answered, so either finds the same saved copy.
    private func offlineFile(_ request: URLRequest) -> URL {
        try? FileManager.default.createDirectory(at: Self.offlineFolder, withIntermediateDirectories: true)
        let key = request.url!.absoluteString.replacingOccurrences(of: address.absoluteString, with: server.absoluteString)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.offlineFolder.appending(path: name + ".json")
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
        return (response as? HTTPURLResponse)?.statusCode == 200
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
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await Self.images.data(for: request)
        try Self.check(response, data)
        return data
    }

    func asset(_ id: String) async throws -> Asset {
        try await get("/assets/\(id)")
    }

    /// Changes the same fields on several assets: isFavorite, visibility, description, dateTimeOriginal, latitude…
    func updateAssets(_ ids: [String], _ fields: [String: Any]) async throws {
        try await call("PUT", "/assets", body: fields.merging(["ids": ids]) { $1 })
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
        try await call("DELETE", "/assets", body: ["ids": ids, "force": force])
        await History.shared.record(force ? .deletedForGood : .deleted, ids)
    }

    func stack(_ id: String) async throws -> Stack {
        try await get("/stacks/\(id)")
    }

    /// The server transcodes videos to a format every iPhone plays.
    func video(_ id: String) -> AVURLAsset {
        // the token and any proxy headers, as every other request sends them
        let request = request("/assets/\(id)/video/playback")
        return AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
    }

    /// Downloads the original file once and keeps the server's file name, so its extension says what it is.
    func downloadOriginal(_ id: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "originals/\(id)")
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
