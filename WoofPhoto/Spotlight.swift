import AppIntents
import CoreSpotlight
import Foundation

/// Album and person names in iOS search. Off by default: the names show up in Spotlight outside the app,
/// so the user opts in (Settings > Library & Viewer).
enum Spotlight {
    static let key = "spotlight.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Replaces what was indexed with the current albums and named people. The link in each item opens it through `Router`.
    static func index(albums: [Album], people: [Person]) async {
        func item(_ link: String, title: String, kind: String) -> CSSearchableItem {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = title
            attributes.contentDescription = kind
            return CSSearchableItem(uniqueIdentifier: link, domainIdentifier: "woofphoto", attributeSet: attributes)
        }
        func link(_ host: String, _ id: String, _ name: String) -> String {
            var components = URLComponents()
            components.scheme = "woofphoto"
            components.host = host
            components.path = "/" + id
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            return components.string ?? ""
        }
        let items = albums.map { item(link("album", $0.id, $0.albumName), title: $0.albumName, kind: "Album in WoofPhoto") }
            + people.filter { !$0.name.isEmpty && $0.isHidden != true }
                .map { item(link("person", $0.id, $0.name), title: $0.name, kind: "Person in WoofPhoto") }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: ["woofphoto"])
        try? await index.indexSearchableItems(items)
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["woofphoto"])
    }
}

// MARK: Shortcuts

struct SearchPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Photos"
    static let description = IntentDescription("Opens WoofPhoto's search with the words you give.")
    static let openAppWhenRun = true

    @Parameter(title: "Search") var text: String

    @MainActor func perform() async throws -> some IntentResult {
        Router.shared.searchText = text
        Router.shared.tab = 2
        return .result()
    }
}

struct OpenFavoritesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Favorites"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        Router.shared.shelf = .favorites
        return .result()
    }
}

struct WoofPhotoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchPhotosIntent(), phrases: ["Search photos in \(.applicationName)"],
                    shortTitle: "Search Photos", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenFavoritesIntent(), phrases: ["Open favorites in \(.applicationName)"],
                    shortTitle: "Favorites", systemImageName: "heart")
    }
}
