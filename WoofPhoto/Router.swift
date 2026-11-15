import SwiftUI

/// Where the app should go when something outside it asks: a widget, Spotlight, or a Shortcuts action.
/// woofphoto://search?q=rome, woofphoto://favorites, woofphoto://album/<id>?name=Trip, woofphoto://person/<id>?name=Ana
@MainActor @Observable
final class Router {
    static let shared = Router()

    var tab = 0
    /// Text for the Search tab to run; the tab clears it once it has taken it.
    var searchText: String?
    /// A collection shown over the tabs.
    var shelf: Shelf?

    /// Returns false for a link this doesn't handle (woofphoto://asset/<id> is opened by the app itself).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let id = url.pathComponents.last ?? ""
        switch url.host() {
        case "search":
            searchText = value("q") ?? ""
            tab = 2
        case "favorites": shelf = .favorites
        case "album" where !id.isEmpty: shelf = .album(id: id, name: value("name") ?? "Album")
        case "person" where !id.isEmpty: shelf = .person(id: id, name: value("name") ?? "Person")
        default: return false
        }
        return true
    }
}

extension Shelf: Identifiable {
    var id: Self { self }
}
