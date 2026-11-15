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

    /// Crop's two angles, one slider at a time: turning the picture level, and tilting it up or down.
    enum CropAngle: String, CaseIterable {
        case straighten = "Straighten", vertical = "Vertical"
    }

    /// Markup's pens, as the buttons in its controls.
    enum Ink: String, CaseIterable {
        case pen = "Pen", marker = "Marker", pencil = "Pencil", eraser = "Eraser"

        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .marker: "highlighter"
            case .pencil: "pencil"
            case .eraser: "eraser"
            }
        }
    }

    let asset: AssetRef
    var onSaved: () -> Void

    /// The controls keep one height for every tool, so the photo above doesn't jump when the tool changes.
    private static let controlsHeight: CGFloat = 176
    /// Room around the picture in Crop, so a corner handle can be grabbed at the very corner.
    private static let cropInset: CGFloat = 24

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
    @State private var cropAspect = PhotoEdit.Aspect.free
    /// A locked ratio turned the other way: 3:4 instead of 4:3.
    @State private var cropFlipped = false
    /// True once the preview shows the whole picture, so the crop frame doesn't sit on a cropped one.
    @State private var previewUncropped = false
    @State private var confirmsCancel = false
    /// The straighten angle when two fingers started turning the photo.
    @State private var twistStart: Double?
    @State private var ink = Ink.pen
    @State private var inkColor = Color.yellow
    @State private var inkWidth = 8.0
    /// Each filter applied to a small copy of the photo, for the Filters strip. Keyed by the filter's name, "" for Original.
    @State private var filterThumbs: [String: UIImage] = [:]
    /// The photo without the other edits, for Clean Up and Markup, whose strokes land on its own pixels.
    @State private var baseDisplay: UIImage?
    /// The stage's zoom, so Clean Up's brush keeps its size on screen.
    @State private var stageZoom: CGFloat = 1
    @State private var cleanStatus: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvasArea
                    .frame(maxHeight: .infinity)
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(tool.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.yellow)
                        if tool == .crop, edit.crop != PhotoEdit.unit || edit.straighten != 0 || edit.perspectiveV != 0 || edit.perspectiveH != 0 {
                            Button("Reset") {
                                edit.crop = PhotoEdit.unit
                                edit.straighten = 0
                                edit.perspectiveV = 0
                                edit.perspectiveH = 0
                                cropAspect = .free
                                cropFlipped = false
                            }
                                .font(.footnote.weight(.semibold))
                                .tint(.yellow)
                        }
                    }
                    controls
                }
                .padding(.top, 8)
                .frame(height: Self.controlsHeight, alignment: .top)
                bottomRow
            }
            .padding(.bottom, 4)
            .background(.black)
            .foregroundStyle(.white)
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .toolbar { editorToolbar }
            .messageAlert($error)
            .confirmationDialog("Discard your edits?", isPresented: $confirmsCancel, titleVisibility: .visible) {
                Button("Discard Edits", role: .destructive) { dismiss() }
            }
        }
        .sensoryFeedback(.selection, trigger: tool)
        .sensoryFeedback(.selection, trigger: edit.filter)
        .sensoryFeedback(.selection, trigger: slider)
        .sensoryFeedback(trigger: edit.straighten == 0) { _, level in level ? .impact(weight: .light) : nil }
        // the detent: a slider coming back to its neutral value
        .sensoryFeedback(trigger: edit[slider] == slider.neutral) { _, atZero in atZero ? .impact(weight: .light) : nil }
        .onChange(of: tool) { old, new in
            // Markup's strokes join the photo when you leave it
            if old == .markup { commitMarkup() }
            if new == .markup { applyInk() }
        }
        .onChange(of: ink) { applyInk() }
        .onChange(of: inkColor) { applyInk() }
        .onChange(of: inkWidth) { applyInk() }
        .task { await load() }
        // a moving crop frame doesn't render again: the picture under it stays the same
        // in Crop the straighten angle turns the shown picture under the frame instead, so it isn't in the render
        .task(id: RenderKey(edit: tool == .crop ? edit.withoutCrop.untilted : edit.withoutCrop, cropping: tool == .crop)) { await render(original: false) }
        .task(id: source.map { ObjectIdentifier(edit.base($0)) }) { baseDisplay = source.map { edit.base($0) }?.screenImage }
        .task(id: source == nil) { await makeFilterThumbs() }
        .task(id: framePosition) { await showFrame(at: framePosition) }
    }

    private struct RenderKey: Equatable {
        var edit: PhotoEdit
        var cropping: Bool
    }

    /// The photo, the same for every tool: where you zoomed and moved it stays when the tool changes.
    /// The tool's own layer (the crop frame, Clean Up's brush, the Markup canvas) sits on it and moves with it.
    @ViewBuilder private var canvasArea: some View {
        if let image = stageImage {
            EditorStage(image: image, inset: Self.cropInset, overlayCoversStage: tool == .crop, overlay: stageOverlay,
                        canvas: tool == .markup ? canvas : nil, tilt: cropTilt, viewing: viewsOriginal, twisting: tool == .crop,
                        onHold: { holding in
                            comparing = holding
                            Task { await render(original: holding) }
                        },
                        onTwist: { twist($0) },
                        onZoom: { zoom in Task { @MainActor in if abs(stageZoom - zoom) > 0.001 { stageZoom = zoom } } })
                .overlay(alignment: .top) { originalLabel }
                .overlay(alignment: .bottom) { cleanStatusLabel }
                .accessibilityHint("Pinch to zoom, two fingers to move")
        } else {
            ProgressView()
        }
    }

    /// Clean Up and Markup work on the photo's own pixels; the other tools show the edit.
    private var stageImage: UIImage? {
        tool == .cleanUp || tool == .markup ? baseDisplay ?? preview : preview
    }

    /// One finger held shows the original, on the tools that leave the photo alone.
    private var viewsOriginal: Bool { [.trim, .adjust, .filters, .live].contains(tool) }

    private var stageOverlay: AnyView? {
        if tool == .crop, previewUncropped {
            return AnyView(CropOverlay(crop: $edit.crop, imageAspect: imageAspect, ratio: cropRatio, inset: Self.cropInset))
        }
        if tool == .cleanUp, let source {
            return AnyView(CleanUpLayer(image: edit.base(source), brush: brush, zoom: stageZoom, status: $cleanStatus, error: $error) { retouch($0) })
        }
        return nil
    }

    /// Straighten turns the picture under the fixed frame, enlarged just enough that its corners never come inside the frame.
    private var cropTilt: (degrees: Double, scale: CGFloat) {
        guard tool == .crop, edit.straighten != 0 else { return (0, 1) }
        let aspect = Double(imageAspect)
        let angle = abs(edit.straighten) * .pi / 180
        let scale = cos(angle) + sin(angle) * max(aspect, 1 / aspect)
        // the mirrored orientations turn the other way
        return (edit.mirrored ? -edit.straighten : edit.straighten, CGFloat(scale))
    }

    @ViewBuilder private var originalLabel: some View {
        if comparing {
            Text("Original")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(.top, 8)
        }
    }

    @ViewBuilder private var cleanStatusLabel: some View {
        if let cleanStatus {
            Label { Text(cleanStatus) } icon: { ProgressView() }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding()
        }
    }

    /// Two fingers turning the photo: `degrees` clockwise since they started, nil when they lift.
    /// It sets the straighten angle in Crop (up to 45 either way; the Rotate button turns by quarters), and sticks at 0.
    private func twist(_ degrees: Double?) {
        guard let degrees else {
            twistStart = nil
            return
        }
        let start = twistStart ?? edit.straighten
        twistStart = start
        // the mirrored orientations turn the other way
        var angle = min(max(start + (edit.mirrored ? -degrees : degrees), -45), 45)
        if abs(angle) < 1.5 { angle = 0 }
        edit.straighten = angle
    }

    private func cancel() {
        if changed || !canvas.drawing.strokes.isEmpty { confirmsCancel = true } else { dismiss() }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        // Photos' centre of the bar: Undo and Redo once there is something to step through
        ToolbarItem(placement: .principal) {
            HStack(spacing: 18) {
                if !undo.isEmpty || !redo.isEmpty {
                    Button("Undo", systemImage: "arrow.uturn.backward") { stepBack() }.disabled(undo.isEmpty)
                    Button("Redo", systemImage: "arrow.uturn.forward") { stepForward() }.disabled(redo.isEmpty)
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

    /// The bottom row: a glass X to leave, the tools in one glass bar like the viewer's, and Auto on Adjust.
    /// The three are as tall as the bar (52 points) and apart, so the glass doesn't bridge between them.
    private var bottomRow: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 12) {
                Button { cancel() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
                modeBar
                Group {
                    if tool == .adjust {
                        Button {
                            if let source { applyAuto(edit.base(source)) }
                        } label: {
                            Image(systemName: "wand.and.stars").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Auto")
                        .accessibilityHint("Sets exposure, black point, contrast and saturation from the photo")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 52, height: 52)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// One glass bar with a round icon per tool, the chosen one in yellow.
    private var modeBar: some View {
        HStack(spacing: 0) {
            ForEach(tools, id: \.self) { item in
                Button { tool = item } label: {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(tool == item ? Color.yellow : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(tool == item ? Color.white.opacity(0.18) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tool == item ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: Crop

    private func cropIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.white).frame(width: 40, height: 40).background(Color.white.opacity(0.15), in: .circle)
    }

    /// The frame's shapes in a pop-up; the chosen one has a check, and choosing it again turns it.
    private var aspectMenu: some View {
        Menu {
            ForEach(PhotoEdit.Aspect.allCases, id: \.self) { aspect in
                Button { chooseAspect(aspect) } label: {
                    if cropAspect == aspect { Label(aspect.rawValue, systemImage: "checkmark") } else { Text(aspect.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(cropAspect.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.white.opacity(0.15), in: .capsule)
        }
        .accessibilityLabel("Frame shape")
        .accessibilityValue(cropAspect.rawValue)
    }

    private var imageAspect: CGFloat { preview.map { $0.size.width / max($0.size.height, 1) } ?? 1 }

    /// The frame's width over its height while a shape is locked; nil for Free.
    private var cropRatio: CGFloat? {
        switch cropAspect {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        default:
            let landscape = cropAspect.ratio ?? 1
            return (imageAspect < 1) != cropFlipped ? 1 / landscape : landscape
        }
    }

    private func chooseAspect(_ aspect: PhotoEdit.Aspect) {
        if aspect == cropAspect, aspect.ratio != nil { cropFlipped.toggle() } else { cropAspect = aspect; cropFlipped = false }
        guard let ratio = cropRatio else { return }
        // the largest frame of that shape, in the middle
        let k = imageAspect / ratio
        let width = min(1, 1 / k), height = width * k
        withAnimation(.snappy) { edit.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height) }
    }

    /// Turns the photo a quarter to the left, and the frame with it.
    private func rotateCrop() {
        let c = edit.crop
        edit.quarterTurns = (edit.quarterTurns + 1) % 4
        edit.crop = CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
    }

    /// The mirrored orientations flip sideways on an upright photo and top to bottom on a turned one.
    private func mirrorCrop() {
        let c = edit.crop
        edit.mirrored.toggle()
        edit.crop = edit.quarterTurns % 2 == 1 ? CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
                                               : CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
    }

    // MARK: Markup

    /// The strokes drawn so far become part of the photo.
    private func commitMarkup() {
        if let source, let marked = MarkupCanvas.flatten(canvas, onto: edit.base(source)) { retouch(marked) }
        canvas.drawing = PKDrawing()
    }

    private func applyInk() {
        switch ink {
        case .pen: canvas.tool = PKInkingTool(.pen, color: UIColor(inkColor), width: inkWidth)
        case .marker: canvas.tool = PKInkingTool(.marker, color: UIColor(inkColor), width: inkWidth * 3)
        case .pencil: canvas.tool = PKInkingTool(.pencil, color: UIColor(inkColor), width: inkWidth)
        case .eraser: canvas.tool = PKEraserTool(.bitmap)
        }
    }

    /// Markup's own tools, in the place the sliders have on the other tools: the pens drawn like the system picker's,
    /// rising from the bottom edge, the chosen one raised.
    private var markupControls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Ink.allCases, id: \.self) { kind in
                    Button { ink = kind } label: {
                        PenArt(kind: kind, color: inkColor)
                            .offset(y: ink == kind ? 6 : 22)
                            .animation(.snappy, value: ink)
                            .frame(width: 40, height: 62, alignment: .top)
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.rawValue)
                    .accessibilityAddTraits(ink == kind ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button("Undo Stroke", systemImage: "arrow.uturn.backward") { canvas.undoManager?.undo() }
                Button("Redo Stroke", systemImage: "arrow.uturn.forward") { canvas.undoManager?.redo() }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .padding(.horizontal)
            if ink != .eraser {
                HStack(spacing: 10) {
                    ForEach([Color.black, .white, .red, .orange, .yellow, .green, .blue], id: \.self) { color in
                        Button { inkColor = color } label: {
                            Circle().fill(color).frame(width: 26, height: 26)
                                .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1) }
                                .overlay { if inkColor == color { Circle().stroke(Color.yellow, lineWidth: 2).padding(-4) } }
                                .frame(width: 34, height: 34)
                        }
                        .accessibilityLabel(color.description)
                    }
                    ColorPicker("Color", selection: $inkColor, supportsOpacity: false).labelsHidden()
                }
                .padding(.horizontal)
                Slider(value: $inkWidth, in: 2...30).tint(.yellow).accessibilityLabel("Stroke Width").padding(.horizontal)
            }
        }
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
            VStack(spacing: 6) {
                // the slider on top, the dials under it, as in Photos
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
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(PhotoEdit.Slider.allCases, id: \.self) { dial($0) }
                    }
                    .padding(.horizontal)
                    // room for the ring's stroke, which the scroll view would cut off at the top and bottom
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        case .filters:
            VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(PhotoEdit.filters, id: \.title) { filter in
                        let chosen = edit.filter == filter.name
                        Button {
                            if edit.filter != filter.name { edit.filterAmount = 1 }
                            edit.filter = filter.name
                        } label: {
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
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(width: 64)
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
            // how much of the look is applied
            HStack {
                Slider(value: $edit.filterAmount, in: 0...1).tint(.yellow).accessibilityLabel("Filter Intensity")
                Text("\(Int((edit.filterAmount * 100).rounded()))").font(.caption.monospacedDigit()).frame(width: 40)
            }
            .padding(.horizontal)
            .disabled(edit.filter == nil)
            .opacity(edit.filter == nil ? 0.35 : 1)
            }
        case .crop:
            VStack(spacing: 10) {
                // the slider on top, then which angle it turns, then the buttons and the shape of the frame
                HStack {
                    switch cropAngle {
                    case .straighten:
                        Slider(value: $edit.straighten, in: -45...45, step: 0.5).tint(.yellow).accessibilityLabel("Straighten")
                        Text("\(edit.straighten, specifier: "%.1f")°").font(.caption.monospacedDigit()).frame(width: 48)
                    case .vertical:
                        Slider(value: $edit.perspectiveV, in: -1...1).tint(.yellow).accessibilityLabel("Vertical Perspective")
                        Text("\(Int((edit.perspectiveV * 100).rounded()))").font(.caption.monospacedDigit()).frame(width: 48)
                    }
                }
                .padding(.horizontal)
                Picker("Angle", selection: $cropAngle) {
                    ForEach(CropAngle.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                HStack(spacing: 10) {
                    Button { rotateCrop() } label: { cropIcon("rotate.left") }.accessibilityLabel("Rotate")
                    Button { mirrorCrop() } label: { cropIcon("arrow.left.and.right.righttriangle.left.righttriangle.right") }.accessibilityLabel("Flip")
                    Spacer(minLength: 0)
                    aspectMenu
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
            markupControls
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
        // Crop shows the whole picture with the frame over it
        let cropping = tool == .crop && !original
        let shown = cropping ? edit.withoutCrop.untilted : edit
        let base = original ? source : shown.base(source)
        let scale = min(1, 1600 / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = original ? small : small.applying(shown, scale: scale)
        guard let cgImage = PhotoEdit.context.createCGImage(image, from: image.extent) else { return }
        preview = UIImage(cgImage: cgImage)
        previewUncropped = cropping || edit.crop == PhotoEdit.unit
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
        commitMarkup()
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
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

    /// The crop frame's shape: Free moves each side alone, Original keeps the photo's own shape, the rest are landscape
    /// ratios that turn upright on a portrait photo (tap the chosen one again to turn it).
    enum Aspect: String, CaseIterable {
        case free = "Free", original = "Original", square = "Square", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9"

        var ratio: CGFloat? {
            switch self {
            case .free, .original, .square: nil
            case .fourThree: 4 / 3
            case .threeTwo: 3 / 2
            case .sixteenNine: 16 / 9
            }
        }
    }

    /// The whole picture, in 0…1 with the origin at the top left.
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The Filters strip: the name is what `filter` holds. The first ones are made here; "CIPhotoEffect…" are Core Image's own.
    static let filters: [(name: String?, title: String)] = [
        (nil, "Original"), ("Vivid", "Vivid"), ("Vivid Warm", "Vivid Warm"), ("Vivid Cool", "Vivid Cool"),
        ("Dramatic", "Dramatic"), ("Dramatic Warm", "Dramatic Warm"), ("Dramatic Cool", "Dramatic Cool"),
        ("Matte", "Matte"), ("Film", "Film"), ("CIPhotoEffectFade", "Fade"), ("CIPhotoEffectInstant", "Instant"),
        ("CIPhotoEffectChrome", "Chrome"), ("CIPhotoEffectProcess", "Process"), ("CIPhotoEffectTransfer", "Transfer"),
        ("CIPhotoEffectMono", "Mono"), ("CIPhotoEffectTonal", "Silvertone"), ("CIPhotoEffectNoir", "Noir"),
    ]

    static let context = CIContext()

    var values: [Slider: Double] = [:]
    var filter: String?
    /// How much of the filter is applied, 0…1.
    var filterAmount = 1.0
    var quarterTurns = 0
    var mirrored = false
    var straighten = 0.0
    /// Vertical and horizontal perspective, -1…1.
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    /// The part kept, in 0…1 of the picture after rotating, straightening and perspective; the origin is the top left.
    var crop = PhotoEdit.unit
    var motionOff = false
    var keyFrame: CIImage?
    /// The photo after Clean Up and Markup, in place of the original's pixels.
    var retouched: CIImage?

    subscript(slider: Slider) -> Double {
        get { values[slider] ?? slider.neutral }
        set { values[slider] = newValue == slider.neutral ? nil : newValue }
    }

    static func == (a: PhotoEdit, b: PhotoEdit) -> Bool {
        a.values == b.values && a.filter == b.filter && a.filterAmount == b.filterAmount && a.quarterTurns == b.quarterTurns && a.mirrored == b.mirrored
            && a.straighten == b.straighten && a.perspectiveV == b.perspectiveV && a.perspectiveH == b.perspectiveH && a.crop == b.crop && a.motionOff == b.motionOff && a.keyFrame === b.keyFrame
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
    /// A crop of a turned photo is baked into new pixels: the server's crop works on the photo as it was shot.
    var isGeometryOnly: Bool {
        values.isEmpty && filter == nil && straighten == 0 && perspectiveV == 0 && perspectiveH == 0 && keyFrame == nil && retouched == nil && !motionOff
            && (crop == Self.unit || quarterTurns == 0)
    }

    /// The same edit with the whole picture kept, which is what the Crop tool shows while the frame moves.
    var withoutCrop: PhotoEdit {
        var copy = self
        copy.crop = Self.unit
        return copy
    }

    /// The same edit without the straighten angle: Crop turns the shown picture itself instead.
    var untilted: PhotoEdit {
        var copy = self
        copy.straighten = 0
        return copy
    }

    /// Immich edits, applied by the server in this order: crop on the original pixels, then rotate, then mirror.
    func serverEdits(width: Int, height: Int) -> [[String: Any]] {
        var edits: [[String: Any]] = []
        if crop != Self.unit {
            // isGeometryOnly keeps this to photos that aren't turned; a mirror flips the frame sideways
            let x = mirrored ? 1 - crop.maxX : crop.minX
            edits.append(["action": "crop", "parameters": ["x": Int((x * CGFloat(width)).rounded()), "y": Int((crop.minY * CGFloat(height)).rounded()),
                                                           "width": Int((crop.width * CGFloat(width)).rounded()), "height": Int((crop.height * CGFloat(height)).rounded())]])
        }
        if quarterTurns != 0 { edits.append(["action": "rotate", "parameters": ["angle": (4 - quarterTurns) % 4 * 90]]) }
        // on a turned photo the mirrored orientations flip top to bottom
        if mirrored { edits.append(["action": "mirror", "parameters": ["axis": quarterTurns % 2 == 1 ? "vertical" : "horizontal"]]) }
        return edits
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
        if let name = edit.filter { image = image.looked(name, amount: edit.filterAmount) }
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
        if edit.crop != PhotoEdit.unit {
            let e = image.extent, c = edit.crop
            // Core Image's y runs upward, the crop's runs downward
            image = image.cropped(to: CGRect(x: e.minX + c.minX * e.width, y: e.minY + (1 - c.maxY) * e.height, width: c.width * e.width, height: c.height * e.height))
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

extension CIImage {
    /// A look from the Filters strip, `amount` (0…1) of the way from the photo to the full look.
    func looked(_ name: String, amount: Double) -> CIImage {
        let extent = self.extent
        let styled: CIImage
        switch name {
        case "Vivid": styled = vivid
        case "Vivid Warm": styled = vivid.lookWarmed(0.35)
        case "Vivid Cool": styled = vivid.lookWarmed(-0.35)
        case "Dramatic": styled = dramatic
        case "Dramatic Warm": styled = dramatic.lookWarmed(0.3)
        case "Dramatic Cool": styled = dramatic.lookWarmed(-0.3)
        case "Matte": styled = lookLifted(black: 0.08, white: 0.95).lookTuned(saturation: 0.88, contrast: 0.95)
        case "Film": styled = lookTuned(saturation: 0.9, contrast: 1.05).lookWarmed(0.2).lookLifted(black: 0.04, white: 0.97).lookVignetted(0.5)
        default:
            // a Core Image photo effect, or a name from an older save
            guard let f = CIFilter(name: name) else { return self }
            f.setValue(self, forKey: kCIInputImageKey)
            styled = f.outputImage ?? self
        }
        guard amount < 1 else { return styled }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = self
        blend.targetImage = styled
        blend.time = Float(max(amount, 0))
        return (blend.outputImage ?? styled).cropped(to: extent)
    }

    private var vivid: CIImage { lookTuned(saturation: 1.15, contrast: 1.06).lookVibrant(0.5) }
    private var dramatic: CIImage { lookTuned(saturation: 0.85, contrast: 1.25).lookShadowed(shadows: -0.35, highlights: 0.7).lookVignetted(0.7) }

    private func lookTuned(saturation: Double = 1, contrast: Double = 1) -> CIImage {
        let f = CIFilter.colorControls(); f.inputImage = self; f.saturation = Float(saturation); f.contrast = Float(contrast)
        return f.outputImage ?? self
    }

    private func lookVibrant(_ amount: Double) -> CIImage {
        let f = CIFilter.vibrance(); f.inputImage = self; f.amount = Float(amount)
        return f.outputImage ?? self
    }

    /// Positive is warmer, negative cooler.
    private func lookWarmed(_ amount: Double) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = self
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: 6500 - amount * 2500, y: 0)
        return f.outputImage ?? self
    }

    /// Blacks raised to `black` and whites lowered to `white`: the faded, matte look.
    private func lookLifted(black: Double, white: Double) -> CIImage {
        let gain = CGFloat(white - black), bias = CGFloat(black)
        let f = CIFilter.colorMatrix()
        f.inputImage = self
        f.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return f.outputImage ?? self
    }

    private func lookShadowed(shadows: Double, highlights: Double) -> CIImage {
        let f = CIFilter.highlightShadowAdjust(); f.inputImage = self; f.shadowAmount = Float(shadows); f.highlightAmount = Float(highlights)
        return f.outputImage ?? self
    }

    private func lookVignetted(_ intensity: Double) -> CIImage {
        let f = CIFilter.vignette(); f.inputImage = self; f.intensity = Float(intensity); f.radius = 1.5
        return f.outputImage ?? self
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

// MARK: - Crop frame

/// Crop's frame over the whole picture: drag a corner or a side to resize it, the inside to move it.
/// `inset` is the room the picture leaves around it, where a finger on a corner can still land.
struct CropOverlay: View {
    @Binding var crop: CGRect
    let imageAspect: CGFloat
    /// The frame's width over its height while a shape is locked.
    let ratio: CGFloat?
    let inset: CGFloat

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    private struct Grab {
        var edges: Edges
        var start: CGRect
    }

    @State private var grab: Grab?
    /// The smallest side of the frame, in 0…1 of the picture.
    private static let minSide: CGFloat = 0.08

    var body: some View {
        GeometryReader { geometry in
            let fit = pictureRect(in: geometry.size)
            let frame = CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height,
                               width: crop.width * fit.width, height: crop.height * fit.height)
            ZStack {
                // the part that goes is dimmed
                Path { path in
                    // the whole stage, so a picture turned past its frame is dimmed too
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(frame)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                // thirds
                Path { path in
                    for step in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: frame.minX + frame.width * step, y: frame.minY))
                        path.addLine(to: CGPoint(x: frame.minX + frame.width * step, y: frame.maxY))
                        path.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * step))
                        path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * step))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                Path { $0.addRect(frame) }.stroke(.white, lineWidth: 1)
                // corners and the middle of each side
                Path { path in
                    let long: CGFloat = 22
                    for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                                             (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
                        path.move(to: CGPoint(x: corner.x, y: corner.y + dy * long))
                        path.addLine(to: corner)
                        path.addLine(to: CGPoint(x: corner.x + dx * long, y: corner.y))
                    }
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .square, lineJoin: .miter))
                Path { path in
                    let half: CGFloat = 12
                    for x in [frame.minX, frame.maxX] {
                        path.move(to: CGPoint(x: x, y: frame.midY - half)); path.addLine(to: CGPoint(x: x, y: frame.midY + half))
                    }
                    for y in [frame.minY, frame.maxY] {
                        path.move(to: CGPoint(x: frame.midX - half, y: y)); path.addLine(to: CGPoint(x: frame.midX + half, y: y))
                    }
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if grab == nil {
                    guard let held = grabbed(at: value.startLocation, in: frame) else { return }
                    grab = Grab(edges: held, start: crop)
                }
                guard let grab else { return }
                crop = moved(grab, dx: value.translation.width / fit.width, dy: value.translation.height / fit.height)
            }.onEnded { _ in
                grab = nil
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Crop frame")
    }

    /// Where the picture sits: the largest of its shape inside the view, less the inset.
    private func pictureRect(in size: CGSize) -> CGRect {
        let room = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let width = min(room.width, room.height * imageAspect)
        let height = width / imageAspect
        return CGRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height)
    }

    /// Which sides a touch at `point` holds: two for a corner, one for a side, none to move the whole frame; nil outside.
    private func grabbed(at point: CGPoint, in frame: CGRect) -> Edges? {
        let reach: CGFloat = 32
        let inX = point.x > frame.minX - reach && point.x < frame.maxX + reach
        let inY = point.y > frame.minY - reach && point.y < frame.maxY + reach
        var edges: Edges = []
        if inY {
            let toLeft = abs(point.x - frame.minX), toRight = abs(point.x - frame.maxX)
            if min(toLeft, toRight) < reach { edges.insert(toLeft < toRight ? .left : .right) }
        }
        if inX {
            let toTop = abs(point.y - frame.minY), toBottom = abs(point.y - frame.maxY)
            if min(toTop, toBottom) < reach { edges.insert(toTop < toBottom ? .top : .bottom) }
        }
        if !edges.isEmpty { return edges }
        return frame.contains(point) ? [] : nil
    }

    /// The frame after a drag of `dx`, `dy` (in 0…1 of the picture) from where the grab began.
    private func moved(_ grab: Grab, dx: CGFloat, dy: CGFloat) -> CGRect {
        let s = grab.start, edges = grab.edges
        if edges.isEmpty {
            return CGRect(x: min(max(s.minX + dx, 0), 1 - s.width), y: min(max(s.minY + dy, 0), 1 - s.height), width: s.width, height: s.height)
        }
        let m = Self.minSide
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if edges.contains(.left) { minX = min(max(s.minX + dx, 0), s.maxX - m) }
        if edges.contains(.right) { maxX = max(min(s.maxX + dx, 1), s.minX + m) }
        if edges.contains(.top) { minY = min(max(s.minY + dy, 0), s.maxY - m) }
        if edges.contains(.bottom) { maxY = max(min(s.maxY + dy, 1), s.minY + m) }
        guard let ratio else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        // a locked shape: the width (or the height, when only top or bottom moves) leads, the other side follows,
        // and the opposite corner or side stays where it was
        let k = imageAspect / ratio
        let leadsByWidth = edges.contains(.left) || edges.contains(.right)
        var width = leadsByWidth ? maxX - minX : (maxY - minY) / k
        let anchorX = edges.contains(.left) ? s.maxX : edges.contains(.right) ? s.minX : s.midX
        let anchorY = edges.contains(.top) ? s.maxY : edges.contains(.bottom) ? s.minY : s.midY
        let roomX = edges.contains(.left) ? anchorX : edges.contains(.right) ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX)
        let roomY = edges.contains(.top) ? anchorY : edges.contains(.bottom) ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY)
        width = min(max(width, m), roomX, roomY / k)
        let height = width * k
        return CGRect(x: edges.contains(.left) ? anchorX - width : edges.contains(.right) ? anchorX : anchorX - width / 2,
                      y: edges.contains(.top) ? anchorY - height : edges.contains(.bottom) ? anchorY : anchorY - height / 2,
                      width: width, height: height)
    }
}

// MARK: - Pens

/// A pen, marker, pencil or eraser drawn upright with the tip up, shaded like a cylinder.
/// Every tool is 26pt wide and 90pt tall; the picker clips the long barrel at the bottom edge.
struct PenArt: View {
    let kind: EditorView.Ink
    let color: Color

    /// A trapezoid: `top` wide at the top, full width at the bottom.
    private struct Taper: Shape {
        var top: CGFloat
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX - top / 2, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX + top / 2, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }

    /// Light on the left of centre, dark at both edges: reads as a round body.
    private var shade: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.28), location: 0), .init(color: .white.opacity(0.35), location: 0.3),
                               .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.3), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private func body(_ base: Color, height: CGFloat) -> some View {
        Rectangle().fill(base).overlay { shade }.frame(width: 26, height: height)
    }

    private func band(_ base: Color, height: CGFloat) -> some View {
        Rectangle().fill(base).overlay { shade }.frame(width: 26, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch kind {
            case .pen:
                Taper(top: 1).fill(Color(white: 0.82)).overlay { shade.mask { Taper(top: 1) } }.frame(width: 26, height: 22)
                    .overlay(alignment: .top) { Taper(top: 1).fill(color).frame(width: 7, height: 9) }
                band(Color(white: 0.3), height: 5)
                body(Color(white: 0.9), height: 64)
            case .marker:
                Taper(top: 12).fill(color).overlay { shade.mask { Taper(top: 12) } }.frame(width: 26, height: 20)
                band(Color(white: 0.3), height: 5)
                body(Color(white: 0.9), height: 66)
            case .pencil:
                Taper(top: 1).fill(Color(red: 0.93, green: 0.78, blue: 0.58)).overlay { shade.mask { Taper(top: 1) } }.frame(width: 26, height: 26)
                    .overlay(alignment: .top) { Taper(top: 1).fill(color).frame(width: 8, height: 10) }
                body(Color(red: 0.98, green: 0.78, blue: 0.2), height: 64)
            case .eraser:
                UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 13)
                    .fill(Color(red: 1, green: 0.6, blue: 0.68)).overlay { shade }.frame(width: 26, height: 26)
                band(Color(white: 0.6), height: 8)
                body(Color(white: 0.9), height: 56)
            }
        }
        .clipShape(.rect(bottomLeadingRadius: 5, bottomTrailingRadius: 5))
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}
