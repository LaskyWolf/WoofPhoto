import SwiftUI

/// The photo open full screen, and the timeline the viewer pages through.
@MainActor @Observable
final class OpenPhoto {
    static let shared = OpenPhoto()

    private(set) var timeline: Timeline?
    /// Follows the viewer's paging, so closing zooms back into the cell of the photo on screen.
    var asset: AssetRef?
    var isExpanded = false

    func open(_ asset: AssetRef, in timeline: Timeline) {
        self.timeline = timeline
        self.asset = asset
        isExpanded = true
    }

    func close() { isExpanded = false }

    /// Called when the full-screen viewer is gone.
    func dismissed() {
        asset = nil
        timeline = nil
    }
}

extension EnvironmentValues {
    /// The namespace the viewer zooms in, set at the root so every grid shares it.
    @Entry var photoZoom: Namespace.ID?
}

extension View {
    /// Marks a cell as a place the viewer can zoom out of and back into.
    @ViewBuilder func zoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}
