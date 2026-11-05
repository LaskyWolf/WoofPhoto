import AVKit
import Photos
import SwiftUI

/// The bar under a grid in Select mode: share, add to album, favorite, save, archive, hide and delete the selection.
struct SelectionBar: View {
    let timeline: Timeline
    @Binding var selection: Set<String>?

    @Environment(Session.self) private var session
    @State private var busy = false
    @State private var message: String?
    @State private var sharing: SharedFiles?
    @State private var addsToAlbum = false
    @State private var confirmsDelete = false

    private var ids: [String] { Array(selection ?? []) }
    private var isTrash: Bool { timeline.query?.isTrash == true }

    var body: some View {
        HStack {
            Button("Share", systemImage: "square.and.arrow.up") { Task { await share() } }
                .disabled(isTrash)
            Spacer()
            Text(ids.isEmpty ? "Select Items" : "\(ids.count) Selected").font(.headline)
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") { actions }
            Button("Delete", systemImage: "trash") { confirmsDelete = true }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .disabled(busy)
        .padding()
        .background(.bar)
        .overlay { if busy { ProgressView() } }
        .sheet(item: $sharing) { ActivityView(items: $0.urls).ignoresSafeArea() }
        .sheet(isPresented: $addsToAlbum) {
            AlbumPicker(assets: ids) { name in
                message = "Added to \(name)."
                selection = nil
            }
        }
        .confirmationDialog(isTrash ? "These items will be deleted for good. This can't be undone." : "These items move to Recently Deleted.",
                            isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete \(ids.count) Items", role: .destructive) {
                run(removes: true) { try await $0.deleteAssets(ids, force: isTrash) }
            }
        }
        .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {}
    }

    @ViewBuilder private var actions: some View {
        if isTrash {
            Button("Recover", systemImage: "arrow.uturn.backward") { run(removes: true) { try await $0.restoreTrash(ids) } }
        } else {
            Button("Add to Album…", systemImage: "rectangle.stack.badge.plus") { addsToAlbum = true }
            Button("Favorite", systemImage: "heart") { setFavorite(true) }
            Button("Unfavorite", systemImage: "heart.slash") { setFavorite(false) }
            Button("Save to iPhone", systemImage: "square.and.arrow.down") { Task { await save() } }
            if let album = timeline.query?.albumID {
                Button("Remove from Album", systemImage: "minus.circle") {
                    run(removes: true) { try await $0.removeFromAlbum(album, assets: ids) }
                }
            }
            Divider()
            let back = ["visibility": "timeline"]
            if timeline.query == .archive {
                Button("Unarchive", systemImage: "archivebox") { run(removes: true) { try await $0.updateAssets(ids, back) } }
            } else {
                Button("Archive", systemImage: "archivebox") { run(removes: true) { try await $0.updateAssets(ids, ["visibility": "archive"]) } }
            }
            if timeline.query == .hidden {
                Button("Unhide", systemImage: "eye") { run(removes: true) { try await $0.updateAssets(ids, back) } }
            } else {
                Button("Hide", systemImage: "eye.slash") { run(removes: true) { try await $0.updateAssets(ids, ["visibility": "locked"]) } }
            }
        }
    }

    private func setFavorite(_ favorite: Bool) {
        let ids = ids
        run(removes: false) { client in
            try await client.updateAssets(ids, ["isFavorite": favorite])
            for id in ids { timeline.update(id) { $0.isFavorite = favorite } }
        }
    }

    /// Runs an action on the selection, then leaves Select mode; `removes` takes the items out of this grid.
    private func run(removes: Bool, _ action: @escaping (ImmichClient) async throws -> Void) {
        guard let client = session.client else { return }
        let ids = Set(ids)
        Task {
            busy = true
            defer { busy = false }
            do {
                try await action(client)
                if removes { timeline.remove(ids) }
                selection = nil
            } catch {
                message = error.explanation
            }
        }
    }

    private func share() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            var urls: [URL] = []
            for id in ids { urls.append(try await client.downloadOriginal(id)) }
            sharing = SharedFiles(urls: urls)
        } catch {
            message = error.explanation
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            let assets = timeline.assets.filter { selection?.contains($0.id) == true }
            for asset in assets { try await DeviceLibrary.save(asset, client: client) }
            message = "Saved \(assets.count) items to Photos."
            selection = nil
        } catch {
            message = error.explanation
        }
    }
}

struct SharedFiles: Identifiable {
    let urls: [URL]
    var id: [URL] { urls }
}

/// Saving to the iPhone's own Photos library.
enum DeviceLibrary {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "Allow WoofPhoto to add photos in Settings > Privacy & Security > Photos." }
    }

    /// Saves the original; a Live Photo keeps its video so it still moves.
    static func save(_ asset: AssetRef, client: ImmichClient) async throws {
        let file = try await client.downloadOriginal(asset.id)
        var motion: URL?
        if let video = asset.livePhotoVideoId { motion = try await client.downloadOriginal(video) }
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: asset.isImage ? .photo : .video, fileURL: file, options: nil)
            if let motion { request.addResource(with: .pairedVideo, fileURL: motion, options: nil) }
        }
    }
}

/// Photos one after another with a cross-fade. Videos are skipped; tap to stop.
struct Slideshow: View {
    let assets: [AssetRef]

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var image: UIImage?

    init(assets: [AssetRef], start: Int) {
        self.assets = assets.filter(\.isImage)
        _index = State(initialValue: max(0, self.assets.firstIndex { $0.id == assets[safe: start]?.id } ?? 0))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .id(index)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                AirPlayButton().frame(width: 44, height: 44)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .padding()
        }
        .onTapGesture { dismiss() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            guard !assets.isEmpty else { return }
            while !Task.isCancelled {
                let next = await Still.load(assets[index].id, size: "preview", client: session.client)
                withAnimation(.easeInOut(duration: 1)) { image = next }
                try? await Task.sleep(for: .seconds(3))
                index = (index + 1) % assets.count
            }
        }
    }
}

/// The system AirPlay button: sends videos to an Apple TV, or mirrors the screen for a slideshow.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
