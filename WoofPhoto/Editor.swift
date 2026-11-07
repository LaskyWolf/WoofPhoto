import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import SwiftUI

/// The editor for photos and videos: Trim (videos), Adjust, Filters, Crop, and Live for Live Photos.
/// On the server, crop, rotate and mirror alone on a photo are saved as Immich edits, which the server can undo;
/// anything else uploads as a new item stacked on top of the original, which stays in the stack.
/// On this iPhone the edit is saved into the Photos library, which keeps the original and can revert.
struct EditorView: View {
    enum Tool: String {
        case trim = "Trim", adjust = "Adjust", filters = "Filters", crop = "Crop", live = "Live"
    }

    let asset: AssetRef
    var onSaved: () -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var tool = Tool.adjust
    @State private var edit = PhotoEdit()
    @State private var slider = PhotoEdit.Slider.exposure
    /// The photo, or the video frame being looked at.
    @State private var source: CIImage?
    @State private var preview: UIImage?
    @State private var hasServerEdits = false
    @State private var busy = false
    @State private var error: String?
    @State private var keyFrame = 0.0
    @State private var motion: AVURLAsset?
    /// Set for an item only on this iPhone.
    @State private var input: PHContentEditingInput?
    @State private var video: AVAsset?
    @State private var duration = 0.0
    @State private var frames: [UIImage] = []
    @State private var trim = 0.0...1.0
    @State private var framePosition = 0.0
    @State private var muted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)
                .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 50) {
                } onPressingChanged: { pressing in
                    // touch and hold shows the original, as in Photos
                    Task { await render(original: pressing) }
                }
                controls
                Picker("Tool", selection: $tool) {
                    ForEach(tools, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            .padding(.bottom)
            .background(.black)
            .foregroundStyle(.white)
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if hasServerEdits {
                        Button("Revert") { Task { await revert() } }.tint(.red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { Task { await save() } }
                        .disabled(!changed || busy)
                }
            }
            .messageAlert($error)
        }
        .task { await load() }
        .task(id: edit) { await render(original: false) }
        .task(id: framePosition) { await showFrame(at: framePosition) }
    }

    private var changed: Bool { edit != PhotoEdit() || trim != 0...1 || muted }

    private var tools: [Tool] {
        if !asset.isImage { return [.trim, .adjust, .filters, .crop] }
        return asset.livePhotoVideoId == nil || asset.localID != nil ? [.adjust, .filters, .crop] : [.adjust, .filters, .crop, .live]
    }

    @ViewBuilder private var controls: some View {
        switch tool {
        case .trim:
            VStack(spacing: 12) {
                TrimBar(frames: frames, range: $trim) { framePosition = $0 }
                HStack {
                    Text("\(VideoSurface.format(trim.lowerBound * duration)) – \(VideoSurface.format(trim.upperBound * duration))")
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    Toggle("Sound", isOn: Binding { !muted } set: { muted = !$0 })
                        .fixedSize()
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
        case .adjust:
            VStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(PhotoEdit.Slider.allCases, id: \.self) { item in
                            Button {
                                slider = item
                            } label: {
                                Image(systemName: item.symbol)
                                    .frame(width: 44, height: 44)
                                    .background(slider == item ? Color.white.opacity(0.25) : .clear, in: .circle)
                                    .overlay {
                                        if edit[item] != item.neutral { Circle().stroke(.yellow, lineWidth: 1.5) }
                                    }
                            }
                            .accessibilityLabel(item.rawValue)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                HStack {
                    Text(slider.rawValue).font(.subheadline)
                    Slider(value: Binding { edit[slider] } set: { edit[slider] = $0 }, in: slider.range)
                    Button("Reset") { edit[slider] = slider.neutral }.font(.caption)
                }
                .padding(.horizontal)
            }
        case .filters:
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(PhotoEdit.filters, id: \.name) { filter in
                        Button(filter.title) { edit.filter = filter.name }
                            .buttonStyle(.bordered)
                            .tint(edit.filter == filter.name ? .yellow : .white)
                    }
                }
                .padding(.horizontal)
            }
        case .crop:
            VStack {
                HStack(spacing: 20) {
                    Button("Rotate", systemImage: "rotate.left") { edit.quarterTurns = (edit.quarterTurns + 3) % 4 }
                    Button("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { edit.mirrored.toggle() }
                    Picker("Aspect", selection: $edit.aspect) {
                        ForEach(PhotoEdit.Aspect.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .tint(.white)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                HStack {
                    Text("Straighten").font(.subheadline)
                    Slider(value: $edit.straighten, in: -45...45, step: 0.5)
                    Text("\(edit.straighten, specifier: "%.1f")°").monospacedDigit().font(.caption)
                }
                .padding(.horizontal)
            }
        case .live:
            VStack {
                Toggle("Live", isOn: Binding { !edit.motionOff } set: { edit.motionOff = !$0 })
                if let motion, !edit.motionOff {
                    Text("Key Photo").font(.subheadline)
                    Slider(value: $keyFrame, in: 0...1, onEditingChanged: { editing in
                        if !editing { Task { await chooseKeyFrame(motion) } }
                    })
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Loading and rendering

    private func load() async {
        do {
            if let localID = asset.localID {
                guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
                      let input = await Self.editingInput(phAsset) else { throw EditError.load }
                self.input = input
                if asset.isImage {
                    source = input.fullSizeImageURL.flatMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) }
                } else {
                    video = input.audiovisualAsset
                }
            } else if let client = session.client {
                if asset.isImage {
                    let data = try await client.image(asset.id, size: "fullsize")
                    source = CIImage(data: data, options: [.applyOrientationProperty: true])
                    let edits: ServerEdits? = try? await client.get("/assets/\(asset.id)/edits")
                    hasServerEdits = edits?.edits.isEmpty == false
                    if let video = asset.livePhotoVideoId {
                        motion = AVURLAsset(url: try await client.downloadOriginal(video))
                    }
                } else {
                    video = AVURLAsset(url: try await client.downloadOriginal(asset.id))
                }
            }
            if let video {
                tool = .trim
                duration = try await video.load(.duration).seconds
                await showFrame(at: 0)
                var frames: [UIImage] = []
                for index in 0..<8 {
                    if let frame = await Self.frame(video, at: (Double(index) + 0.5) / 8, side: 160) { frames.append(UIImage(cgImage: frame)) }
                }
                self.frames = frames
            }
            if source == nil, video == nil { throw EditError.load }
            await render(original: false)
        } catch {
            self.error = error.explanation
        }
    }

    private static func editingInput(_ asset: PHAsset) async -> PHContentEditingInput? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in continuation.resume(returning: input) }
        }
    }

    /// One frame of a video, already turned upright; `side` nil keeps the full size.
    private static func frame(_ video: AVAsset, at fraction: Double, side: CGFloat?) async -> CGImage? {
        guard let duration = try? await video.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let side { generator.maximumSize = CGSize(width: side, height: side) }
        // the very last instant has no frame
        return try? await generator.image(at: CMTimeMultiplyByFloat64(duration, multiplier: min(fraction, 0.995))).image
    }

    private func showFrame(at fraction: Double) async {
        guard let video, let frame = await Self.frame(video, at: fraction, side: 1600), !Task.isCancelled else { return }
        source = CIImage(cgImage: frame)
        await render(original: false)
    }

    /// Renders a screen-sized preview of the edit.
    private func render(original: Bool) async {
        guard let source else { return }
        let base = original ? source : edit.keyFrame ?? source
        let scale = min(1, 1600 / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = original ? small : small.applying(edit, scale: scale)
        guard let cgImage = PhotoEdit.context.createCGImage(image, from: image.extent) else { return }
        preview = UIImage(cgImage: cgImage)
    }

    private func chooseKeyFrame(_ motion: AVURLAsset) async {
        guard let frame = await Self.frame(motion, at: keyFrame, side: nil) else { return }
        edit.keyFrame = CIImage(cgImage: frame)
    }

    // MARK: Saving

    private func save() async {
        busy = true
        defer { busy = false }
        // what History's undo removes: the new copy, the Immich edit, or the edit in Photos
        var editID: String?
        do {
            if let input {
                try await saveOnDevice(input)
                editID = "device"
            } else if let client = session.client {
                if let video {
                    let detail = try await client.asset(asset.id)
                    let name = ((detail.originalFileName ?? "Video") as NSString).deletingPathExtension + "_edited.mov"
                    let file = FileManager.default.temporaryDirectory.appending(path: name)
                    defer { try? FileManager.default.removeItem(at: file) }
                    try await export(video, to: file)
                    editID = try await stackNew(file, detail: detail, client: client)
                } else if edit.motionOff, edit.withoutMotion == PhotoEdit() {
                    try await client.call("PUT", "/assets/\(asset.id)", body: ["livePhotoVideoId": NSNull()])
                } else if edit.isGeometryOnly, let detail = try? await client.asset(asset.id),
                          let width = detail.exifInfo?.exifImageWidth?.value ?? detail.width?.value,
                          let height = detail.exifInfo?.exifImageHeight?.value ?? detail.height?.value {
                    try await client.call("PUT", "/assets/\(asset.id)/edits", body: ["edits": edit.serverEdits(width: width, height: height)])
                    editID = "edits"
                } else if let source {
                    editID = try await bake(source, client: client)
                }
                ImageCache.forget(asset.id, client: client)
            }
            History.shared.record(HistoryEntry(kind: .edited, assetID: asset.id, localID: asset.localID, editID: editID))
            onSaved()
            dismiss()
        } catch {
            self.error = error.explanation
        }
    }

    /// Saves the edit into the Photos library, which keeps the original so Photos can revert it.
    private func saveOnDevice(_ input: PHContentEditingInput) async throws {
        guard let localID = asset.localID,
              let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { throw EditError.load }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "app.woofphoto.edit", formatVersion: "1", data: Data("1".utf8))
        if let video {
            try await export(video, to: output.renderedContentURL)
        } else if let source {
            try jpeg(source.applying(edit, scale: 1)).write(to: output.renderedContentURL)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: phAsset).contentEditingOutput = output
        }
    }

    /// Writes the trimmed part of the video, without sound if muted, with the edit applied to every frame.
    private func export(_ video: AVAsset, to file: URL) async throws {
        let length = try await video.load(.duration)
        let range = CMTimeRange(start: CMTimeMultiplyByFloat64(length, multiplier: trim.lowerBound),
                                end: CMTimeMultiplyByFloat64(length, multiplier: trim.upperBound))
        let composition = AVMutableComposition()
        guard let source = try await video.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditError.render
        }
        try track.insertTimeRange(range, of: source, at: .zero)
        track.preferredTransform = try await source.load(.preferredTransform)
        if !muted {
            for audio in try await video.loadTracks(withMediaType: .audio) {
                try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                    .insertTimeRange(range, of: audio, at: .zero)
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw EditError.render }
        if edit != PhotoEdit() {
            let edit = edit
            // each frame arrives upright, so the photo pipeline applies as is
            let frames = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                request.finish(with: request.sourceImage.applying(edit, scale: 1), context: nil)
            }
            let size = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: frames.renderSize)).applying(edit, scale: 1).extent.size
            // video encoders want even sides
            frames.renderSize = CGSize(width: (size.width / 2).rounded(.down) * 2, height: (size.height / 2).rounded(.down) * 2)
            exporter.videoComposition = frames
        }
        try? FileManager.default.removeItem(at: file)
        try await exporter.export(to: file, as: .mov)
    }

    private func jpeg(_ image: CIImage) throws -> Data {
        guard let data = PhotoEdit.context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                               options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]) else {
            throw EditError.render
        }
        return data
    }

    /// Renders the full photo and stacks it on top of the original.
    private func bake(_ source: CIImage, client: ImmichClient) async throws -> String {
        let detail = try await client.asset(asset.id)
        let name = ((detail.originalFileName ?? "Photo") as NSString).deletingPathExtension + "_edited.jpg"
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        try jpeg((edit.keyFrame ?? source).applying(edit, scale: 1)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await stackNew(file, detail: detail, client: client, motion: edit.motionOff ? nil : asset.livePhotoVideoId)
        if edit.keyFrame != nil {
            // a new key photo replaces the old still; the video now belongs to the new one
            try await client.deleteAssets([asset.id])
        }
        return id
    }

    /// Uploads an edited file as a new item with the original's date, place, albums and favorite,
    /// stacked on top of the original.
    private func stackNew(_ file: URL, detail: Asset, client: ImmichClient, motion: String? = nil) async throws -> String {
        var fields = ["fileCreatedAt": detail.fileCreatedAt ?? Date.now.formatted(.iso8601),
                      "fileModifiedAt": Date.now.formatted(.iso8601)]
        if let motion { fields["livePhotoVideoId"] = motion }
        let id = try await client.upload(file, fields: fields)

        var place: [String: Any] = [:]
        if let date = detail.fileCreatedAt { place["dateTimeOriginal"] = date }
        if let latitude = detail.exifInfo?.latitude, let longitude = detail.exifInfo?.longitude {
            place["latitude"] = latitude
            place["longitude"] = longitude
        }
        if !place.isEmpty { try? await client.updateAssets([id], place) }
        try await client.call("PUT", "/assets/copy", body: ["sourceId": asset.id, "targetId": id, "albums": true, "favorite": true,
                                                            "sharedLinks": true, "stack": false, "sidecar": false])
        try await client.call("POST", "/stacks", body: ["assetIds": [id, asset.id]])
        return id
    }

    private func revert() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.call("DELETE", "/assets/\(asset.id)/edits")
            ImageCache.forget(asset.id, client: client)
            onSaved()
            dismiss()
        } catch {
            self.error = error.explanation
        }
    }

    enum EditError: LocalizedError {
        case load, render
        var errorDescription: String? {
            switch self {
            case .load: "This item couldn't be opened for editing."
            case .render: "The edited copy couldn't be created."
            }
        }
    }
}

private struct ServerEdits: Decodable {
    var edits: [Edit]
    struct Edit: Decodable { var action: String }
}

/// Every setting of one edit. Equatable, so the preview re-renders only when something changes.
struct PhotoEdit: Equatable {
    enum Slider: String, CaseIterable {
        case exposure = "Exposure", highlights = "Highlights", shadows = "Shadows", contrast = "Contrast"
        case brightness = "Brightness", saturation = "Saturation", vibrance = "Vibrance", warmth = "Warmth"
        case tint = "Tint", sharpness = "Sharpness", vignette = "Vignette"

        var symbol: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .highlights: "circle.lefthalf.filled.righthalf.striped.horizontal"
            case .shadows: "circle.righthalf.filled"
            case .contrast: "circle.lefthalf.filled"
            case .brightness: "sun.max"
            case .saturation: "drop.halffull"
            case .vibrance: "camera.filters"
            case .warmth: "thermometer.medium"
            case .tint: "eyedropper"
            case .sharpness: "triangle"
            case .vignette: "circle.dashed"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .exposure: -2...2
            case .highlights: -1...0
            case .contrast: 0.5...1.5
            case .saturation: 0...2
            case .brightness: -0.3...0.3
            case .sharpness, .vignette: 0...1
            default: -1...1
            }
        }

        var neutral: Double {
            switch self {
            case .contrast, .saturation: 1
            default: 0
            }
        }
    }

    enum Aspect: String, CaseIterable {
        case original = "Original", square = "Square", fourThree = "4:3", sixteenNine = "16:9"

        var ratio: CGFloat? {
            switch self {
            case .original: nil
            case .square: 1
            case .fourThree: 4 / 3
            case .sixteenNine: 16 / 9
            }
        }
    }

    static let filters: [(name: String?, title: String)] = [
        (nil, "Original"), ("CIPhotoEffectChrome", "Vivid"), ("CIPhotoEffectFade", "Fade"), ("CIPhotoEffectInstant", "Instant"),
        ("CIPhotoEffectProcess", "Cool"), ("CIPhotoEffectTransfer", "Warm"), ("CIPhotoEffectMono", "Mono"),
        ("CIPhotoEffectTonal", "Silvertone"), ("CIPhotoEffectNoir", "Noir"),
    ]

    static let context = CIContext()

    var values: [Slider: Double] = [:]
    var filter: String?
    var quarterTurns = 0
    var mirrored = false
    var straighten = 0.0
    var aspect = Aspect.original
    var motionOff = false
    var keyFrame: CIImage?

    subscript(slider: Slider) -> Double {
        get { values[slider] ?? slider.neutral }
        set { values[slider] = newValue == slider.neutral ? nil : newValue }
    }

    static func == (a: PhotoEdit, b: PhotoEdit) -> Bool {
        a.values == b.values && a.filter == b.filter && a.quarterTurns == b.quarterTurns && a.mirrored == b.mirrored
            && a.straighten == b.straighten && a.aspect == b.aspect && a.motionOff == b.motionOff && a.keyFrame === b.keyFrame
    }

    var withoutMotion: PhotoEdit {
        var copy = self
        copy.motionOff = false
        return copy
    }

    /// Only crop, rotate and mirror: Immich can store these without new pixels.
    var isGeometryOnly: Bool { values.isEmpty && filter == nil && straighten == 0 && keyFrame == nil && !motionOff }

    /// Immich edits, applied by the server in this order: crop on the original pixels, then rotate, then mirror.
    func serverEdits(width: Int, height: Int) -> [[String: Any]] {
        var edits: [[String: Any]] = []
        if let ratio = aspect.ratio {
            // after an odd number of quarter turns the long side swaps, so the crop uses the inverse ratio
            let target = quarterTurns % 2 == 1 ? 1 / ratio : ratio
            let rect = Self.centerCrop(CGSize(width: width, height: height), ratio: target)
            edits.append(["action": "crop", "parameters": ["x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)]])
        }
        if quarterTurns != 0 { edits.append(["action": "rotate", "parameters": ["angle": (4 - quarterTurns) % 4 * 90]]) }
        if mirrored { edits.append(["action": "mirror", "parameters": ["axis": "horizontal"]]) }
        return edits
    }

    static func centerCrop(_ size: CGSize, ratio: CGFloat) -> CGRect {
        let width = min(size.width, size.height * ratio)
        let height = width / ratio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

extension CIImage {
    /// The image with every setting of the edit. `scale` shrinks distance-based effects for a smaller preview.
    func applying(_ edit: PhotoEdit, scale: CGFloat) -> CIImage {
        var image = self
        if let ev = edit.values[.exposure] {
            let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(ev); image = f.outputImage ?? image
        }
        if edit.values[.highlights] != nil || edit.values[.shadows] != nil {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + edit[.highlights])
            f.shadowAmount = Float(edit[.shadows])
            image = f.outputImage ?? image
        }
        if edit.values[.contrast] != nil || edit.values[.brightness] != nil || edit.values[.saturation] != nil {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(edit[.contrast])
            f.brightness = Float(edit[.brightness])
            f.saturation = Float(edit[.saturation])
            image = f.outputImage ?? image
        }
        if let amount = edit.values[.vibrance] {
            let f = CIFilter.vibrance(); f.inputImage = image; f.amount = Float(amount); image = f.outputImage ?? image
        }
        if edit.values[.warmth] != nil || edit.values[.tint] != nil {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - edit[.warmth] * 2500, y: edit[.tint] * 100)
            image = f.outputImage ?? image
        }
        if let sharpness = edit.values[.sharpness] {
            let f = CIFilter.sharpenLuminance(); f.inputImage = image; f.sharpness = Float(sharpness); image = f.outputImage ?? image
        }
        if let name = edit.filter, let f = CIFilter(name: name) {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }
        if let intensity = edit.values[.vignette] {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(intensity * 2)
            f.radius = 1.5
            image = f.outputImage ?? image
        }
        let extent = image.extent
        image = image.cropped(to: extent)
        if edit.straighten != 0 {
            let f = CIFilter.straighten(); f.inputImage = image; f.angle = Float(-edit.straighten * .pi / 180)
            image = (f.outputImage ?? image).cropped(to: extent)
        }
        let orientations: [CGImagePropertyOrientation] = edit.mirrored ? [.upMirrored, .leftMirrored, .downMirrored, .rightMirrored] : [.up, .left, .down, .right]
        image = image.oriented(orientations[edit.quarterTurns % 4])
        if let ratio = edit.aspect.ratio {
            image = image.cropped(to: PhotoEdit.centerCrop(image.extent.size, ratio: ratio).offsetBy(dx: image.extent.minX, dy: image.extent.minY))
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

/// A strip of video frames with a yellow frame around the part that is kept. Drag near an end to move it.
struct TrimBar: View {
    let frames: [UIImage]
    @Binding var range: ClosedRange<Double>
    /// Where the finger is, 0…1, to preview that frame.
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(uiImage: frames[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: width / CGFloat(frames.count), height: 48)
                            .clipped()
                    }
                }
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * range.lowerBound)
                Rectangle().fill(.black.opacity(0.6)).frame(width: width * (1 - range.upperBound)).offset(x: width * range.upperBound)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: width * (range.upperBound - range.lowerBound))
                    .offset(x: width * range.lowerBound)
            }
            .frame(height: 48)
            .background(.white.opacity(0.1))
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let x = min(max(value.location.x / width, 0), 1)
                let start = value.startLocation.x / width
                if abs(start - range.lowerBound) < abs(start - range.upperBound) {
                    range = min(x, range.upperBound - 0.02)...range.upperBound
                } else {
                    range = range.lowerBound...max(x, range.lowerBound + 0.02)
                }
                onScrub(x)
            })
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel("Trim")
        .accessibilityValue("\(Int(range.lowerBound * 100))% to \(Int(range.upperBound * 100))%")
    }
}
