import CoreMotion
import MetalKit
import OnnxRuntimeBindings
import SwiftUI
import os
import simd

// Spatial Scenes: a port of prototype/spatial/index.html. The photo is split into a front layer and a
// back layer at their own depths; tilting the iPhone moves the camera around them.

/// The photo full screen as a Spatial Scene, opened from the viewer's tool card.
struct SpatialView: View {
    let asset: AssetRef
    let onClose: () -> Void

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
            .overlay(alignment: .topLeading) {
                // the whole circle takes the tap: a frame outside the label left only the glyph tappable,
                // and taps around it went to the tilt drag underneath
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close Spatial Scene")
                .padding()
            }
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
    /// R = front depth, G = front alpha, B = back depth; 255 is near.
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
            let split = await Task.detached { Spatial.split(photo, depth: raw) }.value
            try Task.checkCancellation()
            show(split.layers)
            scanGoal = 0
            riseStart = CACurrentMediaTime()
            guard split.holeBox != nil else {
                status = nil
                SpatialCache.write(split.layers, id: asset.id)
                return
            }
            // LaMa peaked at about 490 MB in the M0 spike; with less free memory iOS would close the app
            guard os_proc_available_memory() > 700 << 20 else {
                status = "Not enough free memory to rebuild the background, so it's filled from the edges."
                return
            }
            buildGoal = 1
            status = "Depth ready in \(started.secondsSince). Rebuilding what's hidden behind the edges…"
            let lama = try await AIModel.lama.download()
            // closed while depth ran: don't start the 500 MB model for a scene nobody sees
            try Task.checkCancellation()
            let filled = try await Task.detached { try Spatial.inpaint(photo, split, model: lama) }.value
            try Task.checkCancellation()
            show(filled)
            buildGoal = 0
            status = nil
            SpatialCache.write(filled, id: asset.id)
        } catch is CancellationError {
        } catch {
            buildGoal = 0
            scanGoal = 0
            status = "Couldn't build the scene: \(error.localizedDescription)"
        }
    }
}

private extension Date {
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
    static let lama = AIModel(url: URL(string: "https://huggingface.co/opencv/inpainting_lama/resolve/main/inpainting_lama_2025jan.onnx")!)

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

    /// Runs the model once and releases it, so only one model is in memory at a time.
    static func run(_ file: URL, inputs: [String: (values: [Float], shape: [Int])], output: String) throws -> (values: [Float], shape: [Int]) {
        try autoreleasepool {
            let env = try ORTEnv(loggingLevel: .warning)
            // ponytail: CPU only; onnxruntime 1.20's Core ML recompiles on every run and lacks LaMa's FFT, try again on a newer onnxruntime
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(ProcessInfo.processInfo.activeProcessorCount))
            let session = try ORTSession(env: env, modelPath: file.path, sessionOptions: options)
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
        }
    }
}

/// Saves the finished back layer and depth per asset, so a scene is built only once.
/// ponytail: no size limit; iOS empties Caches when the iPhone runs low on space.
enum SpatialCache {
    /// Bump when the models or the split change, so old scenes are built again.
    private static let folder = "spatial-2"
    private static func file(_ id: String) -> URL {
        URL.cachesDirectory.appending(path: "\(folder)/\(id.replacingOccurrences(of: "/", with: "_")).scene")
    }
    /// Scenes from older versions; deleted once per launch, on the first save.
    private static let dropOld: Void = { try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "spatial")) }()

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

    struct Split: Sendable {
        var layers: SceneLayers
        /// 1 where the back layer gets new colours.
        var hole: [Float]
        var glow: [Float]
        /// x0, y0, x1, y1 of the hole, padded; nil when there are no sharp depth edges.
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

    static func split(_ photo: Photo, depth raw: [Float]) -> Split {
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

        // tears: pixels clearly farther than something 3 px away, i.e. the FAR side of a sharp depth jump.
        // The depth map is blurrier than the photo, so tearing the near side would eat the subject's edge.
        // Smooth depth (an arm reaching toward the camera) never tears.
        let nearest = erode(d.map { 1 - $0 }, W, H, 3)
        var tear = [Float](repeating: 0, count: N)
        for i in 0..<N { tear[i] = 1 - nearest[i] - d[i] > jump ? 1 : 0 }
        var alpha = box(tear, W, H, 1)
        for i in 0..<N { alpha[i] = 1 - min(1, alpha[i] * 2) }

        // back layer: the farthest depth within the widest parallax shift, so it always sits behind
        let r = max(4, Int((0.06 * longest).rounded()))
        let dBg = erode(d, W, H, r)

        // hole = near side of a tear, as wide as a tilt can uncover; only there the back layer gets new colours
        let nearTear = box(tear, W, H, r)
        var hole = [Float](repeating: 0, count: N)
        for i in 0..<N { hole[i] = nearTear[i] > 0 && d[i] - dBg[i] > jump ? 1 : 0 }
        // grow 3 px past the edge: the outline's faint anti-aliased fringe is repainted too, not left behind
        let grown = box(hole, W, H, 3)
        for i in 0..<N { hole[i] = grown[i] > 0 ? 1 : 0 }

        // the subject's cast shadow is painted on the background, so depth calls it background and it would stay
        // behind as a dark halo. In a band around the hole, repaint pixels darker than the background past the band
        // but of the same colour: a shadow dims the floor without changing its hue, a dark object changes both.
        let S = max(4, Int((0.06 * longest).rounded()))
        let band = box(hole, W, H, S)
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
        for i in 0..<N {
            if hole[i] != 0 { for c in 0..<3 { background[i * 4 + c] = byte(rgb[i * 3 + c]) } }
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

    /// LaMa repaints the hidden area; only a square around the hole goes in, so its 512 pixels go where they matter.
    static func inpaint(_ photo: Photo, _ split: Split, model: URL) throws -> SceneLayers {
        guard let box = split.holeBox else { return split.layers }
        let (W, H, size) = (photo.width, photo.height, lamaSize)
        // a square around the hole, half again as wide, so LaMa sees real background around it and nothing is stretched
        let side = (max(box.x1 - box.x0, box.y1 - box.y0) + 1) * 3 / 2
        let (cw, ch) = (min(side, W), min(side, H))
        let x0 = min(max(0, (box.x0 + box.x1 - cw) / 2), W - cw), y0 = min(max(0, (box.y0 + box.y1 - ch) / 2), H - ch)
        // hide the whole subject, not just its edge: LaMa copies what it sees, and it should only see background.
        // Subject = as near as the nearest-side of the hole, read from the depth the split stored.
        let depth = { (i: Int) in Float(split.layers.data[i * 4]) / 255 }, back = { (i: Int) in Float(split.layers.data[i * 4 + 2]) / 255 }
        let near = (0..<W * H).filter { split.hole[$0] != 0 && depth($0) - back($0) > jump }.map(depth).min() ?? 2
        var hide = split.glow
        for i in 0..<W * H where depth(i) >= near { hide[i] = 1 }
        let crop = resize(photo.rgb, W, 3, region: (x0, y0, cw, ch), to: size, size)
        var maskCrop = resize(hide, W, 1, region: (x0, y0, cw, ch), to: size, size)
        // when the subject fills most of the square, LaMa would have nothing to copy from: hide only the edge, as before
        if maskCrop.filter({ $0 > 0 }).count > size * size * 7 / 10 {
            maskCrop = resize(split.glow, W, 1, region: (x0, y0, cw, ch), to: size, size)
        }
        let painted = try lama(crop, mask: maskCrop.map { $0 > 0 ? Float(1) : 0 }, model: model)
        let result = resize(painted, size, 3, region: (0, 0, size, size), to: cw, ch)
        // paste LaMa's result back, only inside the hole
        var layers = split.layers
        for y in 0..<ch {
            for x in 0..<cw {
                let i = (y + y0) * W + x + x0
                guard split.hole[i] != 0 else { continue }
                for c in 0..<3 { layers.background[i * 4 + c] = byte(result[(y * cw + x) * 3 + c]) }
            }
        }
        return layers
    }

    /// LaMa on one `lamaSize` square, shared with Clean Up. `rgb` is 0…255, three per pixel, row by row from the top;
    /// `mask` is 1 where to repaint. Returns the painted square in the same layout.
    static func lama(_ rgb: [Float], mask: [Float], model: URL) throws -> [Float] {
        let (P, size) = (lamaSize * lamaSize, lamaSize)
        var image = [Float](repeating: 0, count: 3 * P)
        for i in 0..<P {
            for c in 0..<3 { image[c * P + i] = rgb[i * 3 + c] / 255 }
        }
        let out = try AIModel.run(model, inputs: ["image": (image, [1, 3, size, size]), "mask": (mask, [1, 1, size, size])],
                                  output: "output").values
        var painted = [Float](repeating: 0, count: 3 * P)
        for i in 0..<P {
            for c in 0..<3 { painted[i * 3 + c] = out[c * P + i] }
        }
        return painted
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

    private static let distance: Float = 3
    private static let fieldOfView: Float = 40 * .pi / 180

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
            textures = [layers.photo, layers.background, layers.data, layers.mask].compactMap { texture($0, layers.width, layers.height) }
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
        let orbit: Float = 0.25, d = Self.distance
        let eye = SIMD3(sin(cx * orbit) * d, sin(cy * orbit) * d, cos(cx * orbit) * cos(cy * orbit) * d)

        let viewAspect = Float(view.drawableSize.width / view.drawableSize.height)
        // the whole picture, shrunk 10% so it stays on screen while the camera orbits
        let viewHeight = 2 * d * tan(Self.fieldOfView / 2)
        let s = min(viewHeight * viewAspect / aspect, viewHeight) * 0.9
        let mvp = perspective(aspect: viewAspect) * lookAt(eye) * simd_float4x4(diagonal: SIMD4(s * aspect, s, s, 1))

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

    private func texture(_ bytes: [UInt8], _ width: Int, _ height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        bytes.withUnsafeBytes {
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// Right-handed, depth 0…1 as Metal expects.
    private func perspective(aspect: Float, near: Float = 0.1, far: Float = 100) -> simd_float4x4 {
        let y = 1 / tan(Self.fieldOfView / 2), z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(y / aspect, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// The camera at `eye`, looking at the middle of the photo, slightly in front of it like the prototype.
    private func lookAt(_ eye: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(SIMD3(0, 0, 0.1) - eye)
        let s = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}
