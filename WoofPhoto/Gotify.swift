import Foundation

/// Push messages to the user's own Gotify server when a backup run ends. The app token is in the Keychain.
enum Gotify {
    static var server: String {
        get { UserDefaults.standard.string(forKey: "gotify.server") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gotify.server") }
    }

    static var token: String {
        get { Keychain.read("gotify.token") ?? "" }
        set { if newValue.isEmpty { Keychain.delete("gotify.token") } else { Keychain.write("gotify.token", newValue) } }
    }

    static var isSetUp: Bool { !server.isEmpty && !token.isEmpty }

    /// POST /message. The address keeps its path, since Gotify often sits under one, like example.com/gotify.
    static func send(title: String, message: String, priority: Int = 5) async throws {
        let text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: text.contains("://") ? text : "https://" + text), base.host() != nil else { throw GotifyError.badAddress }
        var request = URLRequest(url: base.appending(path: "message"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(token, forHTTPHeaderField: "X-Gotify-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "message": message, "priority": priority])
        let (_, response) = try await URLSession.shared.data(for: request)
        if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw GotifyError.http(code) }
    }

    /// After a backup run: only when something was uploaded or went wrong, so an up-to-date library sends nothing.
    static func backupEnded(uploaded: Int, errors: [String], failure: String? = nil) async {
        guard isSetUp else { return }
        if let failure {
            try? await send(title: "WoofPhoto backup failed", message: failure, priority: 8)
        } else if !errors.isEmpty {
            let lines = errors.prefix(5).joined(separator: "\n") + (errors.count > 5 ? "\n…and \(errors.count - 5) more" : "")
            try? await send(title: "WoofPhoto backup: \(errors.count) failed", message: "\(uploaded) uploaded.\n" + lines, priority: 8)
        } else if uploaded > 0 {
            try? await send(title: "WoofPhoto backup finished", message: "\(uploaded) photos and videos uploaded.", priority: 3)
        }
    }

    enum GotifyError: LocalizedError {
        case badAddress, http(Int)
        var errorDescription: String? {
            switch self {
            case .badAddress: "This is not a Gotify address. Example: https://gotify.example.com"
            case .http(401), .http(403): "Gotify refused the token. Use an app token, not a client token."
            case let .http(code): "Gotify answered \(code)."
            }
        }
    }
}
