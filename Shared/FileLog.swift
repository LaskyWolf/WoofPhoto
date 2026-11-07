import Foundation

/// WoofMusic's FileLog: appends problems to Documents/log.txt, so what only happens on the iPhone can be read
/// and shared from Diagnostics. Starts a fresh file past about 1 MB.
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()

    private let queue = DispatchQueue(label: "com.laskywolf.woofphoto.log")
    private let maxBytes = 1_000_000
    /// Only touched on `queue`.
    private var handle: FileHandle?
    private var size = 0

    var fileURL: URL { URL.documentsDirectory.appending(path: "log.txt") }

    func append(_ level: String, _ message: String) {
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(Self.safe(message))\n"
        queue.async { [self] in
            let data = Data(line.utf8)
            if handle == nil {
                handle = try? FileHandle(forWritingTo: fileURL)
                size = Int((try? handle?.seekToEnd()) ?? 0)
            }
            if let handle, size <= maxBytes, (try? handle.write(contentsOf: data)) != nil {
                size += data.count
                return
            }
            // no file yet, or past the limit: start a fresh one
            try? handle?.close()
            handle = nil
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Addresses carry the server's host and asset IDs, and this log can be shared: only the scheme and host stay.
    static func safe(_ line: String) -> String {
        line.replacingOccurrences(of: #"(https?://[^/\s]+)\S*"#, with: "$1/…", options: .regularExpression)
    }

    static func selfCheck() {
        assert(safe("got https://a.example/api/assets/1?key=2 back") == "got https://a.example/… back")
        assert(safe("no address") == "no address")
    }
}
