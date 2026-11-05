import Foundation

/// The folder of settings the app and the widget share.
enum AppGroup {
    static let requested = "group.com.laskywolf.woofphoto"

    /// The signing tool may rename the group, so a profile's group wins over the requested one.
    /// A widget whose own profile has no group tries the app's, which it can use only if its signature allows it.
    static var id: String {
        SigningProfile.current?.appGroups.first ?? SigningProfile.containingApp?.appGroups.first ?? requested
    }

    /// Nil when the signature doesn't grant the group: iOS then gives no shared folder.
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    static var defaults: UserDefaults? { container == nil ? nil : UserDefaults(suiteName: id) }
}

/// What the signing tool's provisioning profile allows, read from a bundle (app or widget).
struct SigningProfile {
    var name: String
    var team: String
    var expires: Date?
    var appGroups: [String]
    var keychainGroups: [String]

    static let current = read(Bundle.main.bundleURL)

    /// The app around a widget: WoofPhoto.app/PlugIns/WoofPhotoWidget.appex. Nil in the app itself.
    static let containingApp: SigningProfile? = Bundle.main.bundleURL.pathExtension == "appex"
        ? read(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        : nil

    private static func read(_ bundle: URL) -> SigningProfile? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "embedded.mobileprovision")),
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
    }
}
