import Foundation

/// The photos the Featured Photos widget shows. The app writes small JPEGs into the App Group folder;
/// the widget only reads them, because a widget can't sign in to the server.
enum Featured {
    struct Item: Codable {
        var id: String
        var file: String
        var date: Date?
    }

    static var folder: URL? { AppGroup.container?.appending(path: "featured") }

    static func items() -> [Item] {
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "index.json")) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func save(_ items: [Item]) throws {
        guard let folder else { return }
        try JSONEncoder().encode(items).write(to: folder.appending(path: "index.json"))
    }
}
