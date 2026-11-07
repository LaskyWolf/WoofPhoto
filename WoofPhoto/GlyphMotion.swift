import SwiftUI

// WoofTube's icon movements (GlyphMotion.swift there), trimmed to what the video player uses.

/// One moment of an icon's movement. Distances are in points.
struct GlyphPose {
    var scaleX = 1.0
    var scaleY = 1.0
    var x = 0.0
    var y = 0.0

    fileprivate func mixed(with other: GlyphPose, by amount: Double) -> GlyphPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return GlyphPose(scaleX: mix(scaleX, other.scaleX), scaleY: mix(scaleY, other.scaleY), x: mix(x, other.x), y: mix(y, other.y))
    }
}

/// How one icon moves, worked out from the time since the tap, so nothing keeps running afterwards.
struct GlyphScript {
    struct Key {
        let time: Double
        let pose: GlyphPose

        init(_ time: Double, sx: Double = 1, sy: Double = 1, x: Double = 0, y: Double = 0) {
            self.time = time
            pose = GlyphPose(scaleX: sx, scaleY: sy, x: x, y: y)
        }

        init(_ time: Double, s: Double, x: Double = 0, y: Double = 0) {
            self.init(time, sx: s, sy: s, x: x, y: y)
        }
    }

    let keys: [Key]
    /// An accent ring that grows out of the icon and fades.
    var ring = false
    var ringSize = 28.0

    static let ringLife = 0.6

    var duration: Double { max(keys.last?.time ?? 0, ring ? Self.ringLife : 0) }

    func pose(at time: Double) -> GlyphPose {
        guard let first = keys.first, let last = keys.last else { return GlyphPose() }
        if time <= first.time { return first.pose }
        if time >= last.time { return last.pose }
        for (start, end) in zip(keys, keys.dropFirst()) where time < end.time {
            let x = (time - start.time) / (end.time - start.time)
            return start.pose.mixed(with: end.pose, by: x * x * (3 - 2 * x))
        }
        return last.pose
    }

    /// Pause lands like a stamp; the distances follow the icon's size.
    static func pauseStamp(size: Double) -> GlyphScript {
        GlyphScript(keys: [Key(0, s: 1.3, y: -0.24 * size), Key(0.14, sx: 1.12, sy: 0.82), Key(0.28, s: 1)])
    }
    /// Play shoots forward and sends out a ring around it.
    static func playShoot(size: Double) -> GlyphScript {
        GlyphScript(keys: [Key(0, sx: 1.25, sy: 0.7, x: -0.2 * size), Key(0.16, sx: 0.92, sy: 1.1, x: 0.07 * size), Key(0.3, s: 1)],
                    ring: true, ringSize: size * 1.05)
    }
    static let pop = GlyphScript(keys: [Key(0, s: 0.8), Key(0.14, s: 1.16), Key(0.3, s: 1)])
    static let deflate = GlyphScript(keys: [Key(0, s: 1.1), Key(0.14, s: 0.82), Key(0.26, s: 1)])
    /// A skip: the arrow dashes the way it points.
    static func dash(forward: Bool) -> GlyphScript {
        let d = forward ? 1.0 : -1.0
        return GlyphScript(keys: [Key(0, sx: 1.2, sy: 0.8, x: -10 * d), Key(0.16, x: 3 * d), Key(0.28, x: -d), Key(0.4, s: 1)])
    }

    static func selfCheck() {
        // every movement lands where the icon rests, or it jumps at the end
        for script in [pauseStamp(size: 20), playShoot(size: 20), pop, deflate, dash(forward: true), dash(forward: false)] {
            let end = script.pose(at: script.duration)
            assert(end.scaleX == 1 && end.scaleY == 1 && end.x == 0 && end.y == 0)
        }
        assert(GlyphScript(keys: [.init(0, s: 0), .init(1, s: 2)]).pose(at: 0.5).scaleX == 1)
    }
}

private struct GlyphRunner<Trigger: Equatable>: ViewModifier {
    let script: GlyphScript?
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: (start: Date, script: GlyphScript)?

    func body(content: Content) -> some View {
        // paused unless it's moving, so a resting icon costs nothing
        TimelineView(.animation(minimumInterval: nil, paused: run == nil)) { context in
            let time = run.map { context.date.timeIntervalSince($0.start) } ?? 0
            let pose = run?.script.pose(at: time) ?? GlyphPose()
            content
                .scaleEffect(x: pose.scaleX, y: pose.scaleY)
                .offset(x: pose.x, y: pose.y)
                .overlay {
                    if let run, run.script.ring {
                        let progress = min(max(time / GlyphScript.ringLife, 0), 1)
                        Circle()
                            .stroke(.tint, lineWidth: 1.5)
                            .frame(width: run.script.ringSize, height: run.script.ringSize)
                            .scaleEffect(0.6 + progress * 1.3)
                            .opacity(progress > 0 && progress < 1 ? 0.8 * (1 - progress) : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .onChange(of: trigger) {
            guard !reduceMotion, let script else { return }
            run = (Date(), script)
        }
        .task(id: run?.start) {
            guard let current = run else { return }
            try? await Task.sleep(for: .seconds(current.script.duration))
            if !Task.isCancelled, run?.start == current.start { run = nil }
        }
    }
}

extension View {
    /// Plays a movement each time `trigger` changes. Without a script it does nothing, and Reduce Motion skips it.
    func glyphMotion<Trigger: Equatable>(_ script: GlyphScript?, trigger: Trigger) -> some View {
        modifier(GlyphRunner(script: script, trigger: trigger))
    }
}

/// Play melts into pause and back, then stamps or shoots, as in WoofTube and WoofMusic.
struct PlayPauseGlyph: View {
    let isPaused: Bool
    let size: Double

    var body: some View {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .animation(.snappy, value: isPaused)
            .glyphMotion(isPaused ? .playShoot(size: size) : .pauseStamp(size: size), trigger: isPaused)
    }
}
