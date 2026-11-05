import SwiftUI

/// The Library tab: every photo and video in the timeline.
struct LibraryView: View {
    @State private var timeline = Timeline(.library)

    var body: some View {
        NavigationStack {
            AssetGrid(timeline: timeline, showsLevels: true, title: "Library")
        }
    }
}
