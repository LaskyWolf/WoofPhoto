import Foundation
import Network
import os

/// What the app knows about the network, so a screen shows its saved copy at once
/// instead of waiting out a timeout on a weak connection.
final class Connection: @unchecked Sendable {
    static let shared = Connection()

    struct State {
        /// False when iOS says there is no route at all (airplane mode, no Wi-Fi, no cellular).
        var online = true
        /// Cellular or a Personal Hotspot: big background jobs wait for Wi-Fi.
        var expensive = false
        /// A request to the server timed out recently: the route exists but the server doesn't answer in time (weak signal, VPN off).
        var slowUntil = Date.distantPast

        func usable(at now: Date) -> Bool { online && slowUntil <= now }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [state] path in state.withLock { $0.online = path.status == .satisfied; $0.expensive = path.isExpensive } }
        monitor.start(queue: .global(qos: .utility))
    }

    var isOnline: Bool { state.withLock { $0.online } }
    /// Online and not on cellular: the time to save the library for offline use.
    var isCheap: Bool { state.withLock { $0.online && !$0.expensive } }
    /// False while offline or just after a timeout: requests read the saved copy first and skip the wait.
    var isUsable: Bool { state.withLock { $0.usable(at: .now) } }

    /// ponytail: a flat 30 s pause after one timeout; measure the real round trip if this feels too eager or too slow.
    func markSlow() { state.withLock { $0.slowUntil = .now + 30 } }
    func markFast() { state.withLock { $0.slowUntil = .distantPast } }

    /// The errors that mean "the server can't be reached now", not "this request was cancelled".
    static func isUnreachable(_ error: URLError) -> Bool {
        [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed,
         .internationalRoamingOff].contains(error.code)
    }

    #if DEBUG
    static func selfCheck() {
        let now = Date.now
        assert(State().usable(at: now))
        assert(!State(online: false).usable(at: now))
        assert(!State(slowUntil: now + 5).usable(at: now))
        assert(State(slowUntil: now - 5).usable(at: now))
        assert(isUnreachable(URLError(.timedOut)) && !isUnreachable(URLError(.cancelled)))
    }
    #endif
}
