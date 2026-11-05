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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showsInfo = false
    @State private var confirmsDelete = false
    @State private var sharing: SharedFile?
    @State private var busy = false
    @State private var message: String?
    @State private var addsToAlbum = false
    @State private var playsSlideshow = false
    @State private var editing: AssetRef?
    @State private var trimming: SharedFile?

    init(timeline: Timeline, start: AssetRef) {
        self.timeline = timeline
        _current = State(initialValue: start.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(timeline.assets) { asset in
                        ViewerPage(asset: shown(asset), isCurrent: asset.id == current) {
                            if !voiceOver { withAnimation { chromeHidden.toggle() } }
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
            // always black, like WoofMusic's player, so the photo's own colours lead
            .background(Color.black)
            .navigationTitle(detail?.date?.formatted(Date.FormatStyle(timeZone: .gmt).day().month(.wide).year()) ?? "")
            .navigationSubtitle([detail?.date?.formatted(Date.FormatStyle(timeZone: .gmt).hour().minute()), detail?.exifInfo?.city]
                .compactMap { $0 }.joined(separator: " · "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(chromeHidden)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    cameraChips
                    stackStrip
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .task(id: current) {
                if let asset = timeline.assets.first(where: { $0.id == current }) { OpenPhoto.shared.asset = asset }
                await currentChanged()
            }
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                OpenPhoto.shared.zoomedIn()
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
            .fullScreenCover(item: $editing) { asset in
                EditorView(asset: asset) { editSaved() }
            }
            .sheet(item: $trimming) { file in
                VideoTrimmer(file: file.url) { trimmed in
                    trimming = nil
                    if let trimmed { Task { await saveTrim(trimmed) } }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $addsToAlbum) {
                AlbumPicker(assets: [shownID].compactMap { $0 }) { message = "Added to \($0)." }
            }
            .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {}
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Parts

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close", systemImage: "xmark") { OpenPhoto.shared.close() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                if shownAsset?.localID == nil, timeline.query?.isTrash != true {
                    Button("Edit", systemImage: "slider.horizontal.3") { Task { await startEdit() } }
                }
                Button("Copy", systemImage: "doc.on.doc") { Task { await copy() } }
                Button("Save to iPhone", systemImage: "square.and.arrow.down") { Task { await save() } }
                Button("Add to Album…", systemImage: "rectangle.stack.badge.plus") { addsToAlbum = true }
                Button("Slideshow", systemImage: "play.rectangle") { playsSlideshow = true }
                if let album = timeline.query?.albumID {
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
                Divider()
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
        }
        if shownAsset?.localID != nil {
            ToolbarItemGroup(placement: .bottomBar) {
                Label("Not backed up", systemImage: "icloud.slash").labelStyle(.titleAndIcon)
                Spacer()
                Button("Back Up Now") { if let client = session.client { Backup.shared.start(with: client) } }
            }
        } else if timeline.query?.isTrash == true {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                Spacer()
                Button("Recover") {
                    Task { await perform {
                        try await session.client?.restoreTrash([shownID ?? ""])
                        removeCurrent()
                    } }
                }
            }
        } else {
            bottomBar
        }
    }

    @ToolbarContentBuilder private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") { Task { await share() } }
            Spacer()
            let favorite = shownAsset?.isFavorite == true
            Button {
                Task { await toggleFavorite() }
            } label: {
                Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                    .foregroundStyle(favorite ? AnyShapeStyle(.pink) : AnyShapeStyle(.primary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .sensoryFeedback(.impact(weight: .light), trigger: favorite)
            Spacer()
            Button("Info", systemImage: "info.circle") { showsInfo = true }
            Spacer()
            Button("Delete", systemImage: "trash") { confirmsDelete = true }
        }
    }

    /// The camera, lens and exposure as small chips above the buttons; hidden with the buttons.
    @ViewBuilder private var cameraChips: some View {
        if !chromeHidden, let exif = detail?.exifInfo {
            let chips = [
                exif.model ?? exif.make,
                exif.focalLength.map { "\(Int($0.rounded())) mm" },
                exif.fNumber.map { "ƒ\($0.formatted(.number.precision(.fractionLength(0...1))))" },
                exif.exposureTime.map { "\($0) s" },
                exif.iso?.value.map { "ISO \($0)" },
            ].compactMap { $0 }
            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { text in
                            Text(text)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                    .padding(.horizontal, Tokens.screenPadding)
                }
                .scrollIndicators(.hidden)
                .onTapGesture { showsInfo = true }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows the photo's details")
                .transition(.opacity)
            }
        }
    }

    /// Thumbnails of a stack's members (a burst, or RAW + JPEG); tap one to show it.
    @ViewBuilder private var stackStrip: some View {
        if let stack, stack.assets.count > 1, !chromeHidden {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(stack.assets) { member in
                        Thumbnail(asset: member.ref)
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 4))
                            .overlay {
                                if member.id == shownID { RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2) }
                            }
                            .onTapGesture {
                                if let current { shownInStack[current] = member.id }
                            }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 52)
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

    private func startEdit() async {
        guard let asset = shownAsset, let client = session.client else { return }
        if asset.isImage {
            editing = asset
        } else {
            await perform {
                let url = try await client.downloadOriginal(asset.id)
                trimming = SharedFile(url: url)
            }
        }
    }

    /// The trimmed video uploads as a new item with the original's date, albums and favorite, stacked on top of it.
    private func saveTrim(_ file: URL) async {
        guard let id = shownID, let client = session.client else { return }
        await perform {
            let detail = try await client.asset(id)
            let new = try await client.upload(file, fields: ["fileCreatedAt": detail.fileCreatedAt ?? Date.now.formatted(.iso8601),
                                                             "fileModifiedAt": Date.now.formatted(.iso8601)])
            try await client.call("PUT", "/assets/copy", body: ["sourceId": id, "targetId": new, "albums": true, "favorite": true,
                                                                "sharedLinks": true, "stack": false, "sidecar": false])
            try await client.call("POST", "/stacks", body: ["assetIds": [new, id]])
            editSaved()
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
    let onTap: () -> Void

    var body: some View {
        if asset.localID != nil {
            DevicePage(asset: asset, isCurrent: isCurrent, onTap: onTap)
        } else if !asset.isImage {
            VideoPage(asset: asset, isCurrent: isCurrent)
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

    var body: some View {
        ZoomableImage(image: image ?? Still.cached(asset), onTap: onTap) { wantsFullSize = true }
            .task { image = await Still.load(asset.id, size: "preview", client: session.client) ?? image }
            .task(id: wantsFullSize) {
                guard wantsFullSize, let full = await Still.load(asset.id, size: "fullsize", client: session.client, cache: false) else { return }
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

/// A video with the system controls. It plays while it is the current page and pauses when paged away.
struct VideoPage: View {
    let asset: AssetRef
    let isCurrent: Bool

    @Environment(Session.self) private var session
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let image = Still.cached(asset) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            if let player {
                VideoPlayer(player: player)
            }
        }
        .task(id: isCurrent) {
            if isCurrent, let client = session.client {
                if player == nil { player = AVPlayer(playerItem: AVPlayerItem(asset: client.video(asset.id))) }
                player?.play()
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
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
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
                player?.play()
            } else {
                player?.pause()
            }
        }
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

/// Date, camera, people and place for one asset, with an editable caption.
struct InfoSheet: View {
    let id: String

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var asset: Asset?
    @State private var caption = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let asset {
                    Section {
                        TextField("Add a Caption", text: $caption, axis: .vertical)
                    }
                    Section {
                        if let date = asset.date {
                            LabeledContent("Date", value: date.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: .gmt)))
                        }
                        if let name = asset.originalFileName { LabeledContent("File", value: name) }
                    }
                    if let exif = asset.exifInfo { camera(exif) }
                    if let people = asset.people, !people.isEmpty {
                        Section("People") {
                            ForEach(people) { Text($0.name.isEmpty ? "Unnamed" : $0.name) }
                        }
                    }
                    if let exif = asset.exifInfo, let latitude = exif.latitude, let longitude = exif.longitude {
                        place(exif, CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    }
                } else if let error {
                    Text(error)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done", role: .close) {
                    Task {
                        await saveCaption()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            do {
                asset = try await session.client?.asset(id)
                caption = asset?.exifInfo?.description ?? ""
            } catch {
                self.error = error.explanation
            }
        }
    }

    private func camera(_ exif: Exif) -> some View {
        Section("Camera") {
            let device = [exif.make, exif.model].compactMap { $0 }.joined(separator: " ")
            if !device.isEmpty { Text(device) }
            if let lens = exif.lensModel { Text(lens).foregroundStyle(.secondary) }
            let settings = [
                exif.iso?.value.map { "ISO \($0)" },
                exif.focalLength.map { "\(Int($0.rounded())) mm" },
                exif.fNumber.map { "ƒ\($0.formatted(.number.precision(.fractionLength(0...1))))" },
                exif.exposureTime.map { "\($0) s" },
            ].compactMap { $0 }
            if !settings.isEmpty { Text(settings.joined(separator: " · ")).monospacedDigit() }
            if let width = exif.exifImageWidth?.value, let height = exif.exifImageHeight?.value {
                let megapixels = (Double(width * height) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)))
                let size = exif.fileSizeInByte?.value.map { " · " + Int64($0).formatted(.byteCount(style: .file)) } ?? ""
                Text("\(width) × \(height) · \(megapixels) MP\(size)").foregroundStyle(.secondary)
            }
        }
    }

    private func place(_ exif: Exif, _ coordinate: CLLocationCoordinate2D) -> some View {
        Section("Place") {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                Marker("", coordinate: coordinate)
            }
            .frame(height: 200)
            .listRowInsets(EdgeInsets())
            let name = [exif.city, exif.state, exif.country].compactMap { $0 }.joined(separator: ", ")
            if !name.isEmpty { Text(name) }
        }
    }

    private func saveCaption() async {
        guard let asset, caption != (asset.exifInfo?.description ?? "") else { return }
        try? await session.client?.updateAssets([asset.id], ["description": caption])
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
