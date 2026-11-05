import SwiftUI

/// The Library tab: every photo and video in the timeline.
struct LibraryView: View {
    @State private var timeline = Timeline(.library)
    @State private var showsAccount = false

    var body: some View {
        NavigationStack {
            AssetGrid(timeline: timeline, showsLevels: true)
                .navigationTitle("Library")
                .navigationSubtitle(timeline.months == nil ? "" : "\(timeline.count.formatted()) Items")
                .toolbar {
                    Button("Account", systemImage: "person.crop.circle") { showsAccount = true }
                }
                .sheet(isPresented: $showsAccount) {
                    NavigationStack {
                        SpikesView().toolbar {
                            Button("Done", role: .close) { showsAccount = false }
                        }
                    }
                }
        }
    }
}
