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
        /// Server errors (5xx) this change got. Optional, so queues saved by older versions still read.
        var failures: Int?
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

    /// Sends the waiting changes in order. Anything that may pass stops it and keeps the rest: no network, a proxy that is still waking (5xx),
    /// an expired login (401). Only a refusal that will never change (the photo was deleted since, 4xx) removes that change so it can't block the others.
    func flush(with client: ImmichClient) async {
        guard !flushing, !items.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while let item = items.first {
            do {
                let body = try JSONSerialization.jsonObject(with: item.body) as? [String: Any]
                try await client.call(item.method, item.path, body: body)
                Connection.shared.markFast()
            } catch ImmichError.http(let code, _) where (400..<500).contains(code) && ![401, 408, 429].contains(code) {
                // refused for good: drop it
            } catch ImmichError.http(let code, _) where code >= 500 && (item.failures ?? 0) >= 4 {
                // the server failed this change five times: it goes, so the changes behind it aren't held forever
                FileLog.shared.append("ERROR", "A waiting \(item.method) change was dropped after 5 server errors (\(code))")
            } catch ImmichError.http(let code, _) where code >= 500 {
                if !items.isEmpty { items[0].failures = (item.failures ?? 0) + 1 }
                save()
                return
            } catch {
                return
            }
            // signing out empties the queue while a change is on its way
            guard !items.isEmpty else { return }
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
