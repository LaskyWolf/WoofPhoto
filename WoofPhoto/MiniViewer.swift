import SwiftUI

/// The photo that is open: full screen, or folded into the mini viewer above the tab bar.
/// A swipe down on the viewer folds it; the close button and the mini viewer's × close it.
@MainActor @Observable
final class OpenPhoto {
    static let shared = OpenPhoto()
    static let miniID = "mini-viewer"

    private(set) var timeline: Timeline?
    var asset: AssetRef?
    var isExpanded = false
    /// What the viewer zooms out of and back into: the grid cell, or the mini viewer.
    private(set) var zoomSource = ""
    private var closing = false

    func open(_ asset: AssetRef, in timeline: Timeline) {
        self.timeline = timeline
        self.asset = asset
        zoomSource = asset.id
        closing = false
        isExpanded = true
    }

    /// Once the zoom from the cell has played, swiping down folds into the mini viewer.
    func zoomedIn() { if !closing { zoomSource = Self.miniID } }

    func expand() {
        guard asset != nil else { return }
        zoomSource = Self.miniID
        isExpanded = true
    }

    /// Closes for good. Full screen, it zooms back into the photo's cell.
    func close() {
        if isExpanded {
            if let asset { zoomSource = asset.id }
            closing = true
            isExpanded = false
        } else {
            clear()
        }
    }

    /// Called when the full-screen viewer is gone.
    func dismissed() { if closing { clear() } }

    /// The previous or next photo in the same timeline.
    func step(_ offset: Int) {
        guard let assets = timeline?.assets, let index = assets.firstIndex(where: { $0.id == asset?.id }),
              let next = assets[safe: index + offset] else { return }
        asset = next
    }

    private func clear() {
        closing = false
        asset = nil
        timeline = nil
    }
}

extension EnvironmentValues {
    /// The namespace the viewer zooms in, set at the root so every grid shares it.
    @Entry var photoZoom: Namespace.ID?
}

extension View {
    /// The tab bar's accessory, shown only while `enabled`. Before iOS 26.1 the accessory can't be
    /// switched off, so it is added and removed instead.
    @ViewBuilder func bottomAccessory<Content: View>(_ enabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled, content: content)
        } else if enabled {
            tabViewBottomAccessory(content: content)
        } else {
            self
        }
    }

    /// Marks a cell as a place the viewer can zoom out of and back into.
    @ViewBuilder func zoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}

/// The open photo as a bar above the tab bar, like WoofMusic's mini player.
/// Tap or swipe up to open it; swipe sideways for the previous or next photo.
struct MiniViewer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    private let open = OpenPhoto.shared

    var body: some View {
        if let asset = open.asset {
            HStack(spacing: 10) {
                Thumbnail(asset: asset)
                    .frame(width: 30, height: 30)
                    .clipShape(.rect(cornerRadius: 6))
                    .id(asset.id)
                    .transition(.blurReplace)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.title(asset)).font(.footnote.weight(.semibold))
                    if placement != .inline {
                        Text(Self.subtitle(asset)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark") { withAnimation { open.close() } }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .buttonStyle(IconPressStyle())
            }
            .padding(.leading, placement == .inline ? 10 : 16)
            .padding(.trailing, 4)
            .contentShape(.rect)
            .onTapGesture { open.expand() }
            .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                let size = value.translation
                if abs(size.width) > abs(size.height), abs(size.width) > 40 {
                    withAnimation(.snappy) { open.step(size.width < 0 ? 1 : -1) }
                } else if size.height < -30 {
                    open.expand()
                }
            })
            .sensoryFeedback(.selection, trigger: asset.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open photo, \(Self.title(asset))")
            .accessibilityHint("Opens the photo")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open.expand() }
            .accessibilityAction(named: "Next photo") { open.step(1) }
            .accessibilityAction(named: "Previous photo") { open.step(-1) }
            .accessibilityAction(named: "Close") { open.close() }
        }
    }

    static func title(_ asset: AssetRef) -> String {
        asset.date?.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.wide).year()) ?? "Photo"
    }

    private static func subtitle(_ asset: AssetRef) -> String {
        let time = asset.date?.formatted(Date.FormatStyle(timeZone: .gmt).hour().minute()) ?? ""
        guard !asset.isImage else { return asset.livePhotoVideoId == nil ? time : "Live Photo · \(time)" }
        let length = asset.duration.map { Duration.milliseconds($0).formatted(.time(pattern: .minuteSecond)) }
        return ["Video", length].compactMap { $0 }.joined(separator: " · ")
    }
}
