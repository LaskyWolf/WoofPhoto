import Foundation

/// What the Home Screen widgets other than Featured Photos show. The app writes small JSON files and JPEGs
/// into the App Group folder; the widgets only read them, because a widget can't sign in to the server.
enum WidgetData {
    static var folder: URL? { AppGroup.container?.appending(path: "widgets") }

    /// A photo taken on today's date in an earlier year.
    struct Day: Codable {
        var id: String
        var file: String
        var year: Int
    }

    /// A person with a name, with the face the app saved for the widget.
    struct Face: Codable {
        var id: String
        var name: String
        var file: String
    }

    struct Backup: Codable {
        var enabled: Bool
        var pending: Int
        var done: Int
        var last: Date?
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: name + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: folder.appending(path: name + ".json"), options: .atomic)
    }

    static func remove(_ name: String) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: name + ".json"))
    }

    /// The JPEGs of On This Day.
    static var photos: URL? { folder?.appending(path: "photos") }
    /// The faces of People.
    static var faces: URL? { folder?.appending(path: "faces") }

    #if DEBUG
    static func selfCheck() {
        let face = Face(id: "a", name: "Ana", file: "a.jpg")
        let data = try? JSONEncoder().encode([face])
        assert((data.flatMap { try? JSONDecoder().decode([Face].self, from: $0) })?.first?.name == "Ana")
    }
    #endif
}
