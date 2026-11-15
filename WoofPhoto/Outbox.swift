import Foundation
import Observation

/// Changes made without a connection (favorite, archive, hide, caption, delete). They wait here, in order,
/// and go out when the server answers again.
/// ponytail: the Library shows the saved copy until the next refresh, so a deleted photo can reappear offline after a restart.
@MainActor @Observable
final class Outbox {
    static let shared = Outbox()

    struct Item: Codable {
        var method: String
        var path: String
        var body: Data
    }

    private(set) var items: [Item]
    private var flushing = false
    private static let file = URL.applicationSupportDirectory.appending(path: "offline/outbox.json")

    private init() {
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: Self.file))) ?? []
    }

    func add(_ method: String, _ path: String, body: Data) {
        items.append(Item(method: method, path: path, body: body))
        save()
    }

    /// Sends the waiting changes in order. A network failure stops it and keeps the rest;
    /// an answer from the server, even a refusal (the photo was deleted since), removes that change so it can't block the others.
    func flush(with client: ImmichClient) async {
        guard !flushing, !items.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while let item = items.first {
            do {
                let body = try JSONSerialization.jsonObject(with: item.body) as? [String: Any]
                try await client.call(item.method, item.path, body: body)
                Connection.shared.markFast()
            } catch is URLError {
                return
            } catch {
                // refused by the server: drop it
            }
            items.removeFirst()
            save()
        }
    }

    func clear() {
        items = []
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        OfflineFiles.prepare()
        try? JSONEncoder().encode(items).write(to: Self.file, options: .completeFileProtection)
    }
}
