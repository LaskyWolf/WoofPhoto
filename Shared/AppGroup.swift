import Foundation

/// The folder of settings the app and the widget share.
enum AppGroup {
    static let requested = "group.com.laskywolf.woofphoto"

    /// The signing tool may rename the group, so the profile's first group wins over the requested one.
    static var id: String { SigningProfile.current?.appGroups.first ?? requested }

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}

/// What the signing tool's provisioning profile allows, read from the running bundle (app or widget).
struct SigningProfile {
    var name: String
    var team: String
    var expires: Date?
    var appGroups: [String]
    var keychainGroups: [String]

    static let current: SigningProfile? = {
        guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = (try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil)) as? [String: Any] else {
            return nil
        }
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        return SigningProfile(
            name: profile["Name"] as? String ?? "?",
            team: profile["TeamName"] as? String ?? "?",
            expires: profile["ExpirationDate"] as? Date,
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [],
            keychainGroups: entitlements["keychain-access-groups"] as? [String] ?? []
        )
    }()
}
