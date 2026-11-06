import AVFoundation
import SwiftUI

/// The photo open in the viewer or in the floating card, and the timeline the viewer pages through.
@MainActor @Observable
final class OpenPhoto {
    static let shared = OpenPhoto()
    static let miniSource = "mini"

    private(set) var timeline: Timeline?
    /// Follows the viewer's paging, so the card shows the photo that was on screen.
    var asset: AssetRef?
    var isExpanded = false
    /// What the viewer grows out of: the tapped cell, then the floating card.
    private(set) var zoomSource = miniSource
    /// The open video's player, shared by its viewer page and the card, so it keeps playing in the card.
    private(set) var player: AVPlayer?
    private(set) var playerID: String?
    private var zoomTask: Task<Void, Never>?

    func open(_ asset: AssetRef, in timeline: Timeline) {
        stopPlayer()
        self.timeline = timeline
        self.asset = asset
        zoomSource = asset.id
        isExpanded = true
        // once the zoom from the cell is over, closing zooms into the card
        zoomTask?.cancel()
        zoomTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { zoomSource = Self.miniSource }
        }
    }

    /// The photo carries on in the floating card.
    func minimize() { isExpanded = false }

    func expand() { if asset != nil { isExpanded = true } }

    func close() {
        isExpanded = false
        asset = nil
        timeline = nil
        stopPlayer()
    }

    func player(for id: String) -> AVPlayer? { playerID == id ? player : nil }

    /// The video now on screen; the one before it stops.
    func adopt(_ player: AVPlayer, for id: String) {
        guard playerID != id else { return }
        if self.player !== player { self.player?.pause() }
        self.player = player
        playerID = id
    }

    private func stopPlayer() {
        player?.pause()
        player = nil
        playerID = nil
    }
}

extension EnvironmentValues {
    /// The namespace the viewer zooms in, set at the root so every grid shares it.
    @Entry var photoZoom: Namespace.ID?
    /// Goes up each time the selected Library tab is tapped again.
    @Entry var libraryReselects = 0
    /// The namespace Collections' pages zoom out of: albums, people, the map and the shortcuts.
    @Entry var shelfZoom: Namespace.ID?
}

extension View {
    /// Marks a cell as a place the viewer can zoom out of and back into.
    @ViewBuilder func zoomSource(_ id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}

/// WoofTube's floating card above the tabs, for the open photo or video. Drag it to any corner,
/// or flick it off the side, leaving a small handle.
struct MiniViewer: View {
    let zoom: Namespace.ID
    @Bindable private var open = OpenPhoto.shared
    @State private var dragOffset = CGSize.zero
    @State private var isMiniLeading = false
    @State private var isMiniTop = false
    @State private var isDocked = false

    /// The date, pause and close strip under the photo.
    private static let miniStripHeight: CGFloat = 44
    /// The glass shows this far around the photo.
    private static let miniInset: CGFloat = 6
    /// Follows the photo's corners, so the glass stays the same width around them.
    private static let cardRadius = Tokens.tileRadius + miniInset
    private static let miniMargin: CGFloat = 12
    /// Keeps the card just above the tab bar, which sits outside this view's safe area.
    private static let tabBarClearance: CGFloat = 58
    private static let handleSize = CGSize(width: 44, height: 96)
    /// The rest of the handle stays off screen, so it reads as attached to the edge.
    private static let handleVisibleWidth: CGFloat = 24

    private var still: UIImage? { open.asset.flatMap(Still.cached) }
    private var isPortrait: Bool { still.map { $0.size.height > $0.size.width } ?? false }
    private var miniSize: CGSize { isPortrait ? CGSize(width: 108, height: 192) : CGSize(width: 192, height: 108) }
    private var miniCardWidth: CGFloat { miniSize.width + Self.miniInset * 2 }
    private var miniCardHeight: CGFloat { Self.miniInset + miniSize.height + Self.miniStripHeight }

    var body: some View {
        GeometryReader { geometry in
            if open.asset != nil {
                content(geometry)
            }
        }
        .ignoresSafeArea(.keyboard)
        .accessibilityHidden(open.isExpanded)
        .onChange(of: open.isExpanded) { _, expanded in
            if expanded { isDocked = false }
        }
    }

    private func content(_ geometry: GeometryProxy) -> some View {
        let insets = geometry.safeAreaInsets
        let screen = CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        )
        let mini = CGPoint(
            x: isMiniLeading ? Self.miniMargin : screen.width - miniCardWidth - Self.miniMargin,
            y: isMiniTop ? insets.top + Self.miniMargin : screen.height - miniCardHeight - insets.bottom - Self.tabBarClearance
        )
        let hiddenX = isMiniLeading ? -miniCardWidth - Self.miniMargin : screen.width + Self.miniMargin

        return ZStack(alignment: .topLeading) {
            card(origin: mini, screen: screen)
                .offset(x: isDocked ? hiddenX : mini.x + dragOffset.width, y: mini.y + dragOffset.height)
            if isDocked {
                handle
                    .offset(
                        x: isMiniLeading ? Self.handleVisibleWidth - Self.handleSize.width : screen.width - Self.handleVisibleWidth,
                        y: mini.y + (miniCardHeight - Self.handleSize.height) / 2
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .animation(.snappy, value: isDocked)
        .ignoresSafeArea()
    }

    private func card(origin: CGPoint, screen: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .circular)
        let player = open.asset.flatMap { open.player(for: $0.id) }
        return ZStack(alignment: .topLeading) {
            ZStack {
                if let still { Image(uiImage: still).resizable().scaledToFill() }
            }
            .frame(width: miniCardWidth, height: miniCardHeight)
            .clipped()
            .blur(radius: 24, opaque: true)
            .saturation(1.4)
            .opacity(0.7)
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Color.clear.glassEffect(.regular, in: shape)

            ZStack {
                if let still { Image(uiImage: still).resizable().scaledToFill() }
                if let player { PlayerLayer(player: player) }
            }
            .frame(width: miniSize.width, height: miniSize.height)
            .background(.black)
            .clipShape(.rect(cornerRadius: Tokens.tileRadius, style: .continuous))
            .padding(Self.miniInset)
            .allowsHitTesting(false)

            MiniControls(
                player: player,
                title: open.asset?.date?.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated).year()),
                videoAreaHeight: Self.miniInset + miniSize.height,
                onExpand: { open.expand() },
                onClose: { open.close() },
                onDragChanged: { value in dragOffset = value.translation },
                onDragEnded: { value in finishMiniDrag(value, origin: origin, screen: screen) }
            )

            if let player { CardEdgeProgress(player: player, radius: Self.cardRadius) }
        }
        .frame(width: miniCardWidth, height: miniCardHeight)
        .matchedTransitionSource(id: OpenPhoto.miniSource, in: zoom) { source in
            source.clipShape(.rect(cornerRadius: Self.cardRadius))
        }
    }

    private var handle: some View {
        Button {
            isDocked = false
        } label: {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.19))
                .overlay(alignment: .leading) {
                    HandleChevron()
                        .stroke(Color(white: 0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 26)
                        .padding(.leading, 8)
                }
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .scaleEffect(x: isMiniLeading ? -1 : 1)
                // Reaches 44 pt, using the space next to the visible part.
                .contentShape(Rectangle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Photo")
    }

    /// Snaps to the corner the flick is heading for. A flick past the screen's side hides the card,
    /// and one past the bottom edge closes it.
    private func finishMiniDrag(_ value: DragGesture.Value, origin: CGPoint, screen: CGSize) {
        let endX = origin.x + value.predictedEndTranslation.width + miniCardWidth / 2
        let endY = origin.y + value.predictedEndTranslation.height + miniCardHeight / 2
        if endY > screen.height {
            withAnimation(.snappy) {
                dragOffset.height = screen.height - origin.y
            } completion: {
                open.close()
                dragOffset = .zero
            }
            return
        }
        withAnimation(.snappy) {
            isMiniLeading = endX < screen.width / 2
            isMiniTop = endY < screen.height / 2
            isDocked = endX < 0 || endX > screen.width
            dragOffset = .zero
        }
    }
}

/// Points at the side of the screen the card comes back from, like the system's Picture in Picture.
private struct HandleChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// The controls on the floating card: the photo shows above, then its date and pause for a video.
private struct MiniControls: View {
    let player: AVPlayer?
    let title: String?
    let videoAreaHeight: CGFloat
    let onExpand: () -> Void
    let onClose: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    @State private var isPaused = true

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: videoAreaHeight)
            HStack(spacing: 0) {
                Text(title ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let player {
                    Button {
                        if isPaused { player.play() } else { player.pause() }
                        isPaused.toggle()
                    } label: {
                        Label(isPaused ? "Play" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .task {
                        // ponytail: polls the player twice a second, like VideoSurface
                        while !Task.isCancelled {
                            isPaused = player.rate == 0
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
            .labelStyle(MiniGlyphLabelStyle())
            .buttonStyle(ZoomPressStyle())
            .frame(maxHeight: .infinity)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
        // closing is a flick past the bottom edge, so VoiceOver gets it as an action
        .accessibilityAction(named: "Close", onClose)
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
    }
}

/// An icon with a full size tap target inside the card's strip.
private struct MiniGlyphLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

/// Playback progress in a straight line across the card's whole bottom, cut by its corners.
private struct CardEdgeProgress: View {
    let player: AVPlayer
    let radius: CGFloat
    private static let lineHeight: CGFloat = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = player.currentItem?.duration.seconds ?? 0
            let fraction = duration.isFinite && duration > 0 ? min(player.currentTime().seconds / duration, 1) : 0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.12))
                    Rectangle().fill(.tint).frame(width: geometry.size.width * fraction)
                }
                .frame(height: Self.lineHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipShape(.rect(cornerRadius: radius, style: .circular))
        .allowsHitTesting(false)
    }
}
