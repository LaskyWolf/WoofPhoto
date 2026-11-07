import SwiftUI

/// The Library tab: the server's timeline, or this iPhone's photos when no server is signed in.
struct LibraryView: View {
    @Environment(Session.self) private var session
    @State private var timeline = Timeline(.library)
    @State private var device: Timeline?
    @State private var denied = false
    @State private var unreachable = false
    @State private var checking = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            if session.client != nil {
                AssetGrid(timeline: timeline, showsLevels: true, title: "Library")
                    // under the pill, so the sparks fall behind it
                    .overlay(alignment: .top) {
                        if unreachable, !reduceMotion { SparkBurst().padding(.top, 52).allowsHitTesting(false) }
                    }
                    .overlay(alignment: .top) {
                        if unreachable {
                            OfflinePill(checking: checking, tailscale: ImmichClient.isTailscale(session.client?.server.host() ?? "")) {
                                Task { await check() }
                            }
                            // ponytail: fixed drop below the header; measure TabHeader if its height changes
                            .padding(.top, 58)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .top).combined(with: .offset(y: -60)).combined(with: .opacity))
                        }
                    }
                    .task(id: scenePhase) { if scenePhase == .active { await check() } }
            } else if let device {
                AssetGrid(timeline: device, showsLevels: true, title: "Library")
            } else if denied {
                VStack {
                    TabHeader(title: "Library")
                    ContentUnavailableView {
                        Label("No Access to Photos", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Allow access in Settings to see this iPhone's photos, or sign in to your Immich server with the account button.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: session.client == nil) {
            // the next account starts from an empty timeline, not the last one's months
            if session.client == nil { timeline = Timeline(.library) }
            guard session.client == nil, device == nil else { return }
            if await Backup.shared.authorize() { device = .device() } else { denied = true }
        }
    }

    /// Asks the server; on the way back from offline, reloads the photos.
    private func check() async {
        guard let client = session.client else { return }
        checking = true
        // the local address first, so the check below asks the address requests will use
        await ImmichClient.chooseAddress()
        let reachable = await client.isReachable()
        checking = false
        withAnimation(reduceMotion ? .default : .spring(duration: 0.6, bounce: 0.45)) { unreachable = !reachable }
        if reachable, timeline.problem != nil { try? await timeline.reload(with: client) }
    }
}

/// Floats under the Library title while the server doesn't answer: a plug that keeps missing its socket, and Retry.
/// For a server on Tailscale, it says the VPN may be off and opens the Tailscale app.
private struct OfflinePill: View {
    let checking: Bool
    let tailscale: Bool
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var title: String { tailscale ? "Tailscale may be off" : "Immich is unreachable" }

    var body: some View {
        HStack(spacing: 8) {
            UnpluggedGlyph(animated: !reduceMotion)
                .frame(width: 22, height: 22)
                .frame(width: 32, height: 32)
                .background(Color(red: 0.89, green: 0.29, blue: 0.29), in: .circle)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.99, green: 0.92, blue: 0.92))
            if tailscale {
                Button(action: openTailscale) { pillLabel("Open") }
                    .buttonStyle(ZoomPressStyle())
                    .accessibilityLabel("Open Tailscale")
            }
            Button(action: onRetry) {
                ZStack {
                    Text("Retry").opacity(checking ? 0 : 1)
                    if checking { ProgressView().controlSize(.mini).tint(Color(red: 0.47, green: 0.12, blue: 0.12)) }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(red: 0.31, green: 0.07, blue: 0.07))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(red: 0.97, green: 0.76, blue: 0.76), in: .capsule)
                .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(ZoomPressStyle())
            .disabled(checking)
        }
        .padding(6)
        .glassEffect(.regular.tint(Color(red: 0.47, green: 0.12, blue: 0.12).opacity(0.85)), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAction(named: "Retry", onRetry)
        .accessibilityActions { if tailscale { Button("Open Tailscale", action: openTailscale) } }
    }

    /// Same look as Retry.
    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(red: 0.31, green: 0.07, blue: 0.07))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(red: 0.97, green: 0.76, blue: 0.76), in: .capsule)
            .contentShape(Rectangle().inset(by: -8))
    }

    /// The app if it's installed, else its App Store page. No canOpenURL, so no URL scheme to declare.
    private func openTailscale() {
        guard let app = URL(string: "tailscale://"), let store = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") else { return }
        openURL(app) { opened in if !opened { openURL(store) } }
    }
}

/// A plug and a socket on the diagonal, drawn in lines, swinging in and bouncing back without meeting.
private struct UnpluggedGlyph: View {
    let animated: Bool

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 24
            ZStack {
                Plug().stroke(.white, style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round, lineJoin: .round))
                    .keyframeAnimator(initialValue: CGFloat(-1.2), repeating: animated) { content, x in
                        content.offset(x: x * unit)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(2, duration: 0.67)
                            CubicKeyframe(1.2, duration: 0.13)
                            CubicKeyframe(1.8, duration: 0.1)
                            CubicKeyframe(-1.2, duration: 0.7)
                        }
                    }
                Socket().stroke(.white, style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round, lineJoin: .round))
                    .keyframeAnimator(initialValue: CGFloat(1.2), repeating: animated) { content, x in
                        content.offset(x: x * unit)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(-2, duration: 0.67)
                            CubicKeyframe(-1.2, duration: 0.13)
                            CubicKeyframe(-1.8, duration: 0.1)
                            CubicKeyframe(1.2, duration: 0.7)
                        }
                    }
            }
            .rotationEffect(.degrees(-45))
            // in close, back a little, in again, then fully apart: 1.6 seconds, never touching
        }
        .accessibilityHidden(true)
    }

    /// Drawn on a 24-point grid, scaled to the frame.
    private struct Plug: Shape {
        func path(in rect: CGRect) -> Path {
            let u = rect.width / 24
            var path = Path()
            path.move(to: CGPoint(x: 1 * u, y: 12 * u)); path.addLine(to: CGPoint(x: 4 * u, y: 12 * u))
            path.addRoundedRect(in: CGRect(x: 4 * u, y: 8 * u, width: 4.5 * u, height: 8 * u), cornerSize: CGSize(width: 1.5 * u, height: 1.5 * u))
            path.move(to: CGPoint(x: 8.5 * u, y: 10.2 * u)); path.addLine(to: CGPoint(x: 11 * u, y: 10.2 * u))
            path.move(to: CGPoint(x: 8.5 * u, y: 13.8 * u)); path.addLine(to: CGPoint(x: 11 * u, y: 13.8 * u))
            return path
        }
    }

    private struct Socket: Shape {
        func path(in rect: CGRect) -> Path {
            let u = rect.width / 24
            var path = Path()
            path.move(to: CGPoint(x: 23 * u, y: 12 * u)); path.addLine(to: CGPoint(x: 20 * u, y: 12 * u))
            path.addRoundedRect(in: CGRect(x: 13.5 * u, y: 8 * u, width: 6.5 * u, height: 8 * u), cornerSize: CGSize(width: 1.5 * u, height: 1.5 * u))
            return path
        }
    }
}

/// One burst of 45 sparks falling from the whole width of the top bar's bottom edge, gone in about 1.3 seconds.
private struct SparkBurst: View {
    private struct Spark {
        let x: CGFloat, dx: CGFloat, dy: CGFloat, size: CGFloat, delay: Double, duration: Double, color: Color
    }

    private static let colors: [Color] = [
        Color(red: 0.89, green: 0.29, blue: 0.29), Color(red: 0.94, green: 0.58, blue: 0.58),
        Color(red: 0.98, green: 0.78, blue: 0.46), Color(red: 0.97, green: 0.76, blue: 0.76),
        Color(red: 0.94, green: 0.62, blue: 0.15), Color(red: 0.64, green: 0.18, blue: 0.18),
    ]
    @State private var start = Date.now
    @State private var done = false
    @State private var sparks = (0..<45).map { i in
        Spark(x: .random(in: 0...1), dx: .random(in: -25...25), dy: .random(in: 40...220), size: .random(in: 2...6),
              delay: .random(in: 0.2...0.5), duration: .random(in: 0.7...1.3), color: colors[i % colors.count])
    }

    var body: some View {
        if !done { canvas.task { try? await Task.sleep(for: .seconds(2)); done = true } }
    }

    private var canvas: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let elapsed = context.date.timeIntervalSince(start)
                for spark in sparks {
                    let p = min(max((elapsed - spark.delay) / spark.duration, 0), 1)
                    guard p > 0, p < 1 else { continue }
                    let eased = 1 - pow(1 - p, 3)
                    let side = spark.size * (1 - 0.8 * eased)
                    canvas.opacity = p < 0.08 ? p / 0.08 : 1 - p
                    canvas.fill(Path(ellipseIn: CGRect(x: spark.x * size.width + spark.dx * eased - side / 2,
                                                       y: spark.dy * eased - side / 2, width: side, height: side)),
                                with: .color(spark.color))
                }
            }
        }
        .frame(height: 240)
        .padding(.horizontal, Tokens.screenPadding)
    }
}
