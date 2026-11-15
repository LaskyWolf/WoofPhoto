import Foundation
import Observation

/// Files kept on this iPhone so the library opens without the server. In Application Support, not Caches:
/// iOS empties Caches when storage runs low, and these files are the offline library.
/// - `thumbs`: every thumbnail seen or saved in the background, up to `thumbCap`; previews of kept photos.
/// - `originals/<id>`: photos and videos the user chose with "Keep Offline".
enum OfflineFiles {
    static let root = URL.applicationSupportDirectory.appending(path: "offline")
    static let thumbs = root.appending(path: "thumbs")
    static let originals = root.appending(path: "originals")

    /// ponytail: a fixed 2 GB for thumbnails, oldest written first out; a setting if someone needs more.
    static let thumbCap: Int64 = 2 << 30

    /// Creates the folders the first time, and again after Settings removed them.
    static func prepare() {
        guard !FileManager.default.fileExists(atPath: thumbs.path) else { return }
        for folder in [thumbs, originals] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // the server has these files; a device backup needn't carry them
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    // MARK: Images

    static func image(_ id: String, size: String) -> Data? {
        try? Data(contentsOf: thumbs.appending(path: "\(id)-\(size)"))
    }

    static func hasThumbnail(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: thumbs.appending(path: "\(id)-thumbnail").path)
    }

    /// Thumbnails always; other sizes only for kept photos, which must open offline at full screen.
    static func save(_ data: Data, id: String, size: String) {
        guard size == "thumbnail" || isKept(id) else { return }
        prepare()
        try? data.write(to: thumbs.appending(path: "\(id)-\(size)"))
    }

    /// After an edit changed the asset.
    static func forget(_ id: String) {
        for size in ["thumbnail", "preview", "fullsize"] { try? FileManager.default.removeItem(at: thumbs.appending(path: "\(id)-\(size)")) }
    }

    // MARK: Kept originals

    static func isKept(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: originals.appending(path: id).path)
    }

    static func original(_ id: String) -> URL? {
        try? FileManager.default.contentsOfDirectory(at: originals.appending(path: id), includingPropertiesForKeys: nil).first
    }

    // MARK: Size

    static func bytes(in folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0) }
        return total
    }

    /// At launch: removes the oldest thumbnails until the folder fits `thumbCap`.
    static func trimThumbs() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: thumbs, includingPropertiesForKeys: Array(keys)) else { return }
        var files = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > thumbCap else { return }
        files.sort { $0.2 < $1.2 }
        for (url, size, _) in files where total > thumbCap * 8 / 10 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    static func removeOriginals() {
        // previews were saved only for kept photos; thumbnails stay
        for id in (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? [] {
            try? FileManager.default.removeItem(at: thumbs.appending(path: "\(id)-preview"))
        }
        try? FileManager.default.removeItem(at: originals)
    }

    static func removeAll() { try? FileManager.default.removeItem(at: root) }
}

/// "Keep Offline": downloads the originals of the chosen photos one after another in the background.
@MainActor @Observable
final class OfflineDownloads {
    static let shared = OfflineDownloads()

    private(set) var done = 0
    private(set) var total = 0
    private(set) var failed = 0
    var isRunning: Bool { done < total }

    private var queue: [String] = []
    private var worker: Task<Void, Never>?

    func add(_ ids: [String], client: ImmichClient) {
        let new = ids.filter { !OfflineFiles.isKept($0) && !queue.contains($0) }
        guard !new.isEmpty else { return }
        if !isRunning { done = 0; total = 0; failed = 0 }
        queue += new
        total += new.count
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let id = queue.removeFirst()
                do { try await client.keepOffline(id) } catch { failed += 1 }
                done += 1
            }
            worker = nil
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        queue = []
        total = done
    }
}
