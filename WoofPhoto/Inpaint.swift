import CoreML
import CryptoKit
import SwiftUI
import os

// What Clean Up needs to run LaMa: the photo at the working size, the model download and the LaMa call.

extension Date {
    var secondsSince: String { (Date.now.timeIntervalSince(self)).formatted(.number.precision(.fractionLength(1))) + " s" }
}

/// The photo at the working size: 1280 pixels on the longest side.
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
}

/// A Core ML model downloaded once as the three files of its .mlpackage, from a pinned commit, each checked
/// by SHA-256, compiled on the iPhone, and kept loaded while the app runs, so the next use starts at once.
struct CoreMLModel: Sendable {
    /// The compiled model's name in Caches/models.
    let name: String
    let base: URL
    let parts: [(path: String, sha256: String)]
    let computeUnits: MLComputeUnits

    /// Big LaMa in half precision (fp16, 100 MB). A 6-bit LaMa (40 MB) painted the hole purple: 6-bit weights shift its colours.
    /// CPU only: the Neural Engine took minutes to prepare LaMa, and the CPU computes in full precision.
    /// ponytail: slower per tile; try .cpuAndGPU and compare the colours if tiles take too long
    static let lama = CoreMLModel(
        name: "LaMa-fp16",
        base: URL(string: "https://huggingface.co/heypatkay/solume-big-lama-coreml/resolve/c4358e4356b4c576a7fbfaabf27b5ffd5d9d7758/lama/LaMa512.mlpackage/")!,
        parts: [
            ("Manifest.json", "a2576a37183e5a04265456092e18271e165564bd2e6578f6091e404236f3069b"),
            ("Data/com.apple.CoreML/model.mlmodel", "a50e4ed35d3588892615046a111d274451ee83d29e854175fc91acc1361ffdd1"),
            ("Data/com.apple.CoreML/weights/weight.bin", "4db509018e12aec710ab28d8ac1a88812665decf7511e538666590db3e5c88fb"),
        ],
        computeUnits: .cpuOnly)

    /// The compiled model; it exists once downloaded.
    var compiled: URL { URL.cachesDirectory.appending(path: "models/\(name).mlmodelc") }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    func download() async throws -> URL {
        let compiled = compiled
        if isDownloaded { return compiled }
        let started = Date.now
        let package = FileManager.default.temporaryDirectory.appending(path: "\(name).mlpackage")
        try? FileManager.default.removeItem(at: package)
        defer { try? FileManager.default.removeItem(at: package) }
        for (part, sha256) in parts {
            let (temp, response) = try await URLSession.shared.download(from: base.appending(path: part))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let digest = SHA256.hash(data: try Data(contentsOf: temp, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == sha256 else { throw URLError(.cannotDecodeContentData) }
            let file = package.appending(path: part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: file)
        }
        FileLog.shared.append("TIME", "\(name) downloaded in \(started.secondsSince)")
        let compiling = Date.now
        let built = try await MLModel.compileModel(at: package)
        FileLog.shared.append("TIME", "\(name) compiled in \(compiling.secondsSince)")
        try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: built, to: compiled)
        return compiled
    }

    // ponytail: one lock for every model; the loads it guards are rare
    nonisolated(unsafe) private static var loaded: [String: MLModel] = [:]
    private static let lock = NSLock()
    /// iOS asks for memory back: drop the loaded models, the next scene loads them again.
    nonisolated(unsafe) private static var memoryWarning: NSObjectProtocol?

    /// The downloaded model, loaded on first use and kept.
    func load() throws -> MLModel {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let model = Self.loaded[name] { return model }
        if Self.memoryWarning == nil {
            Self.memoryWarning = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
                    Self.lock.lock()
                    Self.loaded = [:]
                    Self.lock.unlock()
                }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let loading = Date.now
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        FileLog.shared.append("TIME", "\(name) loaded in \(loading.secondsSince)")
        Self.loaded[name] = model
        return model
    }
}

/// LaMa for Clean Up.
enum Inpaint {
    /// LaMa's fixed input size.
    static let lamaSize = 512
    /// Free memory LaMa needs; its card lists a peak of about 600 MB.
    static var lamaFits: Bool { os_proc_available_memory() > 700 << 20 }

    /// LaMa on one `lamaSize` square, for Clean Up. `rgb` is 0…255, three per pixel, row by row from the top;
    /// `mask` is 1 where to repaint. Returns the painted square in the same layout.
    static func lama(_ rgb: [Float], mask: [Float], model: MLModel) throws -> [Float] {
        try lama([(rgb, mask)], model: model)[0]
    }

    /// LaMa on several squares. `model` is `CoreMLModel.lama`, loaded.
    static func lama(_ squares: [(rgb: [Float], mask: [Float])], model lama: MLModel, progress: @Sendable (String) -> Void = { _ in }) throws -> [[Float]] {
        let (P, size) = (lamaSize * lamaSize, lamaSize as NSNumber)
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
            guard let out = try lama.prediction(from: input).featureValue(for: "result")?.multiArrayValue else {
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
}
