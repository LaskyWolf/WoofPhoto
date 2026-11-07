import Foundation
import os

/// The few Immich endpoints the app uses. Every field the server might drop is optional,
/// so a newer server version shows less data instead of failing to decode.
/// This part is shared with the share extension: the address, the request, the upload. The app's endpoints are in ImmichClient.swift.
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

    /// The signed-in server, from the App Group's settings so the share extension finds it too.
    static func saved() -> ImmichClient? {
        guard let text = (AppGroup.defaults ?? .standard).string(forKey: "server"), let url = URL(string: text),
              let token = Keychain.read("token") else { return nil }
        return ImmichClient(server: url, token: token)
    }

    /// Tailscale gives devices addresses in 100.64.0.0/10 and MagicDNS names under .ts.net.
    static func isTailscale(_ host: String) -> Bool {
        if host.lowercased().hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, let first = parts[0], let second = parts[1], parts.allSatisfy({ $0 != nil }) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    #if DEBUG
    static func selfCheck() {
        assert(serverURL(from: "http://server.ts.net:2283/auth/login?continue=%2F")?.absoluteString == "http://server.ts.net:2283")
        assert(serverURL(from: " https://photos.example.com/api/ ")?.absoluteString == "https://photos.example.com")
        assert(serverURL(from: "photos.example.com")?.absoluteString == "https://photos.example.com")
        assert(serverURL(from: "192.168.1.5:2283")?.absoluteString == "http://192.168.1.5:2283")
        assert(serverURL(from: "not a url") == nil)
        assert(isTailscale("100.101.2.3") && isTailscale("nas.tail1234.ts.net") && isTailscale("100.64.0.1") && isTailscale("100.127.255.255"))
        assert(!isTailscale("100.128.0.1") && !isTailscale("100.63.0.1") && !isTailscale("192.168.1.5") && !isTailscale("photos.example.com"))
    }
    #endif

    /// Settings > Immich: "Name: value" lines for a proxy in front of the server. In the Keychain, since they can be secrets.
    /// Read by every request on any thread and written by Settings, so a lock guards it.
    static var proxyHeaders: String {
        get { headers.withLock { $0 } }
        set {
            headers.withLock { $0 = newValue }
            Keychain.write("proxyHeaders", newValue)
            UserDefaults.standard.removeObject(forKey: "proxyHeaders")
        }
    }
    private static let headers = OSAllocatedUnfairLock(
        initialState: Keychain.read("proxyHeaders") ?? UserDefaults.standard.string(forKey: "proxyHeaders") ?? "")

    // MARK: Local address

    /// Settings > Immich: the server's address on the home network, like http://192.168.1.5:2283.
    static var localAddress: URL? {
        get { (AppGroup.defaults ?? .standard).string(forKey: "server.local").flatMap(URL.init(string:)) }
        set {
            (AppGroup.defaults ?? .standard).set(newValue?.absoluteString, forKey: "server.local")
            route.withLock { $0 = nil }
        }
    }

    /// The local address while it answered the last check; nil sends requests to the main address.
    /// `server` stays the main address, so the rest of the app never sees the switch.
    /// ponytail: starts on the main address at launch until the first check; remember the last choice if that wait shows.
    private static let route = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Pings the local address with a short wait and sends requests there if it answers.
    /// Called when the Library appears or comes back to the foreground, and before a backup run.
    static func chooseAddress() async {
        guard let local = localAddress else {
            route.withLock { $0 = nil }
            return
        }
        var request = URLRequest(url: local.appending(path: "api/server/ping"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try? await URLSession.shared.data(for: request)
        let answered = (result?.1 as? HTTPURLResponse)?.statusCode == 200
        route.withLock { $0 = answered ? local : nil }
    }

    /// The address requests go to: the local one while it answers, else the main one.
    var address: URL { Self.route.withLock { $0 } ?? server }

    func request(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: address.appending(path: "api" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for line in Self.proxyHeaders.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { request.setValue(parts[1], forHTTPHeaderField: parts[0]) }
        }
        return request
    }

    /// Any method with an optional JSON body. Returns the raw response for callers that ignore it.
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        var request = request(path, query: query)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    func fetch<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await call(method, path, query: query, body: body))
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.message
        throw ImmichError.http(http.statusCode, message)
    }

    /// Uploads a file as a new asset and returns its id. The form is written to disk first and streamed,
    /// so a large video doesn't fill memory. `fields` needs at least fileCreatedAt and fileModifiedAt.
    func upload(_ file: URL, fields: [String: String], cellular: Bool = true) async throws -> String {
        let boundary = "WoofPhoto-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        let all = [
            "deviceAssetId": "woofphoto-\(UUID().uuidString)",
            "deviceId": "WoofPhoto",
            "filename": file.lastPathComponent,
        ].merging(fields) { $1 }
        for (name, value) in all {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try input.close()
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var request = request("/assets")
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.allowsCellularAccess = cellular
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        try Self.check(response, data)
        return try JSONDecoder().decode(Uploaded.self, from: data).id
    }
}

private struct Uploaded: Decodable { var id: String }
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
    /// Each one is also written to the log file, where Diagnostics lists it under Recent Problems.
    var explanation: String {
        let message = describe
        // ponytail: logs where the message is made; every caller asks once per failure today
        FileLog.shared.append("ERROR", "\(message) (\(String(describing: self).prefix(200)))")
        return message
    }

    private var describe: String {
        if self is DecodingError {
            return "The server answered with data WoofPhoto can't read. When signing in, enter only the address, for example http://192.168.1.5:2283."
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
