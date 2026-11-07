import Foundation
import Observation

/// WoofTube's AppUpdate: compares this build with the newest release on GitHub. The app only points to the release page.
@MainActor
@Observable
final class AppUpdate {
    static let shared = AppUpdate()

    struct Release {
        let version: String
        let page: URL
    }

    private(set) var available: Release?
    private(set) var isChecking = false
    private(set) var didCheck = false
    private(set) var errorText: String?

    private static let latestRelease = URL(string: "https://api.github.com/repos/LaskyWolf/WoofPhoto/releases/latest")!

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            didCheck = true
        }
        do {
            var request = URLRequest(url: Self.latestRelease)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            // 404: no release published yet, so nothing is newer
            if status == 404 {
                available = nil
                errorText = nil
                return
            }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                throw URLError(.badServerResponse)
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            available = Self.isNewer(version, than: Self.currentVersion) ? Release(version: version, page: page) : nil
            errorText = nil
        } catch {
            errorText = "GitHub can't be reached right now."
        }
    }

    /// Compares numbers part by part, so 1.10 is newer than 1.9.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let new = version.split(separator: ".").map { Int($0) ?? 0 }
        let old = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    nonisolated static func selfCheck() {
        assert(isNewer("1.3", than: "1.2"))
        assert(isNewer("1.10", than: "1.9"))
        assert(isNewer("2", than: "1.9.9"))
        assert(!isNewer("1.2", than: "1.2.0"))
        assert(!isNewer("1.0", than: "1.2"))
    }
}
