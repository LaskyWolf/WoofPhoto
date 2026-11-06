import AVKit
import MapKit
import Photos
import PhotosUI
import SwiftUI
import VisionKit

/// Full-screen pages through a timeline, like the Photos viewer. Opens with a zoom from the tapped cell;
/// swiping down closes it back into the cell.
struct Viewer: View {
    let timeline: Timeline

    @Environment(Session.self) private var session
    @State private var current: String?
    @State private var detail: Asset?
    @State private var stack: Stack?
    /// The stack member shown in place of a stack's top asset, after picking it in the strip.
    @State private var shownInStack: [String: String] = [:]
    @State private var chromeHidden = false
    /// Height of the bottom bars, so a video's progress bar sits above them.
    @State private var chromeInset: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showsInfo = false
    @State private var confirmsDelete = false
    @State private var sharing: SharedFile?
    @State private var busy = false
    @State private var message: String?
    @State private var addsToAlbum = false
    @State private var playsSlideshow = false
    @State private var spatial: AssetRef?
    @State private var editing: AssetRef?

    init(timeline: Timeline, start: AssetRef) {
        self.timeline = timeline
        _current = State(initialValue: start.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(timeline.assets) { asset in
                        ViewerPage(asset: shown(asset), isCurrent: asset.id == current, chromeHidden: $chromeHidden) {
                            if !voiceOver { withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() } }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            // WoofTube's ambient mode: the photo itself, blurred, instead of black
            .background { ambient }
            // a swipe up pulls up the details, as in Photos
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                let (x, y) = (value.translation.width, value.translation.height)
                if y < -80, abs(y) > abs(x) * 2, shownAsset?.localID == nil { showsInfo = true }
            })
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(chromeHidden)
            .overlay(alignment: .top) { if !chromeHidden { handle.transition(.opacity) } }
            .safeAreaInset(edge: .bottom) {
                if !chromeHidden {
                    VStack(spacing: 10) {
                        if let caption = dateLine { Text(caption).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85)) }
                        stackStrip
                        filmstrip
                        toolBar
                    }
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeInset = $0 }
                    .transition(.opacity)
                }
            }
            .environment(\.viewerInset, chromeInset)
            .environment(\.colorScheme, .dark)
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .task(id: current) {
                if let asset = timeline.assets.first(where: { $0.id == current }) { OpenPhoto.shared.asset = asset }
                await currentChanged()
            }
            .sheet(isPresented: $showsInfo) {
                if let id = shownID { InfoSheet(id: id) }
            }
            .sheet(item: $sharing) { file in
                ActivityView(items: [file.url]).ignoresSafeArea()
            }
            .confirmationDialog(timeline.query?.isTrash == true ? "This item will be deleted for good. This can't be undone." : "This item moves to Recently Deleted.",
                                isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .fullScreenCover(isPresented: $playsSlideshow) {
                Slideshow(assets: timeline.assets, start: timeline.assets.firstIndex { $0.id == current } ?? 0)
            }
            .fullScreenCover(item: $spatial) { SpatialView(asset: $0).environment(session) }
            .fullScreenCover(item: $editing) { asset in
                EditorView(asset: asset) { editSaved() }
            }
            .sheet(isPresented: $addsToAlbum) {
                AlbumPicker(assets: [shownID].compactMap { $0 }) { message = "Added to \($0)." }
            }
            .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {}
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Parts

    private var ambient: some View {
        ZStack {
            Color.black
            if let asset = shownAsset, let image = Still.cached(asset) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50, opaque: true)
                    .saturation(1.4)
                    .opacity(0.55)
                    .id(asset.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: shownID)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// The only thing on top: WoofMusic's player handle, which says the viewer pulls down to close.
    private var handle: some View {
        Button { OpenPhoto.shared.close() } label: {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 36, height: 5)
                .frame(width: 80, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    private var dateLine: String? {
        guard let date = (detail?.date ?? shownAsset?.date) else { return nil }
        let day = date.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.wide).year())
        let time = date.formatted(Date.FormatStyle(timeZone: .gmt).hour().minute())
        return [day, time, detail?.exifInfo?.city].compactMap { $0 }.joined(separator: " · ")
    }

    /// The photos before and after this one; tap one to jump to it.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(timeline.assets) { asset in
                        let isCurrent = asset.id == current
                        Thumbnail(asset: asset, square: false, cornerRadius: 6)
                            .frame(width: isCurrent ? 46 : 30, height: 46)
                            .overlay { if isCurrent { RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2) } }
                            .onTapGesture { withAnimation(.snappy) { current = asset.id } }
                            .id(asset.id)
                    }
                }
                .padding(.horizontal, Tokens.screenPadding)
            }
            .scrollIndicators(.hidden)
            .frame(height: 46)
            .onChange(of: current, initial: true) { withAnimation(.snappy) { proxy.scrollTo(current, anchor: .center) } }
            .sensoryFeedback(.selection, trigger: current)
        }
        .accessibilityHidden(true)
    }

    /// Every tool, in one glass bar at the bottom, with WoofMusic's white player glyphs.
    private var toolBar: some View {
        HStack(spacing: 0) {
            if timeline.query?.isTrash == true {
                Button("Recover", systemImage: "arrow.uturn.backward") {
                    Task { await perform {
                        try await session.client?.restoreTrash([shownID ?? ""])
                        removeCurrent()
                    } }
                }
                Spacer()
                Button("Delete", systemImage: "trash") { confirmsDelete = true }
            } else if shownAsset?.localID != nil {
                editButton
                spatialButton
                Spacer()
                Button {
                    if let client = session.client { Backup.shared.start(with: client) }
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up").labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                }
                .disabled(session.client == nil)
            } else {
                Button("Share", systemImage: "square.and.arrow.up") { Task { await share() } }
                Spacer(minLength: 0)
                let favorite = shownAsset?.isFavorite == true
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                        .foregroundStyle(favorite ? AnyShapeStyle(.pink) : AnyShapeStyle(.white))
                        .contentTransition(.symbolEffect(.replace))
                }
                .sensoryFeedback(.impact(weight: .light), trigger: favorite)
                Spacer(minLength: 0)
                editButton
                Spacer(minLength: 0)
                spatialButton
                Spacer(minLength: 0)
                Button("Info", systemImage: "info.circle") { showsInfo = true }
                Spacer(minLength: 0)
                moreMenu
            }
        }
        .labelStyle(GlyphLabelStyle())
        .buttonStyle(GlyphPressStyle())
        .padding(.horizontal, 10)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Tokens.screenPadding)
    }

    @ViewBuilder private var editButton: some View {
        if timeline.query?.isTrash != true {
            Button("Edit", systemImage: "slider.horizontal.3") { editing = shownAsset }
        }
    }

    @ViewBuilder private var spatialButton: some View {
        if let shownAsset, shownAsset.isImage {
            Button("Spatial Scene", systemImage: "cube") { spatial = shownAsset }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy", systemImage: "doc.on.doc") { Task { await copy() } }
            Button("Save to iPhone", systemImage: "square.and.arrow.down") { Task { await save() } }
            Button("Add to Album…", systemImage: "rectangle.stack.badge.plus") { addsToAlbum = true }
            Button("Slideshow", systemImage: "play.rectangle") { playsSlideshow = true }
            if let album = timeline.query?.albumID {
                Section {
                    Button("Make Key Photo", systemImage: "photo") {
                        Task { await perform {
                            try await session.client?.updateAlbum(album, ["albumThumbnailAssetId": shownID ?? ""])
                            message = "Key photo changed."
                        } }
                    }
                    Button("Remove from Album", systemImage: "minus.circle") {
                        Task { await perform {
                            try await session.client?.removeFromAlbum(album, assets: [shownID ?? ""])
                            removeCurrent()
                        } }
                    }
                }
            }
            Section {
                if timeline.query == .hidden {
                    Button("Unhide", systemImage: "eye") { Task { await move(to: "timeline", done: "Moved to Library.") } }
                } else {
                    Button("Hide", systemImage: "eye.slash") { Task { await move(to: "locked", done: "Moved to Hidden.") } }
                }
                if timeline.query == .archive {
                    Button("Unarchive", systemImage: "archivebox") { Task { await move(to: "timeline", done: "Moved to Library.") } }
                } else {
                    Button("Archive", systemImage: "archivebox") { Task { await move(to: "archive", done: "Moved to Archive.") } }
                }
            }
            Section {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// Thumbnails of a stack's members (a burst, or RAW + JPEG); tap one to show it.
    @ViewBuilder private var stackStrip: some View {
        if let stack, stack.assets.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(stack.assets) { member in
                        Thumbnail(asset: member.ref, cornerRadius: 6)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if member.id == shownID { RoundedRectangle(cornerRadius: 6).stroke(.tint, lineWidth: 2) }
                            }
                            .onTapGesture {
                                if let current { shownInStack[current] = member.id }
                            }
                    }
                }
                .padding(.horizontal, Tokens.screenPadding)
            }
            .scrollIndicators(.hidden)
            .frame(height: 36)
        }
    }

    // MARK: State

    private var currentAsset: AssetRef? { timeline.assets.first { $0.id == current } }
    private var shownAsset: AssetRef? { currentAsset.map(shown) }
    private var shownID: String? { shownAsset?.id }

    private func shown(_ asset: AssetRef) -> AssetRef {
        guard let id = shownInStack[asset.id], let member = stack?.assets.first(where: { $0.id == id }) else { return asset }
        return member.ref
    }

    private func currentChanged() async {
        guard let current, let client = session.client else { return }
        await timeline.loadNeighbours(of: current, with: client)
        detail = try? await client.asset(current)
        if let stackID = currentAsset?.stackID {
            if stack?.id != stackID { stack = try? await client.stack(stackID) }
        } else {
            stack = nil
        }
    }

    // MARK: Actions

    private func toggleFavorite() async {
        guard let asset = shownAsset, let client = session.client else { return }
        do {
            try await client.updateAssets([asset.id], ["isFavorite": !asset.isFavorite])
            timeline.update(asset.id) { $0.isFavorite.toggle() }
        } catch {
            message = error.explanation
        }
    }

    private func delete() async {
        guard let id = shownID, let client = session.client else { return }
        await perform {
            try await client.deleteAssets([id], force: timeline.query?.isTrash == true)
            removeCurrent()
        }
    }

    /// Hidden and Archive take the asset out of this timeline.
    private func move(to visibility: String, done: String) async {
        guard let id = shownID, let client = session.client else { return }
        await perform {
            try await client.updateAssets([id], ["visibility": visibility])
            removeCurrent()
            message = done
        }
    }

    /// An edit may replace the asset with a new one, so the grid reloads its month and the viewer closes.
    private func editSaved() {
        if let current { timeline.invalidate(containing: current) }
        OpenPhoto.shared.close()
    }

    private func removeCurrent() {
        guard let current else { return }
        let assets = timeline.assets
        let index = assets.firstIndex { $0.id == current } ?? 0
        let next = assets.indices.contains(index + 1) ? assets[index + 1] : assets.indices.contains(index - 1) ? assets[index - 1] : nil
        timeline.remove([current])
        if let next { self.current = next.id } else { OpenPhoto.shared.close() }
    }

    private func share() async {
        guard let id = shownID, let client = session.client else { return }
        await perform {
            let url = try await client.downloadOriginal(id)
            sharing = SharedFile(url: url)
        }
    }

    private func copy() async {
        guard let id = shownID, let client = session.client else { return }
        await perform {
            let file = try await client.downloadOriginal(id)
            if let provider = NSItemProvider(contentsOf: file) { UIPasteboard.general.itemProviders = [provider] }
            message = "Copied."
        }
    }

    private func save() async {
        guard let asset = shownAsset, let client = session.client else { return }
        await perform {
            try await DeviceLibrary.save(asset, client: client)
            message = "Saved to Photos."
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
        } catch {
            message = error.explanation
        }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

// MARK: - Pages

/// One page of the viewer: a zoomable photo, a Live Photo or a video.
struct ViewerPage: View {
    let asset: AssetRef
    let isCurrent: Bool
    @Binding var chromeHidden: Bool
    let onTap: () -> Void

    var body: some View {
        if asset.localID != nil {
            DevicePage(asset: asset, isCurrent: isCurrent, chromeHidden: $chromeHidden, onTap: onTap)
        } else if !asset.isImage {
            VideoPage(asset: asset, isCurrent: isCurrent, chromeHidden: $chromeHidden, onTap: onTap)
        } else if asset.livePhotoVideoId != nil {
            LivePage(asset: asset, isCurrent: isCurrent, onTap: onTap)
        } else {
            PhotoPage(asset: asset, onTap: onTap)
        }
    }
}

/// Shows the thumbnail at once, the ~1440 px preview when it arrives, and the full image after zooming in.
struct PhotoPage: View {
    let asset: AssetRef
    let onTap: () -> Void

    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @State private var wantsFullSize = false
    @AppStorage("viewer.fullSize") private var alwaysFullSize = false

    var body: some View {
        ZoomableImage(image: image ?? Still.cached(asset), onTap: onTap) { wantsFullSize = true }
            .task { image = await Still.load(asset.id, size: "preview", client: session.client) ?? image }
            .task(id: wantsFullSize || alwaysFullSize) {
                guard wantsFullSize || alwaysFullSize, let full = await Still.load(asset.id, size: "fullsize", client: session.client, cache: false) else { return }
                image = full
            }
    }
}

/// A Live Photo: the still at once, then the photo and its video, which play on touch and hold.
struct LivePage: View {
    let asset: AssetRef
    let isCurrent: Bool
    let onTap: () -> Void

    @Environment(Session.self) private var session
    @State private var livePhoto: PHLivePhoto?

    var body: some View {
        Group {
            if let livePhoto {
                LivePhotoView(livePhoto: livePhoto)
                    .onTapGesture(perform: onTap)
            } else {
                PhotoPage(asset: asset, onTap: onTap)
            }
        }
        .overlay(alignment: .topLeading) {
            Label("Live", systemImage: "livephoto")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)
                .padding()
                .padding(.top, 90)
        }
        .task(id: isCurrent) {
            guard isCurrent, livePhoto == nil, let client = session.client, let video = asset.livePhotoVideoId,
                  let photoFile = try? await client.downloadOriginal(asset.id),
                  let videoFile = try? await client.downloadOriginal(video) else { return }
            livePhoto = await Self.livePhoto([photoFile, videoFile])
        }
    }

    static func livePhoto(_ files: [URL]) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            var resumed = false
            PHLivePhoto.request(withResourceFileURLs: files, placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                // the first call may be a low-quality version; wait for the final one or an error
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true, !resumed else { return }
                resumed = true
                continuation.resume(returning: photo)
            }
        }
    }
}

/// A video with WoofTube's controls. It plays while it is the current page and pauses when paged away.
struct VideoPage: View {
    let asset: AssetRef
    let isCurrent: Bool
    @Binding var chromeHidden: Bool
    let onTap: () -> Void

    @Environment(Session.self) private var session
    @AppStorage("video.autoplay") private var autoplay = true
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let image = Still.cached(asset) {
                Image(uiImage: image).resizable().scaledToFit().onTapGesture(perform: onTap)
            }
            if let player {
                VideoSurface(player: player, chromeHidden: $chromeHidden, onTap: onTap)
            }
        }
        .task(id: isCurrent) {
            if isCurrent, let client = session.client {
                if player == nil { player = AVPlayer(playerItem: AVPlayerItem(asset: client.video(asset.id))) }
                if autoplay { player?.play() }
            } else {
                player?.pause()
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// A photo or video that is only on this iPhone, read from its Photos library.
struct DevicePage: View {
    let asset: AssetRef
    let isCurrent: Bool
    @Binding var chromeHidden: Bool
    let onTap: () -> Void

    @AppStorage("video.autoplay") private var autoplay = true
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoSurface(player: player, chromeHidden: $chromeHidden, onTap: onTap)
            } else {
                ZoomableImage(image: image ?? Still.cached(asset), onTap: onTap) {}
            }
        }
        .task {
            guard let localID = asset.localID else { return }
            image = await DeviceLibrary.image(localID, side: 2400)
        }
        .task(id: isCurrent) {
            guard !asset.isImage, let localID = asset.localID else { return }
            if isCurrent {
                if player == nil, let item = await DeviceLibrary.playerItem(localID) { player = AVPlayer(playerItem: item) }
                if autoplay { player?.play() }
            } else {
                player?.pause()
            }
        }
        .onDisappear { player?.pause() }
    }
}

extension EnvironmentValues {
    @Entry var viewerInset: CGFloat = 0
}

/// WoofTube's player controls on a plain AVPlayer: play/pause in the middle, a thin accent progress bar,
/// a gradient while visible, auto-hide while playing, double-tap a side to skip 10 seconds.
struct VideoSurface: View {
    let player: AVPlayer
    @Binding var chromeHidden: Bool
    let onTap: () -> Void

    @Environment(\.viewerInset) private var inset
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("video.loop") private var loops = false
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var playing = false
    @State private var muted = false
    /// 0…1 while a finger drags the progress bar.
    @State private var scrub: Double?
    @State private var skipHint: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PlayerLayer(player: player)
                if !chromeHidden {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                           .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.35), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(.rect)
            .gesture(SpatialTapGesture(count: 2)
                .onEnded { skip($0.location.x < geometry.size.width / 2 ? -10 : 10) }
                .exclusively(before: TapGesture().onEnded(onTap)))
            .overlay {
                if !chromeHidden {
                    Button { toggle() } label: {
                        Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .labelStyle(GlyphLabelStyle(size: 34))
                    .buttonStyle(GlyphPressStyle())
                    .transition(.opacity)
                }
            }
            .overlay(alignment: (skipHint ?? 0) < 0 ? .leading : .trailing) {
                if let skipHint {
                    Image(systemName: skipHint < 0 ? "gobackward.10" : "goforward.10")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .padding(48)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if !chromeHidden { controls.padding(.bottom, inset + 6).transition(.opacity) }
            }
        }
        .task {
            // ponytail: polls 4 times a second; switch to addPeriodicTimeObserver if it ever shows in Instruments
            while !Task.isCancelled {
                time = player.currentTime().seconds
                duration = player.currentItem?.duration.seconds.nonNaN ?? 0
                playing = player.rate != 0
                muted = player.isMuted
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .task(id: [chromeHidden, playing, scrub == nil]) {
            guard !chromeHidden, playing, scrub == nil, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { chromeHidden = true } }
        }
        .task(id: skipHint) {
            try? await Task.sleep(for: .seconds(0.6))
            if !Task.isCancelled { withAnimation { skipHint = nil } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem)) { _ in
            player.seek(to: .zero)
            if loops { player.play() } else { withAnimation { chromeHidden = false } }
        }
    }

    private var controls: some View {
        let shown = scrub.map { $0 * duration } ?? time
        return VStack(spacing: 0) {
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.tint).frame(width: bar.size.width * (duration > 0 ? min(shown / duration, 1) : 0))
                }
                .frame(height: scrub == nil ? 5 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { scrub = min(max($0.location.x / bar.size.width, 0), 1) }
                    .onEnded { _ in
                        if let scrub { player.seek(to: CMTime(seconds: scrub * duration, preferredTimescale: 600)) }
                        scrub = nil
                    })
            }
            .frame(height: 24)
            .animation(.easeOut(duration: 0.15), value: scrub == nil)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Self.format(time))
            .accessibilityAdjustableAction { skip($0 == .increment ? 10 : -10) }
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text(Self.format(duration))
                Button { player.isMuted.toggle(); muted = player.isMuted } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .labelStyle(GlyphLabelStyle(size: 15))
                .buttonStyle(GlyphPressStyle())
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .padding(.horizontal, Tokens.screenPadding)
    }

    private func toggle() {
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    private func skip(_ seconds: Double) {
        player.seek(to: CMTime(seconds: min(max(time + seconds, 0), duration), preferredTimescale: 600))
        withAnimation { skipHint = seconds }
    }

    static func format(_ seconds: Double) -> String {
        Duration.seconds(seconds.nonNaN ?? 0).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

private extension Double {
    var nonNaN: Double? { isFinite ? self : nil }
}

/// An AVPlayerLayer as a view, without the system's controls.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView { LayerView() }
    func updateUIView(_ view: LayerView, context: Context) { view.playerLayer.player = player }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Loads and caches the larger images the viewer shows.
enum Still {
    /// The best image already in memory: preview, then thumbnail, then the thumbhash.
    static func cached(_ asset: AssetRef) -> UIImage? {
        ImageCache.image(asset.id, size: "preview") ?? ImageCache.image(asset.id, size: "thumbnail")
            ?? asset.thumbhash.flatMap { ImageCache.placeholder(id: asset.id, hash: $0) }
    }

    static func load(_ id: String, size: String, client: ImmichClient?, cache: Bool = true) async -> UIImage? {
        if let image = ImageCache.image(id, size: size) { return image }
        guard let client, let data = try? await client.image(id, size: size), let image = UIImage(data: data) else { return nil }
        let ready = await image.byPreparingForDisplay() ?? image
        if cache { ImageCache.store(ready, for: id, size: size) }
        return ready
    }
}

// MARK: - Zoom and Live Text

/// Pinch and double-tap zoom, plus Live Text and Visual Look Up on the photo.
struct ZoomableImage: UIViewRepresentable {
    var image: UIImage?
    var onTap: () -> Void
    var onZoomIn: () -> Void

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.onTap = onTap
        view.onZoomIn = onZoomIn
        view.show(image)
    }
}

final class ZoomView: UIScrollView, UIScrollViewDelegate {
    var onTap: () -> Void = {}
    var onZoomIn: () -> Void = {}

    private let imageView = UIImageView()
    private let analysis = ImageAnalysisInteraction()
    private var analysisTask: Task<Void, Never>?
    private static let analyzer = ImageAnalyzer()

    init() {
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo"
        imageView.accessibilityTraits = .image
        imageView.addInteraction(analysis)
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        analysisTask?.cancel()
        guard let image, ImageAnalyzer.isSupported else { return }
        analysisTask = Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
            guard let result = try? await Self.analyzer.analyze(image, configuration: configuration), !Task.isCancelled else { return }
            self?.analysis.analysis = result
            self?.analysis.preferredInteractionTypes = .automatic
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale > 1.5 { onZoomIn() }
    }

    @objc private func singleTapped() { onTap() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
        zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        onZoomIn()
    }
}

// MARK: - Info

/// The pull-up panel: caption, date, camera, people and where the photo was taken, as cards.
struct InfoSheet: View {
    let id: String

    @Environment(Session.self) private var session
    @State private var asset: Asset?
    @State private var caption = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let asset {
                    if let date = asset.date {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide).day().month(.wide).year()))
                                .font(.title3.bold())
                            Text([date.formatted(Date.FormatStyle(timeZone: .gmt).hour().minute()), asset.originalFileName]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Add a Caption", text: $caption, axis: .vertical)
                        .onSubmit { Task { await saveCaption() } }
                        .card()
                    if let exif = asset.exifInfo, let latitude = exif.latitude, let longitude = exif.longitude {
                        place(exif, CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    }
                    if let exif = asset.exifInfo { camera(exif) }
                    if let people = asset.people, !people.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("People", systemImage: "person.2").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                            Text(people.map { $0.name.isEmpty ? "Unnamed" : $0.name }.joined(separator: ", "))
                        }
                        .card()
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Tokens.screenPadding)
            .padding(.top, 8)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { Task { await saveCaption() } }
        .task {
            do {
                asset = try await session.client?.asset(id)
                caption = asset?.exifInfo?.description ?? ""
            } catch {
                self.error = error.explanation
            }
        }
    }

    @ViewBuilder private func camera(_ exif: Exif) -> some View {
        let device = [exif.make, exif.model].compactMap { $0 }.joined(separator: " ")
        let settings = [
            exif.iso?.value.map { "ISO \($0)" },
            exif.focalLength.map { "\(Int($0.rounded())) mm" },
            exif.fNumber.map { "ƒ\($0.formatted(.number.precision(.fractionLength(0...1))))" },
            exif.exposureTime.map { "\($0) s" },
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 4) {
            Label(device.isEmpty ? "File" : device, systemImage: "camera")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            if let lens = exif.lensModel { Text(lens) }
            if !settings.isEmpty { Text(settings.joined(separator: " · ")).monospacedDigit() }
            if let width = exif.exifImageWidth?.value, let height = exif.exifImageHeight?.value {
                let megapixels = (Double(width * height) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))
                let size = exif.fileSizeInByte?.value.map { " · " + Int64($0).formatted(.byteCount(style: .file)) } ?? ""
                Text("\(width) × \(height) · \(megapixels) MP\(size)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .card()
    }

    private func place(_ exif: Exif, _ coordinate: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                Marker("", coordinate: coordinate)
            }
            .frame(height: 180)
            let name = [exif.city, exif.state, exif.country].compactMap { $0 }.joined(separator: ", ")
            if !name.isEmpty {
                Label(name, systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .padding(14)
            }
        }
        .background(Tokens.cardColor)
        .clipShape(.rect(cornerRadius: Tokens.cardRadius))
    }

    private func saveCaption() async {
        guard let asset, caption != (asset.exifInfo?.description ?? "") else { return }
        try? await session.client?.updateAssets([asset.id], ["description": caption])
        self.asset?.exifInfo?.description = caption
    }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.cardRadius))
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
