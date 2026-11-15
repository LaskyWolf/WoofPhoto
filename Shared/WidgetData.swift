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

    /// This month so far, from the library timeline.
    struct Month: Codable {
        var name: String
        var count: Int
        /// Photos per week of the month (days 1–7, 8–14…), up to the current week.
        var weeks: [Int]
        /// Days in a row, ending today or yesterday, with at least one photo.
        var streak: Int
        var bestDay: Date?
        var bestCount: Int
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

    #if DEBUG
    static func selfCheck() {
        let month = Month(name: "May", count: 3, weeks: [1, 2], streak: 2, bestDay: nil, bestCount: 2)
        let data = try? JSONEncoder().encode(month)
        assert((data.flatMap { try? JSONDecoder().decode(Month.self, from: $0) })?.weeks == [1, 2])
    }
    #endif
}
