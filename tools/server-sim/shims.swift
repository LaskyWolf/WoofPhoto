import Foundation
// Stand-ins for the iOS-only pieces ImmichCore needs.
enum Keychain {
    static func read(_ key: String) -> String? { nil }
    static func write(_ key: String, _ value: String) {}
}
enum AppGroup { static var defaults: UserDefaults? { nil } }
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock(); private var state: State
    init(initialState: State) { state = initialState }
    func withLock<R>(_ body: (inout State) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&state) }
}
extension URL {
    static var documentsDirectory: URL { try? FileManager.default.createDirectory(atPath: "/tmp/sim-docs", withIntermediateDirectories: true); return URL(fileURLWithPath: "/tmp/sim-docs") }
}
