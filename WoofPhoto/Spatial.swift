import CoreML
import CoreMotion
import MetalKit
import OnnxRuntimeBindings
import SwiftUI
import Vision
import os
import simd

// Spatial Scenes: a port of prototype/spatial/index.html. The photo is split into a front layer and a
// back layer at their own depths; tilting the iPhone slides the nearer layer more, like looking through a window.

/// The photo full screen as a Spatial Scene, opened from the viewer's bottom bar.
struct SpatialView: View {
    let asset: AssetRef

    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = SpatialScene()

    var body: some View {
        // transparent around the photo: the viewer's blurred ambient shows through, as in the flat viewer
        SpatialCanvas(scene: scene, reduced: reduceMotion)
            .ignoresSafeArea()
            // dragging tilts too, for Reduce Motion and for looking without moving the iPhone; 200 points is a full tilt
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { scene.drag = SIMD2(Float($0.translation.width / 200), Float($0.translation.height / 200)) }
                .onEnded { _ in scene.drag = .zero })
            .accessibilityElement()
            .accessibilityLabel("Spatial scene")
            .accessibilityValue(scene.status ?? "Ready")
            .overlay(alignment: .bottom) {
                if let status = scene.status {
                    Text(status)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: scene.status)
            .task { await scene.build(asset, client: session.client) }
    }
}

// MARK: - Building a scene

/// What the renderer draws. Every buffer is RGBA8, row by row from the top, `width` × `height` pixels.
struct SceneLayers: Sendable {
    var width: Int
    var height: Int
    var photo: [UInt8]
    var background: [UInt8]
    /// R = front depth, G = front alpha, B = back depth; 255 is near. A = focus: 255 on the subject, 0 behind it.
    var data: [UInt8]
    /// R = how strongly each pixel shimmers while the hidden area is rebuilt.
    var mask: [UInt8]
}

@MainActor @Observable
final class SpatialScene {
    /// Shown at the bottom; nil once the scene is ready.
    var status: String? = "Loading the photo…"
    private(set) var layers: SceneLayers?
    /// Goes up every time `layers` changes, so the renderer uploads new textures.
    private(set) var version = 0
    // the loading animation: the scan reads the flat photo, the depth rises in, the rebuilt area shimmers
    var scanGoal: Float = 0
    var buildGoal: Float = 0
    var riseStart: CFTimeInterval?
    /// Finger tilt, -1…1 on each axis, added to the iPhone's own tilt.
    var drag = SIMD2<Float>.zero

    private func show(_ layers: SceneLayers) {
        self.layers = layers
        version += 1
    }

    func build(_ asset: AssetRef, client: ImmichClient?) async {
        let started = Date.now
        let image = if let localID = asset.localID {
            await DeviceLibrary.image(localID, side: 1440)
        } else {
            await Still.load(asset.id, size: "preview", client: client)
        }
        guard let image, let photo = await Task.detached(operation: { Photo(image) }).value else {
            status = "Can't load this photo."
            return
        }
        if let cached = SpatialCache.read(asset.id, photo: photo) {
            show(cached)
            riseStart = CACurrentMediaTime()
            status = nil
            return
        }
        show(photo.flat)
        scanGoal = 1
        do {
            // Depth Anything Base: about 400 MB of weights plus the photo's activations
            guard os_proc_available_memory() > 1200 << 20 else {
                status = "Not enough free memory to estimate depth. Close other apps and try again."
                return
            }
            let downloaded = FileManager.default.fileExists(atPath: AIModel.depth.file.path)
            status = downloaded ? "Estimating depth…" : "Downloading the depth model (390 MB, only once)…"
            let depthModel = try await AIModel.depth.download()
            status = "Estimating depth…"
            let raw = try await Task.detached { try Spatial.depth(photo, model: depthModel) }.value
            let split = await Task.detached { Spatial.split(photo, depth: raw, subject: Spatial.subjectMask(photo)) }.value
            try Task.checkCancellation()
            show(split.layers)
            scanGoal = 0
            riseStart = CACurrentMediaTime()
            guard split.holeBox != nil else {
                status = nil
                SpatialCache.write(split.layers, id: asset.id)
                return
            }
            guard Spatial.lamaFits else {
                status = "Not enough free memory to rebuild the background, so it's filled from the edges."
                return
            }
            buildGoal = 1
            status = LaMa.isDownloaded ? "Depth ready in \(started.secondsSince). Loading LaMa…"
                : "Depth ready in \(started.secondsSince). Downloading LaMa (40 MB, only once)…"
            let lama = try await LaMa.download()
            // closed while depth ran: don't start LaMa for a scene nobody sees
            try Task.checkCancellation()
            // each step shows, so a slow one can be told apart from one that never started
            let progress: @Sendable (String) -> Void = { text in Task { @MainActor in self.status = text } }
            let filled = try await Task.detached { try Spatial.inpaint(photo, split, model: lama, progress: progress) }.value
            try Task.checkCancellation()
            show(filled)
            SpatialCache.write(filled, id: asset.id)
            buildGoal = 0
            status = nil
        } catch is CancellationError {
        } catch {
            buildGoal = 0
            scanGoal = 0
            status = "Couldn't build the scene: \(error.localizedDescription)"
        }
    }
}

extension Date {
    var secondsSince: String { (Date.now.timeIntervalSince(self)).formatted(.number.precision(.fractionLength(1))) + " s" }
}

/// The photo at the working size: 1280 pixels on the longest side, like the prototype.
struct Photo: Sendable {
    static let workSize = 1280
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(_ image: UIImage) {
        let scale = min(1, Double(Self.workSize) / max(image.size.width, image.size.height))
        let (width, height) = (Int((image.size.width * scale).rounded()), Int((image.size.height * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // UIKit draws top down and applies the photo's orientation
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, self.rgba) = (width, height, rgba)
    }

    /// Red, green, blue as 0…255 floats, three per pixel.
    var rgb: [Float] {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<width * height {
            for c in 0..<3 { rgb[i * 3 + c] = Float(rgba[i * 4 + c]) }
        }
        return rgb
    }

    /// Depth 0 everywhere, fully opaque, no hole: the flat photo shown while the depth model runs.
    var flat: SceneLayers {
        let count = width * height
        return SceneLayers(width: width, height: height, photo: rgba, background: rgba,
                           data: [UInt8](repeating: 0, count: count * 4).enumerated().map { $0.offset % 4 == 1 || $0.offset % 4 == 3 ? 255 : 0 },
                           mask: [UInt8](repeating: 0, count: count * 4))
    }
}

/// The two models, the same ONNX files the prototype runs. Downloaded once into Caches.
struct AIModel: Sendable {
    var url: URL

    static let depth = AIModel(url: URL(string: "https://huggingface.co/onnx-community/depth-anything-v2-base/resolve/main/onnx/model.onnx")!)

    /// Where the download lives; it exists once the model was downloaded.
    var file: URL { URL.cachesDirectory.appending(path: "models").appending(path: url.lastPathComponent) }

    func download() async throws -> URL {
        let file = file
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let (temp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }

    typealias Tensor = (values: [Float], shape: [Int])

    static func run(_ file: URL, inputs: [String: Tensor], output: String) throws -> Tensor {
        try run(file, batch: [inputs], output: output)[0]
    }

    /// Loads the model once, runs it on each input set, and releases it, so only one model is in memory at a time.
    static func run(_ file: URL, batch: [[String: Tensor]], output: String) throws -> [Tensor] {
        try autoreleasepool {
            let env = try ORTEnv(loggingLevel: .warning)
            // ponytail: CPU only; onnxruntime 1.20's Core ML recompiles on every run and lacks LaMa's FFT, try again on a newer onnxruntime
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(ProcessInfo.processInfo.activeProcessorCount))
            let session = try ORTSession(env: env, modelPath: file.path, sessionOptions: options)
            // each run's buffers are released before the next one, not at the end of the batch
            return try batch.map { inputs in try autoreleasepool {
                var feeds: [String: ORTValue] = [:]
                for (name, input) in inputs {
                    let data = input.values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
                    feeds[name] = try ORTValue(tensorData: data, elementType: .float, shape: input.shape.map { NSNumber(value: $0) })
                }
                guard let value = try session.run(withInputs: feeds, outputNames: [output], runOptions: nil)[output] else {
                    throw CocoaError(.featureUnsupported)
                }
                let shape = try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
                let values = (try value.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return (values, shape)
            } }
        }
    }
}

/// LaMa converted to Core ML (6-bit, 40 MB), so it runs on the GPU instead of onnxruntime's CPU.
/// Downloaded as the three files of its .mlpackage and compiled once on the iPhone.
enum LaMa {
    private static let base = URL(string: "https://huggingface.co/Dadm-n/lama-dilated-coreml/resolve/main/Resources/LaMa.mlpackage/")!
    private static let parts = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
    /// The compiled model; it exists once downloaded.
    static var compiled: URL { URL.cachesDirectory.appending(path: "models/LaMa.mlmodelc") }
    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    static func download() async throws -> URL {
        let compiled = compiled
        if isDownloaded { return compiled }
        let started = Date.now
        let package = FileManager.default.temporaryDirectory.appending(path: "LaMa.mlpackage")
        try? FileManager.default.removeItem(at: package)
        defer { try? FileManager.default.removeItem(at: package) }
        for part in parts {
            let (temp, response) = try await URLSession.shared.download(from: base.appending(path: part))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let file = package.appending(path: part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: file)
        }
        FileLog.shared.append("TIME", "LaMa downloaded in \(started.secondsSince)")
        let compiling = Date.now
        let built = try await MLModel.compileModel(at: package)
        FileLog.shared.append("TIME", "LaMa compiled in \(compiling.secondsSince)")
        try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: built, to: compiled)
        return compiled
    }
}

/// Saves the finished back layer and depth per asset, so a scene is built only once.
/// ponytail: no size limit; iOS empties Caches when the iPhone runs low on space.
enum SpatialCache {
    /// Bump when the models or the split change, so old scenes are built again.
    private static let version = 10
    private static func folder(_ version: Int) -> URL {
        URL.cachesDirectory.appending(path: version == 1 ? "spatial" : "spatial-\(version)")
    }
    private static func file(_ id: String) -> URL {
        folder(version).appending(path: "\(id.replacingOccurrences(of: "/", with: "_")).scene")
    }
    /// Scenes from older versions; deleted once per launch, on the first save.
    private static let dropOld: Void = {
        for old in 1..<version { try? FileManager.default.removeItem(at: folder(old)) }
    }()
    /// Every scene, current and old: signing out removes them.
    static func removeAll() {
        for v in 1...version { try? FileManager.default.removeItem(at: folder(v)) }
    }

    static func read(_ id: String, photo: Photo) -> SceneLayers? {
        let size = photo.width * photo.height * 4
        guard let packed = try? Data(contentsOf: file(id)),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              data.count == size * 2 else { return nil }
        return SceneLayers(width: photo.width, height: photo.height, photo: photo.rgba,
                           background: [UInt8](data.prefix(size)), data: [UInt8](data.suffix(size)),
                           mask: [UInt8](repeating: 0, count: size))
    }

    static func write(_ layers: SceneLayers, id: String) {
        _ = dropOld
        let url = file(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (Data(layers.background + layers.data) as NSData).compressed(using: .lzfse).write(to: url, options: .completeFileProtection)
    }
}

/// The prototype's image processing, step for step.
enum Spatial {
    /// Depth difference (0…1) within 3 pixels that counts as a separate object; lower values cut subjects apart.
    static let jump: Float = 0.3
    /// LaMa's fixed input size.
    static let lamaSize = 512
    /// Free memory LaMa needs: the onnxruntime build peaked at about 490 MB in the M0 spike.
    /// ponytail: kept for the Core ML build, which likely needs less; lower it once measured
    static var lamaFits: Bool { os_proc_available_memory() > 700 << 20 }

    struct Split: Sendable {
        var layers: SceneLayers
        /// 1 where the back layer gets new colours.
        var hole: [Float]
        var glow: [Float]
        /// x0, y0, x1, y1 of the hole; nil when there are no sharp depth edges.
        var holeBox: (x0: Int, y0: Int, x1: Int, y1: Int)?
    }

    /// Depth Anything V2: the short side 518 and both sides a multiple of 14, ImageNet mean and deviation.
    /// The long side stops at 728: attention memory grows with the square of the 14-pixel patches, and a tall
    /// screenshot at 518 wide needed several hundred MB more, enough for iOS to close the app.
    /// Returns 0…1 per pixel at the photo's size, 1 = near.
    static func depth(_ photo: Photo, model: URL) throws -> [Float] {
        let (W, H) = (photo.width, photo.height)
        let scale = min(518 / Float(min(W, H)), 728 / Float(max(W, H)))
        let w = max(14, Int((Float(W) * scale / 14).rounded()) * 14)
        let h = max(14, Int((Float(H) * scale / 14).rounded()) * 14)
        let small = resize(photo.rgb, W, 3, region: (0, 0, W, H), to: w, h)
        let mean: [Float] = [0.485, 0.456, 0.406], deviation: [Float] = [0.229, 0.224, 0.225]
        var input = [Float](repeating: 0, count: 3 * w * h)
        for i in 0..<w * h {
            for c in 0..<3 { input[c * w * h + i] = (small[i * 3 + c] / 255 - mean[c]) / deviation[c] }
        }
        let out = try AIModel.run(model, inputs: ["pixel_values": (input, [1, 3, h, w])], output: "predicted_depth")
        let (outH, outW) = (out.shape[out.shape.count - 2], out.shape[out.shape.count - 1])
        let top = max(out.values.max() ?? 1, .leastNonzeroMagnitude)
        return resize(out.values.map { max(0, $0) / top }, outW, 1, region: (0, 0, outW, outH), to: W, H)
    }

    /// The subject's outline from Vision, the same mask Photos uses to lift a subject off a photo.
    /// 1 on the subject, 0 elsewhere; nil when Vision finds no subject (a landscape) or fails.
    static func subjectMask(_ photo: Photo) -> [Float]? {
        let (W, H) = (photo.width, photo.height)
        guard let provider = CGDataProvider(data: Data(photo.rgba) as CFData),
              let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest(), handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler),
              CVPixelBufferGetWidth(buffer) == W, CVPixelBufferGetHeight(buffer) == H
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var mask = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            let line = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<W { mask[y * W + x] = line[x] > 0.5 ? 1 : 0 }
        }
        return mask
    }

    /// `subject`: Vision's subject mask. With it the outline comes from the mask, which follows fur and hair
    /// far closer than the depth map's soft edge; the depth only decides how near the subject is.
    static func split(_ photo: Photo, depth raw: [Float], subject mask: [Float]? = nil) -> Split {
        let (W, H, N) = (photo.width, photo.height, photo.width * photo.height)
        let longest = Float(max(W, H))
        let rgba = photo.rgba

        // the depth map fades over a few pixels at an edge, and the subject's outline sits in that fade.
        // Snap the fade into a clean step, pushed outward: anything 8% up the fade belongs to the subject,
        // so the outline moves with it and the repaint removes it from the background.
        let R = max(4, Int((0.006 * longest).rounded()))
        let lo = erode(raw, W, H, R), hiInv = erode(raw.map { 1 - $0 }, W, H, R)
        var d = [Float](repeating: 0, count: N)
        for i in 0..<N {
            let hi = 1 - hiInv[i], range = hi - lo[i]
            d[i] = range > jump ? (raw[i] - lo[i] > 0.08 * range ? hi : lo[i]) : raw[i]
        }
        if let mask {
            // around the subject: the background's depth, filled in from outside the mask (grown past the outline,
            // where the depth map still fades). On the subject: at least a clear step nearer, so the whole outline
            // tears and the subject moves as one layer over the background, as in Photos.
            let outside = erode(mask.map { 1 - $0 }, W, H, R)
            var back = d
            fill(&back, outside, W, H, 1)
            for i in 0..<N { d[i] = mask[i] > 0 ? min(1, max(d[i], back[i] + jump + 0.1)) : back[i] }
        }

        // tears: pixels clearly farther than something 3 px away, i.e. the FAR side of a sharp depth jump.
        // The depth map is blurrier than the photo, so tearing the near side would eat the subject's edge.
        // Smooth depth (an arm reaching toward the camera) never tears.
        let nearest = erode(d.map { 1 - $0 }, W, H, 3)
        var tear = [Float](repeating: 0, count: N)
        for i in 0..<N { tear[i] = 1 - nearest[i] - d[i] > jump ? 1 : 0 }
        var alpha = box(tear, W, H, 1)
        for i in 0..<N { alpha[i] = 1 - min(1, alpha[i] * 2) }

        // back layer: flat behind the subject. Any rise in it, a step or a ramp, stretches the background
        // into lines along the tilt. So the subject's depth is removed and filled in from the background around it.
        // Subject = as near as the near side of the closest-to-far tear, so everything in front of the background goes.
        let r = max(4, Int((0.06 * longest).rounded()))
        let eroded = erode(d, W, H, r), nearTear = box(tear, W, H, r)
        var subject: Float = 2
        for i in 0..<N where nearTear[i] > 0 && d[i] - eroded[i] > jump { subject = min(subject, d[i]) }
        var dBg = d, behind = [Float](repeating: 0, count: N)
        for i in 0..<N { behind[i] = d[i] < subject ? 1 : 0 }
        fill(&dBg, behind, W, H, 1)

        // hole = near side of a tear, as wide as a tilt can uncover; only there the back layer gets new colours
        var hole = [Float](repeating: 0, count: N)
        for i in 0..<N { hole[i] = nearTear[i] > 0 && d[i] - dBg[i] > jump ? 1 : 0 }
        // grow 3 px past the edge: the outline's faint anti-aliased fringe is repainted too, not left behind
        let grown = box(hole, W, H, 3)
        for i in 0..<N { hole[i] = grown[i] > 0 ? 1 : 0 }

        // the subject's cast shadow is painted on the background, so depth calls it background and it would stay
        // behind as a dark halo. In a band around the hole, repaint pixels darker than the background past the band
        // but of the same colour: a shadow dims the floor without changing its hue, a dark object changes both.
        let band = box(hole, W, H, r)
        var known = [Float](repeating: 0, count: N)
        for i in 0..<N { known[i] = band[i] > 0 ? 0 : 1 }
        var expected = photo.rgb
        fill(&expected, known, W, H, 3)
        var keepBg = [Float](repeating: 0, count: N)
        for i in 0..<N {
            if hole[i] == 0, band[i] > 0 {
                let seen = (0..<3).map { Float(rgba[i * 4 + $0]) }, bare = (0..<3).map { expected[i * 3 + $0] }
                let (sum, bareSum) = (seen.reduce(0, +) + 1, bare.reduce(0, +) + 1)
                // ponytail: fixed thresholds; tune on real photos (darker than 0.9, hue within 0.05)
                let sameHue = (0..<3).allSatisfy { abs(seen[$0] / sum - bare[$0] / bareSum) < 0.05 }
                if sum < bareSum * 0.9, sameHue { hole[i] = 1 }
            }
            keepBg[i] = 1 - hole[i]
        }

        // instant fill of the hole from the surrounding colours
        var rgb = photo.rgb
        fill(&rgb, keepBg, W, H, 3)
        var background = rgba, data = [UInt8](repeating: 255, count: N * 4), mask = [UInt8](repeating: 0, count: N * 4)
        let glow = box(hole, W, H, Int((Float(r) / 3).rounded()))   // soft falloff for the shimmer, not slabs
        // focus: the subject sharp, everything behind it soft like a portrait, so the repainted strip,
        // softer than the photo, blends into the background around it. Feathered 2 px so the outline isn't jagged.
        let focus = box(d.map { $0 >= subject ? 1 : 0 }, W, H, 2)
        for i in 0..<N {
            if hole[i] != 0 { for c in 0..<3 { background[i * 4 + c] = byte(rgb[i * 3 + c]) } }
            data[i * 4 + 3] = byte(focus[i] * 255)
            data[i * 4] = byte(d[i] * 255)
            data[i * 4 + 1] = byte(alpha[i] * 255)
            data[i * 4 + 2] = byte(dBg[i] * 255)
            mask[i * 4] = byte(glow[i] * 255)
        }

        // the hole's bounding box; inpaint adds the context around it
        var (x0, y0, x1, y1) = (W, H, 0, 0)
        for y in 0..<H {
            for x in 0..<W where hole[y * W + x] != 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        var holeBox: (Int, Int, Int, Int)?
        if x1 >= x0 { holeBox = (x0, y0, x1, y1) }
        return Split(layers: SceneLayers(width: W, height: H, photo: rgba, background: background, data: data, mask: mask),
                     hole: hole, glow: glow, holeBox: holeBox)
    }

    /// LaMa repaints the hidden area in overlapping tiles along the hole, at the photo's own resolution.
    /// One square over the whole hole squashed a big subject's surroundings into 512 pixels, and LaMa's
    /// texture came back stretched into lines.
    static func inpaint(_ photo: Photo, _ split: Split, model: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> SceneLayers {
        guard let box = split.holeBox else { return split.layers }
        let (W, H, N, size) = (photo.width, photo.height, photo.width * photo.height, lamaSize)
        let hide = hidden(split, width: W, height: H)

        // tiles of `t` photo pixels, a quarter overlapping; photos over 1536 pixels go in a little smaller
        // so a big one doesn't need dozens of tiles
        let t = min(Int(Float(size) * max(1, Float(max(W, H)) / 1536)), W, H)
        var tiles: [(x: Int, y: Int)] = []
        for y in tileStarts(box.y0, box.y1, H, t) {
            for x in tileStarts(box.x0, box.x1, W, t)
            where (y..<y + t).contains(where: { row in (x..<x + t).contains { split.hole[row * W + $0] != 0 } }) {
                tiles.append((x, y))
            }
        }
        let rgb = photo.rgb
        let squares = tiles.map { tile -> (rgb: [Float], mask: [Float]) in
            let region = (tile.x, tile.y, t, t)
            var mask = resize(hide, W, 1, region: region, to: size, size)
            // when the subject fills most of the tile, LaMa would have nothing to copy from: hide only the edge
            if mask.filter({ $0 > 0 }).count > size * size * 7 / 10 { mask = resize(split.glow, W, 1, region: region, to: size, size) }
            return (resize(rgb, W, 3, region: region, to: size, size), mask.map { $0 > 0 ? 1 : 0 })
        }
        let painted = try lama(squares, model: model, progress: progress)

        // blend the tiles inside the hole, each weighted by its distance from the tile's edge, so no seams show
        var sum = [Float](repeating: 0, count: N * 3), weight = [Float](repeating: 0, count: N)
        for (tile, square) in zip(tiles, painted) {
            let result = resize(square, size, 3, region: (0, 0, size, size), to: t, t)
            for y in 0..<t {
                for x in 0..<t {
                    let i = (y + tile.y) * W + x + tile.x
                    guard split.hole[i] != 0 else { continue }
                    let w = Float(min(x + 1, t - x) * min(y + 1, t - y))
                    weight[i] += w
                    for c in 0..<3 { sum[i * 3 + c] += result[(y * t + x) * 3 + c] * w }
                }
            }
        }
        var layers = split.layers
        for i in 0..<N where weight[i] > 0 {
            for c in 0..<3 { layers.background[i * 4 + c] = byte(sum[i * 3 + c] / weight[i]) }
        }
        return layers
    }

    /// 1 where the inpainting must not look: the whole subject, not just its edge, since LaMa copies what it sees
    /// and should only see background. Subject = as near as the near side of the hole, from the depth the split stored.
    static func hidden(_ split: Split, width W: Int, height H: Int) -> [Float] {
        let depth = { (i: Int) in Float(split.layers.data[i * 4]) / 255 }, back = { (i: Int) in Float(split.layers.data[i * 4 + 2]) / 255 }
        let near = (0..<W * H).filter { split.hole[$0] != 0 && depth($0) - back($0) > jump }.map(depth).min() ?? 2
        var hide = split.glow
        for i in 0..<W * H where depth(i) >= near { hide[i] = 1 }
        return hide
    }

    /// Where tiles `t` wide start so they cover lo…hi of a side `n` long, overlapping by a quarter.
    static func tileStarts(_ lo: Int, _ hi: Int, _ n: Int, _ t: Int) -> [Int] {
        var result: [Int] = [], p = max(0, lo - t / 4)
        while true {
            let start = min(p, n - t)
            result.append(start)
            if start + t > hi || start == n - t { return result }
            p += t * 3 / 4
        }
    }

    /// LaMa on one `lamaSize` square, for Clean Up. `rgb` is 0…255, three per pixel, row by row from the top;
    /// `mask` is 1 where to repaint. Returns the painted square in the same layout.
    static func lama(_ rgb: [Float], mask: [Float], model: URL) throws -> [Float] {
        try lama([(rgb, mask)], model: model)[0]
    }

    /// LaMa on several squares, loading the model once. `model` is `LaMa.compiled`.
    static func lama(_ squares: [(rgb: [Float], mask: [Float])], model: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> [[Float]] {
        let (P, size) = (lamaSize * lamaSize, lamaSize as NSNumber)
        let configuration = MLModelConfiguration()
        // CPU only: the Neural Engine took minutes to prepare LaMa, and the GPU's half precision broke its
        // Fourier layers into purple smears. The CPU computes in full precision.
        // ponytail: slower per tile; try .cpuAndGPU again if a later model ships in full precision
        configuration.computeUnits = .cpuOnly
        let loading = Date.now
        let lama = try MLModel(contentsOf: model, configuration: configuration)
        FileLog.shared.append("TIME", "LaMa loaded in \(loading.secondsSince), \(squares.count) tiles")
        return try squares.enumerated().map { index, square in try autoreleasepool {
            progress("Rebuilding what's hidden behind the edges, \(index + 1) of \(squares.count)…")
            let predicting = Date.now
            defer { FileLog.shared.append("TIME", "LaMa tile \(index + 1) in \(predicting.secondsSince)") }
            // in: RGB 0…1 and the mask, channel by channel; out: RGB 0…1
            let image = try MLMultiArray(shape: [1, 3, size, size], dataType: .float32)
            let mask = try MLMultiArray(shape: [1, 1, size, size], dataType: .float32)
            image.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for i in 0..<P {
                    for c in 0..<3 { buffer[c * P + i] = square.rgb[i * 3 + c] / 255 }
                }
            }
            mask.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for i in 0..<P { buffer[i] = square.mask[i] }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": image, "mask": mask])
            guard let out = try lama.prediction(from: input).featureValue(for: "inpainted_image")?.multiArrayValue else {
                throw CocoaError(.featureUnsupported)
            }
            // Core ML can pad rows, so read through the strides; the output may be half precision
            let strides = out.strides.map(\.intValue), w = lamaSize
            var painted = [Float](repeating: 0, count: 3 * P)
            func read<T: BinaryFloatingPoint & MLShapedArrayScalar>(_ type: T.Type) {
                out.withUnsafeBufferPointer(ofType: T.self) { buffer in
                    for c in 0..<3 {
                        for y in 0..<w {
                            for x in 0..<w {
                                painted[(y * w + x) * 3 + c] = Float(buffer[c * strides[1] + y * strides[2] + x * strides[3]]) * 255
                            }
                        }
                    }
                }
            }
            if out.dataType == .float16 { read(Float16.self) } else { read(Float.self) }
            return painted
        } }
    }

    static func byte(_ value: Float) -> UInt8 { UInt8(min(max(value.rounded(), 0), 255)) }

    private static func clamped(_ value: Int, _ count: Int) -> Int { min(count - 1, max(0, value)) }

    /// Separable box blur with running sums, edges clamped. The sums are Doubles so a 0 stays exactly 0.
    static func box(_ src: [Float], _ W: Int, _ H: Int, _ r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: W * H), out = tmp
        let n = Double(2 * r + 1)
        for y in 0..<H {
            let o = y * W
            var s = 0.0
            for k in -r...r { s += Double(src[o + clamped(k, W)]) }
            for x in 0..<W {
                tmp[o + x] = Float(s / n)
                s += Double(src[o + clamped(x + r + 1, W)]) - Double(src[o + clamped(x - r, W)])
            }
        }
        for x in 0..<W {
            var s = 0.0
            for k in -r...r { s += Double(tmp[clamped(k, H) * W + x]) }
            for y in 0..<H {
                out[y * W + x] = Float(s / n)
                s += Double(tmp[clamped(y + r + 1, H) * W + x]) - Double(tmp[clamped(y - r, H) * W + x])
            }
        }
        return out
    }

    /// Smallest value within r pixels (for depth: the farthest point nearby). van Herk/Gil-Werman, O(N) for any r.
    static func erode(_ src: [Float], _ W: Int, _ H: Int, _ r: Int) -> [Float] {
        let window = 2 * r + 1
        func pass(_ input: [Float], _ output: inout [Float], length n: Int, lines: Int, step: Int, lineStep: Int) {
            var g = [Float](repeating: 0, count: n), h = g
            for line in 0..<lines {
                let o = line * lineStep
                for i in 0..<n {
                    let v = input[o + i * step]
                    g[i] = i % window == 0 ? v : min(g[i - 1], v)
                }
                for i in (0..<n).reversed() {
                    let v = input[o + i * step]
                    h[i] = i % window == window - 1 || i == n - 1 ? v : min(h[i + 1], v)
                }
                for i in 0..<n { output[o + i * step] = min(h[max(0, i - r)], g[min(n - 1, i + r)]) }
            }
        }
        var tmp = [Float](repeating: 0, count: W * H), out = tmp
        pass(src, &tmp, length: W, lines: H, step: 1, lineStep: W)
        pass(tmp, &out, length: H, lines: W, step: W, lineStep: 1)
        return out
    }

    /// Fills pixels where `known` is 0 from the nearest known ones, coarse to fine (push-pull).
    static func fill(_ data: inout [Float], _ known: [Float], _ W: Int, _ H: Int, _ C: Int) {
        if W * H <= 1 { return }
        let (w, h) = ((W + 1) / 2, (H + 1) / 2)
        var d = [Float](repeating: 0, count: w * h * C), k = [Float](repeating: 0, count: w * h)
        for y in 0..<H {
            for x in 0..<W where known[y * W + x] != 0 {
                let i = y * W + x, j = (y >> 1) * w + (x >> 1)
                k[j] += 1
                for c in 0..<C { d[j * C + c] += data[i * C + c] }
            }
        }
        for j in 0..<w * h where k[j] != 0 {
            for c in 0..<C { d[j * C + c] /= k[j] }
            k[j] = 1
        }
        fill(&d, k, w, h, C)
        for y in 0..<H {
            for x in 0..<W where known[y * W + x] == 0 {
                // bilinear sample of the coarser level, so the fill has no blocks
                let fx = min(Float(w - 1), max(0, (Float(x) + 0.5) / 2 - 0.5))
                let fy = min(Float(h - 1), max(0, (Float(y) + 0.5) / 2 - 0.5))
                let (x0, y0) = (Int(fx), Int(fy))
                let (x1, y1, tx, ty) = (min(w - 1, x0 + 1), min(h - 1, y0 + 1), fx - Float(x0), fy - Float(y0))
                let i = y * W + x
                for c in 0..<C {
                    let a = d[(y0 * w + x0) * C + c] * (1 - tx) + d[(y0 * w + x1) * C + c] * tx
                    let b = d[(y1 * w + x0) * C + c] * (1 - tx) + d[(y1 * w + x1) * C + c] * tx
                    data[i * C + c] = a * (1 - ty) + b * ty
                }
            }
        }
    }

    /// Bilinear resize of a region of a `width`-wide map with `channels` values per pixel.
    static func resize(_ src: [Float], _ width: Int, _ channels: Int, region: (x: Int, y: Int, w: Int, h: Int),
                       to dw: Int, _ dh: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dw * dh * channels)
        let (sx, sy) = (Float(region.w) / Float(dw), Float(region.h) / Float(dh))
        for y in 0..<dh {
            let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(region.h - 1))
            let (y0, ty) = (Int(fy), fy - Float(Int(fy)))
            let y1 = min(y0 + 1, region.h - 1)
            for x in 0..<dw {
                let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(region.w - 1))
                let (x0, tx) = (Int(fx), fx - Float(Int(fx)))
                let x1 = min(x0 + 1, region.w - 1)
                for c in 0..<channels {
                    func at(_ px: Int, _ py: Int) -> Float { src[((region.y + py) * width + region.x + px) * channels + c] }
                    let a = at(x0, y0) * (1 - tx) + at(x1, y0) * tx
                    let b = at(x0, y1) * (1 - tx) + at(x1, y1) * tx
                    out[(y * dw + x) * channels + c] = a * (1 - ty) + b * ty
                }
            }
        }
        return out
    }
}

// MARK: - Drawing

/// Two displaced meshes, the back layer and the front one with alpha, drawn with Metal.
struct SpatialCanvas: UIViewRepresentable {
    let scene: SpatialScene
    let reduced: Bool

    func makeCoordinator() -> SpatialRenderer? { SpatialRenderer(scene: scene, reduced: reduced) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

/// Matches `Uniforms` in Spatial.metal.
private struct Uniforms {
    var mvp: simd_float4x4
    var strength: Float
    var rise: Float
    var time: Float
    var scan: Float
    var build: Float
    var reduced: Float
    var front: Float
}

@MainActor
final class SpatialRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let scene: SpatialScene
    private let reduced: Bool
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let indices: MTLBuffer
    private let indexCount: Int
    /// photo, background, data, mask
    private var textures: [MTLTexture] = []
    private var version = -1
    private var aspect: Float = 1
    private let motion = CMMotionManager()
    /// The iPhone's pose when the scene opened; tilt is measured from it.
    private var neutral: CMAttitude?
    private var tilt = SIMD2<Float>.zero
    private var scan: Float = 0
    private var build: Float = 0
    private let start = CACurrentMediaTime()

    init?(scene: SpatialScene, reduced: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "spatialVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "spatialFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        // the front layer's soft edge over the back layer stays opaque, so the ambient doesn't leak through the outline
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = 4
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true

        // a 384 × 384 grid, like the prototype's PlaneGeometry; uv (0, 0) is the photo's top left
        let segments = 384, row = UInt32(segments + 1)
        var uvs: [SIMD2<Float>] = []
        for y in 0...segments {
            for x in 0...segments { uvs.append(SIMD2(Float(x), Float(y)) / Float(segments)) }
        }
        var triangles: [UInt32] = []
        for y in 0..<UInt32(segments) {
            for x in 0..<UInt32(segments) {
                let a = y * row + x
                triangles += [a, a + 1, a + row, a + 1, a + row + 1, a + row]
            }
        }
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let depthState = device.makeDepthStencilState(descriptor: depth),
              let vertices = device.makeBuffer(bytes: uvs, length: uvs.count * MemoryLayout<SIMD2<Float>>.stride),
              let indices = device.makeBuffer(bytes: triangles, length: triangles.count * 4) else { return nil }
        self.device = device
        self.scene = scene
        self.reduced = reduced
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.vertices = vertices
        self.indices = indices
        indexCount = triangles.count
        super.init()
        if !reduced, motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates()
        }
    }

    // on the main actor, where `motion` lives
    isolated deinit { motion.stopDeviceMotionUpdates() }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        if scene.version != version, let layers = scene.layers {
            textures = [(layers.photo, true), (layers.background, true), (layers.data, false), (layers.mask, false)]
                .compactMap { texture($0.0, layers.width, layers.height, mipmapped: $0.1) }
            aspect = Float(layers.width) / Float(layers.height)
            version = scene.version
        }
        guard textures.count == 4, view.drawableSize.height > 0, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let now = CACurrentMediaTime(), time = Float(now - start)
        // eased toward their goals, so the effects fade instead of popping
        scan += (scene.scanGoal - scan) * 0.06
        build += (scene.buildGoal - build) * 0.04
        let rise = scene.riseStart.map { 1 - pow(2, -10 * min(1, Float(now - $0) / (reduced ? 0.3 : 1.6))) } ?? 0

        // the first reading is the neutral pose; ±20° is a full swing
        var target = scene.drag
        // roll and pitch measured from the floor break down when the iPhone is held upright (gimbal lock),
        // so take the rotation since the scene opened: it stays small, and small angles are always stable
        // a copy: multiply changes it in place, and the same reading can reach two frames
        if let attitude = motion.deviceMotion?.attitude.copy() as? CMAttitude {
            if let neutral { attitude.multiply(byInverseOf: neutral) } else { neutral = attitude.copy() as? CMAttitude }
            target += SIMD2(Float(attitude.roll), Float(attitude.pitch)) / (20 * .pi / 180)
        }
        tilt += (simd_clamp(target, SIMD2(repeating: -1), SIMD2(repeating: 1)) - tilt) * 0.08
        // while rebuilding, the camera sways on its own so the 3D shows without touching anything
        let sway = reduced ? 0 : build
        let cx = tilt.x + sin(time * 0.7) * 0.6 * sway, cy = tilt.y + sin(time * 0.5) * 0.3 * sway

        // the whole photo, the same size as the flat one, and the frame stays still, as in Photos: no camera turn,
        // each point slides by its depth instead (near = more), so the subject moves over a background that barely moves
        let viewAspect = Float(view.drawableSize.width / view.drawableSize.height)
        let fx = min(1, aspect / viewAspect), fy = min(1, viewAspect / aspect)
        // ponytail: 0.4 = how far a full tilt slides the nearest point (0.1 of the screen at strength 0.25)
        let slide = -SIMD2(cx, cy) * 0.4
        // z: nearer is smaller, so the subject wins the depth test over the back layer
        let mvp = simd_float4x4(columns: (SIMD4(2 * fx, 0, 0, 0), SIMD4(0, 2 * fy, 0, 0),
                                          SIMD4(slide.x, slide.y, -1, 0), SIMD4(0, 0, 0.5, 1)))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexTexture(textures[2], index: 0)
        encoder.setFragmentTexture(textures[2], index: 1)
        encoder.setFragmentTexture(textures[3], index: 2)
        for front in [false, true] {
            var uniforms = Uniforms(mvp: mvp, strength: 0.25, rise: rise, time: time, scan: scan, build: build,
                                    reduced: reduced ? 1 : 0, front: front ? 1 : 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(textures[front ? 0 : 1], index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// `mipmapped`: smaller copies too, which the shader reads for the soft background.
    private func texture(_ bytes: [UInt8], _ width: Int, _ height: Int, mipmapped: Bool) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        if mipmapped, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }
}
