import AVKit
import Photos
import SwiftUI

/// The bar under a grid in Select mode: share, add to album, favorite, save, archive, hide and delete the selection.
struct SelectionBar: View {
    let timeline: Timeline
    @Binding var selection: Set<String>?

    @Environment(Session.self) private var session
    @State private var actions = AssetActions()

    private var ids: [String] { Array(selection ?? []) }

    var body: some View {
        HStack {
            Button("Share", systemImage: "square.and.arrow.up") { actions.ids = ids; Task { await actions.share(session.client) } }
                .disabled(actions.isTrash)
            Spacer()
            Text(ids.isEmpty ? "Select Items" : "\(ids.count) Selected").font(.headline)
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") { AssetMenuItems(actions: actions, ids: ids) }
            Button("Delete", systemImage: "trash") { actions.ids = ids; actions.confirmsDelete = true }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding()
        .background(.bar)
        .assetActions(actions)
        .onAppear {
            actions.timeline = timeline
            actions.done = { selection = nil }
        }
    }
}

/// Actions on some assets of a timeline, shared by the Select bar and the long-press menu.
@MainActor @Observable
final class AssetActions {
    var timeline: Timeline?
    var ids: [String] = []
    var busy = false
    var message: String?
    var sharing: SharedFiles?
    var addsToAlbum = false
    var confirmsDelete = false
    /// Runs after an action succeeded, like leaving Select mode.
    var done: () -> Void = {}

    var isTrash: Bool { timeline?.query?.isTrash == true }

    func setFavorite(_ favorite: Bool, _ client: ImmichClient?) {
        let ids = ids
        run(client, removes: false) { client in
            try await client.updateAssets(ids, ["isFavorite": favorite])
            for id in ids { self.timeline?.update(id) { $0.isFavorite = favorite } }
        }
    }

    /// Runs an action on `ids`; `removes` takes the items out of this grid.
    func run(_ client: ImmichClient?, removes: Bool, _ action: @escaping (ImmichClient) async throws -> Void) {
        guard let client else { return }
        let ids = Set(ids)
        Task {
            busy = true
            defer { busy = false }
            do {
                try await action(client)
                if removes { timeline?.remove(ids) }
                done()
            } catch {
                message = error.explanation
            }
        }
    }

    func share(_ client: ImmichClient?) async {
        guard let client else { return }
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

    func save(_ client: ImmichClient?) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            let assets = timeline?.assets.filter { ids.contains($0.id) } ?? []
            for asset in assets { try await DeviceLibrary.save(asset, client: client) }
            message = "Saved \(assets.count) items to Photos."
            done()
        } catch {
            message = error.explanation
        }
    }
}

/// The actions as menu items, for the Select bar's menu and a cell's long press.
struct AssetMenuItems: View {
    let actions: AssetActions
    let ids: [String]
    /// Set for one asset, so the menu says Favorite or Unfavorite.
    var isFavorite: Bool?
    @Environment(Session.self) private var session

    var body: some View {
        let client = session.client
        let timeline = actions.timeline
        if actions.isTrash {
            Button("Recover", systemImage: "arrow.uturn.backward") { act { actions.run(client, removes: true) { try await $0.restoreTrash(self.ids) } } }
            Button("Delete for Good", systemImage: "trash", role: .destructive) { act { actions.confirmsDelete = true } }
        } else {
            // WoofMusic's and WoofTube's long press: the three main actions in a row on top
            ControlGroup {
                if let isFavorite {
                    Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") { act { actions.setFavorite(!isFavorite, client) } }
                } else {
                    Button("Favorite", systemImage: "heart") { act { actions.setFavorite(true, client) } }
                }
                Button("Share", systemImage: "square.and.arrow.up") { act { Task { await actions.share(client) } } }
                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") { act { actions.addsToAlbum = true } }
            }
            .controlGroupStyle(.compactMenu)
            Section {
                if isFavorite == nil {
                    Button("Unfavorite", systemImage: "heart.slash") { act { actions.setFavorite(false, client) } }
                }
                Button("Save to iPhone", systemImage: "square.and.arrow.down") { act { Task { await actions.save(client) } } }
                if let album = timeline?.query?.albumID {
                    Button("Remove from Album", systemImage: "minus.circle") { act { actions.run(client, removes: true) { try await $0.removeFromAlbum(album, assets: self.ids) } } }
                }
            }
            Section {
                let back = ["visibility": "timeline"]
                if timeline?.query == .archive {
                    Button("Unarchive", systemImage: "archivebox") { act { actions.run(client, removes: true) { try await $0.updateAssets(self.ids, back) } } }
                } else {
                    Button("Archive", systemImage: "archivebox") { act { actions.run(client, removes: true) { try await $0.updateAssets(self.ids, ["visibility": "archive"]) } } }
                }
                if timeline?.query == .hidden {
                    Button("Unhide", systemImage: "eye") { act { actions.run(client, removes: true) { try await $0.updateAssets(self.ids, back) } } }
                } else {
                    Button("Hide", systemImage: "eye.slash") { act { actions.run(client, removes: true) { try await $0.updateAssets(self.ids, ["visibility": "locked"]) } } }
                }
            }
            Section {
                Button("Delete", systemImage: "trash", role: .destructive) { act { actions.confirmsDelete = true } }
            }
        }
    }

    /// Every item acts on this menu's assets.
    private func act(_ body: () -> Void) {
        actions.ids = ids
        body()
    }
}

extension View {
    /// The sheets, confirmation and messages the actions open.
    func assetActions(_ actions: AssetActions) -> some View {
        modifier(AssetActionsHost(actions: actions))
    }
}

private struct AssetActionsHost: ViewModifier {
    @Bindable var actions: AssetActions
    @Environment(Session.self) private var session

    func body(content: Content) -> some View {
        content
            .disabled(actions.busy)
            .overlay { if actions.busy { ProgressView() } }
            .sheet(item: $actions.sharing) { ActivityView(items: $0.urls).ignoresSafeArea() }
            .sheet(isPresented: $actions.addsToAlbum) {
                AlbumPicker(assets: actions.ids) { name in
                    actions.message = "Added to \(name)."
                    actions.done()
                }
            }
            .confirmationDialog(actions.isTrash ? "These items will be deleted for good. This can't be undone." : "These items move to Recently Deleted.",
                                isPresented: $actions.confirmsDelete, titleVisibility: .visible) {
                Button(actions.ids.count == 1 ? "Delete" : "Delete \(actions.ids.count) Items", role: .destructive) {
                    let force = actions.isTrash, ids = actions.ids
                    actions.run(session.client, removes: true) { try await $0.deleteAssets(ids, force: force) }
                }
            }
            .alert(actions.message ?? "", isPresented: Binding { actions.message != nil } set: { if !$0 { actions.message = nil } }) {}
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

    /// A photo from the iPhone's library, at about `side` pixels.
    static func image(_ localID: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // one callback, the final image
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func playerItem(_ localID: String) async -> AVPlayerItem? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
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
