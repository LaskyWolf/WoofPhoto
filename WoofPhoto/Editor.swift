import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import PencilKit
import SwiftUI

/// The editor for photos and videos: Trim (videos), Adjust, Filters, Crop, Clean Up and Markup (photos), and Live for Live Photos.
/// On the server, crop, rotate and mirror alone on a photo are saved as Immich edits, which the server can undo;
/// anything else uploads as a new item stacked on top of the original, which stays in the stack.
/// On this iPhone the edit is saved into the Photos library, which keeps the original and can revert.
struct EditorView: View {
    enum Tool: String {
        case trim = "Trim", adjust = "Adjust", filters = "Filters", crop = "Crop", cleanUp = "Clean Up", markup = "Markup", live = "Live"

        var symbol: String {
            switch self {
            case .trim: "scissors"
            case .adjust: "slider.horizontal.3"
            case .filters: "camera.filters"
            case .crop: "crop.rotate"
            case .cleanUp: "eraser"
            case .markup: "pencil.tip.crop.circle"
            case .live: "livephoto"
            }
        }
    }

    /// Crop's three angles, one slider at a time, like Photos' dial.
    enum CropAngle: String, CaseIterable {
        case straighten = "Straighten", vertical = "Vertical", horizontal = "Horizontal"
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
    /// Clean Up's brush width in points.
    @State private var brush: CGFloat = 40
    /// The photo's pixels before each Clean Up stroke or Markup, for Undo.
    @State private var undo: [CIImage?] = []
    /// Markup's drawing, kept while switching away and back until Done or Cancel.
    @State private var canvas = PKCanvasView()
    /// Pixel states stepped back by Undo, for Redo; cleared by any new retouch.
    @State private var redo: [CIImage?] = []
    /// True while the finger holds the preview, which then shows the original.
    @State private var comparing = false
    /// Set for a photo on this iPhone that Photos can revert.
    @State private var hasDeviceEdits = false
    @State private var canPaste = EditRecipe.saved != nil
    @State private var cropAngle = CropAngle.straighten
    /// Each filter applied to a small copy of the photo, for the Filters strip. Keyed by the filter's name, "" for Original.
    @State private var filterThumbs: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if tool == .cleanUp, let source {
                    // the photo without the other edits, so a stroke lands on the pixels it covers
                    CleanUpCanvas(image: edit.base(source), brush: brush) { retouch($0) }
                        .frame(maxHeight: .infinity)
                } else if tool == .markup, let source {
                    MarkupCanvas(image: edit.base(source), canvas: canvas)
                        .frame(maxHeight: .infinity)
                        // ponytail: room for PencilKit's tool picker, about this tall on iPhone; read its frame if it covers the photo
                        .padding(.bottom, 90)
                } else {
                    ZStack {
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if comparing {
                            Text("Original")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: .capsule)
                        }
                    }
                    .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 50) {
                    } onPressingChanged: { pressing in
                        // touch and hold shows the original, as in Photos
                        comparing = pressing
                        Task { await render(original: pressing) }
                    }
                    .accessibilityHint("Touch and hold to compare with the original")
                }
                // Markup's tool picker takes the bottom, as in Photos; its own Cancel and Done lead back
                if tool != .markup {
                    Text(tool.rawValue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.yellow)
                    controls
                    modeBar
                }
            }
            .padding(.bottom, 4)
            .background(.black)
            .foregroundStyle(.white)
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .toolbar {
                if tool == .markup { markupToolbar } else { editorToolbar }
            }
            .messageAlert($error)
        }
        .task { await load() }
        .task(id: edit) { await render(original: false) }
        .task(id: source == nil) { await makeFilterThumbs() }
        .task(id: framePosition) { await showFrame(at: framePosition) }
    }

    @ToolbarContentBuilder private var markupToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
                canvas.drawing = PKDrawing()
                tool = .adjust
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", role: .confirm) {
                if let source, let marked = MarkupCanvas.flatten(canvas, onto: edit.base(source)) { retouch(marked) }
                canvas.drawing = PKDrawing()
                tool = .adjust
            }
        }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }
        }
        // Photos' centre of the bar: Undo and Redo once there is something to step through, and the Auto wand on Adjust
        ToolbarItem(placement: .principal) {
            HStack(spacing: 18) {
                if !undo.isEmpty || !redo.isEmpty {
                    Button("Undo", systemImage: "arrow.uturn.backward") { stepBack() }.disabled(undo.isEmpty)
                    Button("Redo", systemImage: "arrow.uturn.forward") { stepForward() }.disabled(redo.isEmpty)
                }
                if tool == .adjust {
                    Button("Auto", systemImage: "wand.and.stars") {
                        if let source { applyAuto(edit.base(source)) }
                    }
                    .accessibilityHint("Sets exposure, black point, contrast and saturation from the photo")
                }
            }
            .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("Edit Options", systemImage: "ellipsis.circle") {
                Button("Copy Edits", systemImage: "doc.on.doc") {
                    EditRecipe(edit).save()
                    canPaste = true
                }
                .disabled(edit.values.isEmpty && edit.filter == nil)
                Button("Paste Edits", systemImage: "doc.on.clipboard") {
                    EditRecipe.saved?.apply(to: &edit)
                }
                .disabled(!canPaste)
                if hasServerEdits || hasDeviceEdits {
                    Button("Revert to Original", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                        Task { await revert() }
                    }
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", role: .confirm) { Task { await save() } }
                .tint(.yellow)
                .disabled(!changed || busy)
        }
    }

    /// Photos' bottom row: one round icon per tool, the chosen one in yellow.
    private var modeBar: some View {
        HStack(spacing: 0) {
            ForEach(tools, id: \.self) { item in
                Button { tool = item } label: {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(tool == item ? Color.yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(tool == item ? Color.white.opacity(0.18) : .clear, in: .circle)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tool == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
    }

    /// How far a slider is from neutral, 0…1, for the ring around its icon.
    private func amount(_ item: PhotoEdit.Slider) -> Double {
        let span = max(item.range.upperBound - item.neutral, item.neutral - item.range.lowerBound)
        return span == 0 ? 0 : min(1, abs(edit[item] - item.neutral) / span)
    }

    /// A round dial: the slider's icon, and a yellow ring that fills as the value moves away from neutral.
    private func dial(_ item: PhotoEdit.Slider) -> some View {
        Button { slider = item } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: amount(item))
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: item.symbol)
                    .font(.body)
                    .foregroundStyle(slider == item ? Color.yellow : .white)
            }
            .frame(width: 46, height: 46)
            .background(slider == item ? Color.white.opacity(0.14) : .clear, in: .circle)
        }
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(edit[item] == item.neutral ? "Not changed" : "Changed")
    }

    /// The slider's position as a signed number, like Photos: 0 at neutral, up to ±100.
    private func valueText(_ item: PhotoEdit.Slider) -> String {
        let span = max(item.range.upperBound - item.neutral, item.neutral - item.range.lowerBound)
        let value = span == 0 ? 0 : Int(((edit[item] - item.neutral) / span * 100).rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }

    /// The Filters strip's thumbnails: the photo, small, with each filter.
    private func makeFilterThumbs() async {
        guard let source else { return }
        let base = edit.base(source)
        let scale = min(1, 160 / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var thumbs: [String: UIImage] = [:]
        for filter in PhotoEdit.filters {
            var look = PhotoEdit()
            look.filter = filter.name
            let image = small.applying(look, scale: scale)
            if let cgImage = PhotoEdit.context.createCGImage(image, from: small.extent) { thumbs[filter.name ?? ""] = UIImage(cgImage: cgImage) }
        }
        filterThumbs = thumbs
    }

    private var changed: Bool { edit != PhotoEdit() || trim != 0...1 || muted }

    private var tools: [Tool] {
        if !asset.isImage { return [.trim, .adjust, .filters, .crop] }
        let photo: [Tool] = [.adjust, .filters, .crop, .cleanUp, .markup]
        return asset.livePhotoVideoId == nil || asset.localID != nil ? photo : photo + [.live]
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
            VStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(PhotoEdit.Slider.allCases, id: \.self) { dial($0) }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                VStack(spacing: 2) {
                    HStack {
                        Text(slider.rawValue).font(.subheadline.weight(.semibold))
                        Text(valueText(slider)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if edit[slider] != slider.neutral {
                            Button("Reset") { edit[slider] = slider.neutral }.font(.caption.weight(.semibold)).tint(.yellow)
                        }
                    }
                    Slider(value: Binding { edit[slider] } set: { edit[slider] = $0 }, in: slider.range)
                        .tint(.yellow)
                        .accessibilityLabel(slider.rawValue)
                }
                .padding(.horizontal)
            }
        case .filters:
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(PhotoEdit.filters, id: \.title) { filter in
                        let chosen = edit.filter == filter.name
                        Button { edit.filter = filter.name } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if let thumb = filterThumbs[filter.name ?? ""] {
                                        Image(uiImage: thumb).resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.12)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.yellow : .clear, lineWidth: 2) }
                                Text(filter.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(chosen ? Color.yellow : .white.opacity(0.8))
                            }
                        }
                        .accessibilityLabel(filter.title)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        case .crop:
            VStack(spacing: 12) {
                HStack(spacing: 22) {
                    Button("Rotate", systemImage: "rotate.left") { edit.quarterTurns = (edit.quarterTurns + 3) % 4 }
                    Button("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { edit.mirrored.toggle() }
                    Menu {
                        Picker("Aspect", selection: $edit.aspect) {
                            ForEach(PhotoEdit.Aspect.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    } label: {
                        Label(edit.aspect.rawValue, systemImage: "aspectratio")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(.white.opacity(0.15), in: .capsule)
                    }
                    .accessibilityLabel("Aspect Ratio")
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                Picker("Angle", selection: $cropAngle) {
                    ForEach(CropAngle.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                HStack {
                    switch cropAngle {
                    case .straighten:
                        Slider(value: $edit.straighten, in: -45...45, step: 0.5).tint(.yellow)
                        Text("\(edit.straighten, specifier: "%.1f")°").font(.caption.monospacedDigit()).frame(width: 48)
                    case .vertical:
                        Slider(value: $edit.perspectiveV, in: -1...1).tint(.yellow).accessibilityLabel("Vertical Perspective")
                        Text("\(Int((edit.perspectiveV * 100).rounded()))").font(.caption.monospacedDigit()).frame(width: 48)
                    case .horizontal:
                        Slider(value: $edit.perspectiveH, in: -1...1).tint(.yellow).accessibilityLabel("Horizontal Perspective")
                        Text("\(Int((edit.perspectiveH * 100).rounded()))").font(.caption.monospacedDigit()).frame(width: 48)
                    }
                }
                .padding(.horizontal)
            }
        case .cleanUp:
            VStack {
                Text("Brush over something to remove it.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "circle.fill").font(.caption2)
                    Slider(value: $brush, in: 16...100)
                        .accessibilityLabel("Brush Size")
                    Image(systemName: "circle.fill").font(.title3)
                    undoButton
                }
            }
            .padding(.horizontal)
        case .markup:
            EmptyView()
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

    private var undoButton: some View {
        Button("Undo", systemImage: "arrow.uturn.backward") { stepBack() }
            .labelStyle(.iconOnly)
            .font(.title3)
            .disabled(undo.isEmpty)
    }

    /// A Clean Up stroke or a Markup drawing replaces the photo's pixels; Undo steps back one.
    private func retouch(_ image: CIImage) {
        undo.append(edit.keyFrame ?? edit.retouched)
        redo = []
        setPixels(image)
    }

    private func stepBack() {
        guard let pixels = undo.popLast() else { return }
        redo.append(edit.keyFrame ?? edit.retouched)
        setPixels(pixels)
    }

    private func stepForward() {
        guard let pixels = redo.popLast() else { return }
        undo.append(edit.keyFrame ?? edit.retouched)
        setPixels(pixels)
    }

    /// Auto: exposure, black point, contrast and saturation chosen from the photo's tones.
    private func applyAuto(_ image: CIImage) {
        let found = Self.autoValues(image)
        for slider in [PhotoEdit.Slider.exposure, .blackPoint, .contrast, .saturation] {
            edit[slider] = found[slider] ?? slider.neutral
        }
    }

    /// Reads a 64-pixel copy: mean brightness sets exposure, the darkest 1% sets the black point,
    /// a narrow tonal spread adds contrast and dull colours add saturation.
    private static func autoValues(_ image: CIImage) -> [PhotoEdit.Slider: Double] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [:] }
        let scale = 64 / max(extent.width, extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return [:] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        PhotoEdit.context.render(small, toBitmap: &pixels, rowBytes: width * 4, bounds: rect, format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var lumas: [Double] = []
        var saturation = 0.0
        for index in 0..<(width * height) {
            let r = Double(pixels[index * 4]) / 255, g = Double(pixels[index * 4 + 1]) / 255, b = Double(pixels[index * 4 + 2]) / 255
            lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
            let top = max(r, g, b)
            if top > 0 { saturation += (top - min(r, g, b)) / top }
        }
        lumas.sort()
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let low = lumas[lumas.count / 100], high = lumas[lumas.count * 99 / 100]
        saturation /= Double(lumas.count)
        var result: [PhotoEdit.Slider: Double] = [:]
        result[.exposure] = min(max(log2(0.45 / max(mean, 0.02)) * 0.6, -1), 1)
        result[.blackPoint] = min(max(low * 0.8, 0), 0.2)
        result[.contrast] = 1 + min(max(0.8 - (high - low), 0) * 0.5, 0.3)
        result[.saturation] = saturation < 0.35 ? 1.15 : 1.05
        return result
    }

    /// A picked key photo stays the key photo, so saving still replaces the Live Photo's still.
    private func setPixels(_ image: CIImage?) {
        if edit.keyFrame != nil { edit.keyFrame = image } else { edit.retouched = image }
    }

    // MARK: Loading and rendering

    private func load() async {
        do {
            if let localID = asset.localID {
                guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
                      let input = await Self.editingInput(phAsset) else { throw EditError.load }
                self.input = input
                hasDeviceEdits = PHAssetResource.assetResources(for: phAsset).contains { $0.type == .adjustmentData }
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
        let base = original ? source : edit.base(source)
        let scale = min(1, 1600 / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = original ? small : small.applying(edit, scale: scale)
        guard let cgImage = PhotoEdit.context.createCGImage(image, from: image.extent) else { return }
        preview = UIImage(cgImage: cgImage)
    }

    private func chooseKeyFrame(_ motion: AVURLAsset) async {
        guard let frame = await Self.frame(motion, at: keyFrame, side: nil) else { return }
        edit.keyFrame = CIImage(cgImage: frame)
        // the strokes were on the old still
        undo = []
        redo = []
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
            try jpeg(edit.base(source).applying(edit, scale: 1)).write(to: output.renderedContentURL)
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
        try jpeg(edit.base(source).applying(edit, scale: 1)).write(to: file)
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
        busy = true
        defer { busy = false }
        do {
            if input != nil {
                // Photos keeps the original of an edited item and puts it back
                guard let localID = asset.localID,
                      let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { throw EditError.load }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: phAsset).revertAssetContentToOriginal()
                }
                onSaved()
                dismiss()
                return
            }
            guard let client = session.client else { return }
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
        case exposure = "Exposure", brilliance = "Brilliance", highlights = "Highlights", shadows = "Shadows", contrast = "Contrast"
        case brightness = "Brightness", blackPoint = "Black Point", saturation = "Saturation", vibrance = "Vibrance", warmth = "Warmth"
        case tint = "Tint", sharpness = "Sharpness", definition = "Definition", noiseReduction = "Noise Reduction", vignette = "Vignette"

        var symbol: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .brilliance: "sparkle"
            case .blackPoint: "circle.fill"
            case .definition: "triangle.lefthalf.filled"
            case .noiseReduction: "waveform"
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
            case .blackPoint: -0.2...0.2
            case .sharpness, .definition, .noiseReduction, .vignette: 0...1
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
    /// Vertical and horizontal perspective, -1…1.
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    var aspect = Aspect.original
    var motionOff = false
    var keyFrame: CIImage?
    /// The photo after Clean Up and Markup, in place of the original's pixels.
    var retouched: CIImage?

    subscript(slider: Slider) -> Double {
        get { values[slider] ?? slider.neutral }
        set { values[slider] = newValue == slider.neutral ? nil : newValue }
    }

    static func == (a: PhotoEdit, b: PhotoEdit) -> Bool {
        a.values == b.values && a.filter == b.filter && a.quarterTurns == b.quarterTurns && a.mirrored == b.mirrored
            && a.straighten == b.straighten && a.perspectiveV == b.perspectiveV && a.perspectiveH == b.perspectiveH && a.aspect == b.aspect && a.motionOff == b.motionOff && a.keyFrame === b.keyFrame
            && a.retouched === b.retouched
    }

    /// The pixels the other settings apply to: a new key photo, else the retouched photo, else the original.
    func base(_ source: CIImage) -> CIImage { keyFrame ?? retouched ?? source }

    var withoutMotion: PhotoEdit {
        var copy = self
        copy.motionOff = false
        return copy
    }

    /// Only crop, rotate and mirror: Immich can store these without new pixels.
    var isGeometryOnly: Bool { values.isEmpty && filter == nil && straighten == 0 && perspectiveV == 0 && perspectiveH == 0 && keyFrame == nil && retouched == nil && !motionOff }

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
        if let level = edit.values[.noiseReduction] {
            // first, before the other steps stretch the noise
            let f = CIFilter.noiseReduction(); f.inputImage = image; f.noiseLevel = Float(level * 0.06); f.sharpness = 0.4
            image = f.outputImage ?? image
        }
        if let ev = edit.values[.exposure] {
            let f = CIFilter.exposureAdjust(); f.inputImage = image; f.ev = Float(ev); image = f.outputImage ?? image
        }
        if let black = edit.values[.blackPoint] {
            // out = (in - black) / (1 - black): a positive point darkens the shadows, a negative one lifts them
            let gain = CGFloat(1 / (1 - black)), bias = CGFloat(-black / (1 - black))
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            image = f.outputImage ?? image
        }
        if edit.values[.highlights] != nil || edit.values[.shadows] != nil || edit.values[.brilliance] != nil {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            // Brilliance opens the shadows and calms the highlights at once
            f.highlightAmount = Float(min(max(1 + edit[.highlights] - edit[.brilliance] * 0.3, 0), 1))
            f.shadowAmount = Float(min(max(edit[.shadows] + edit[.brilliance] * 0.5, -1), 1))
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
        if let amount = edit.values[.definition] {
            // local contrast: an unsharp mask with a wide radius, which is in pixels so it follows the preview's scale
            let f = CIFilter.unsharpMask(); f.inputImage = image; f.radius = Float(30 * scale); f.intensity = Float(amount * 0.8)
            image = f.outputImage ?? image
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
        if edit.perspectiveV != 0 || edit.perspectiveH != 0 {
            let e = image.extent
            let v = CGFloat(edit.perspectiveV), h = CGFloat(edit.perspectiveH)
            let top = max(v, 0) * e.width * 0.15, bottom = max(-v, 0) * e.width * 0.15
            let left = max(h, 0) * e.height * 0.15, right = max(-h, 0) * e.height * 0.15
            let f = CIFilter.perspectiveTransform()
            f.inputImage = image
            // Core Image's y runs upward
            f.topLeft = CGPoint(x: e.minX + top, y: e.maxY - left)
            f.topRight = CGPoint(x: e.maxX - top, y: e.maxY - right)
            f.bottomLeft = CGPoint(x: e.minX + bottom, y: e.minY + left)
            f.bottomRight = CGPoint(x: e.maxX - bottom, y: e.minY + right)
            // ponytail: this inset hides the empty corners for one axis; with both sliders far out a sliver may show
            image = (f.outputImage ?? image).cropped(to: e.insetBy(dx: max(top, bottom), dy: max(left, right)))
        }
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
