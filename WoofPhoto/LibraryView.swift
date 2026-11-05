import SwiftUI

/// The Library tab: the server's timeline, or this iPhone's photos when no server is signed in.
struct LibraryView: View {
    @Environment(Session.self) private var session
    @State private var timeline = Timeline(.library)
    @State private var device: Timeline?
    @State private var denied = false

    var body: some View {
        NavigationStack {
            if session.client != nil {
                AssetGrid(timeline: timeline, showsLevels: true, title: "Library")
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
            guard session.client == nil, device == nil else { return }
            if await Backup.shared.authorize() { device = .device() } else { denied = true }
        }
    }
}
