import Foundation

/// The few Immich endpoints the app uses. Every field the server might drop is optional,
/// so a newer server version shows less data instead of failing to decode.
struct ImmichClient {
    let server: URL
    var token: String?

    /// Accepts "photos.example.com", "192.168.1.5:2283" or any URL copied from the web app,
    /// such as ".../auth/login": Immich always serves its API from the root, so the path is dropped.
    /// Without a scheme, an address with a port is Immich's own HTTP port; one without is a proxy on HTTPS.
    static func serverURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let hasPort = text.split(separator: "/").first?.contains(":") == true
            text = (hasPort ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased()),
              let host = components.host, !host.isEmpty else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    #if DEBUG
    static func selfCheck() {
        assert(serverURL(from: "http://server.ts.net:2283/auth/login?continue=%2F")?.absoluteString == "http://server.ts.net:2283")
        assert(serverURL(from: " https://photos.example.com/api/ ")?.absoluteString == "https://photos.example.com")
        assert(serverURL(from: "photos.example.com")?.absoluteString == "https://photos.example.com")
        assert(serverURL(from: "192.168.1.5:2283")?.absoluteString == "http://192.168.1.5:2283")
        assert(serverURL(from: "not a url") == nil)
    }
    #endif

    func request(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: server.appending(path: "api" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(request(path, query: query))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.message
        throw ImmichError.http(http.statusCode, message)
    }

    // MARK: Endpoints

    func ping() async throws {
        let _: Pong = try await get("/server/ping")
    }

    func login(email: String, password: String) async throws -> String {
        var request = request("/auth/login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        let response: LoginResponse = try await send(request)
        return response.accessToken
    }

    /// Months that have photos, newest first.
    func buckets() async throws -> [TimeBucket] {
        try await get("/timeline/buckets", query: ["visibility": "timeline"])
    }

    func bucket(_ key: String) async throws -> BucketAssets {
        try await get("/timeline/bucket", query: ["timeBucket": key, "visibility": "timeline"])
    }

    /// Downloads the original file and keeps the server's file name, so its extension says what it is.
    func downloadOriginal(_ id: String) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(for: request("/assets/\(id)/original"))
        try Self.check(response, Data())
        let name = response.suggestedFilename ?? id
        let folder = FileManager.default.temporaryDirectory.appending(path: id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }
}

struct TimeBucket: Decodable {
    var timeBucket: String
    var count: Int
}

/// One month of the timeline. The server sends one array per field, all in the same order.
struct BucketAssets: Decodable {
    var id: [String]
    var isImage: [Bool]?
    var livePhotoVideoId: [String?]?
}

private struct Pong: Decodable { var res: String }
private struct LoginResponse: Decodable { var accessToken: String }
private struct ServerError: Decodable { var message: String? }

enum ImmichError: LocalizedError {
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .http(401, _): "Wrong email or password, or the session expired."
        case .http(404, _): "No Immich server at this address. Check the URL and the port."
        case let .http(code, message): "The server answered \(code)\(message.map { ": \($0)" } ?? ".")"
        }
    }
}

extension Error {
    /// A message that says what went wrong and what to try, for the errors a home server usually causes.
    var explanation: String {
        if self is DecodingError {
            return "This address answered, but not as an Immich server. Enter only the address, for example http://192.168.1.5:2283."
        }
        guard let error = self as? URLError else { return localizedDescription }
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the plain HTTP connection. Update WoofPhoto: this build is missing the HTTP permission."
        case .cannotFindHost, .dnsLookupFailed:
            return "The server name was not found. Check the spelling, or use the IP address."
        case .cannotConnectToHost:
            return "Nothing answers at this address. Check the port (Immich uses 2283) and that the server is running."
        case .timedOut, .notConnectedToInternet, .networkConnectionLost:
            return "The server didn't answer in time. If you reach it through a VPN such as Tailscale, check that the VPN is on."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
            return "The server's HTTPS certificate is not trusted. Try its http:// address on the local network."
        default:
            return error.localizedDescription
        }
    }
}
