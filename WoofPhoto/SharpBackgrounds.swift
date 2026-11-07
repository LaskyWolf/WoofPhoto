import CoreGraphics
import Foundation
import GuernikaKit
import os
import SwiftUI
import ZIPFoundation

/// Stable Diffusion inpainting for the background a Spatial Scene uncovers: it draws new detail where LaMa
/// only averages the colours around, so busy backgrounds stay sharp. An opt-in 2 GB download.
@MainActor @Observable
final class SharpBackgrounds {
    static let shared = SharpBackgrounds()

    /// Runway's SD 1.5 inpainting, converted by Guernika for the Neural Engine, its UNet split in two for the iPhone.
    private static let url = URL(string: "https://huggingface.co/Guernika/CoreMLStableDiffusion/resolve/main/Models/SPLIT_EINSUM/Runway_SD1.5_Inpaint_chunked.zip")!
    /// Application Support, not Caches: iOS empties Caches when space runs low, and this is 2 GB to fetch again.
    private static let parent = URL.applicationSupportDirectory.appending(path: "Models")
    nonisolated static let folder = parent.appending(path: "Runway_SD1.5_Inpaint_chunked")
    /// The download plus the unzipped copy, both on disk for a moment.
    private static let spaceNeeded: Int64 = 4_500_000_000

    /// The UNet alone is 1.7 GB; under 6 GB of RAM iOS would close the app. A 6 GB iPhone reports a little less.
    static var isSupported: Bool { ProcessInfo.processInfo.physicalMemory >= 5_500_000_000 }

    private(set) var isReady = FileManager.default.fileExists(atPath: folder.appending(path: "guernika.json").path)
    /// 0…1 while downloading and unzipping.
    private(set) var progress: Double?
    var error: String?

    func download() async {
        guard progress == nil else { return }
        let free = (try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= Self.spaceNeeded else {
            error = "This needs about 4.5 GB free while it installs. Free up some space and try again."
            return
        }
        progress = 0
        defer { progress = nil }
        do {
            // ponytail: a foreground download, so WoofPhoto has to stay open; a background URLSession if that's a bother
            let zip = URL.temporaryDirectory.appending(path: "sharp-backgrounds.zip")
            try await Download.run(Self.url, to: zip) { value in
                Task { @MainActor in SharpBackgrounds.shared.progress = value * 0.9 }
            }
            defer { try? FileManager.default.removeItem(at: zip) }
            try await Task.detached {
                try FileManager.default.createDirectory(at: Self.parent, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: Self.folder)
                try FileManager.default.unzipItem(at: zip, to: Self.parent)
                // not in iCloud backups: it can always be downloaded again
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var parent = Self.parent
                try parent.setResourceValues(values)
            }.value
            progress = 1
            isReady = FileManager.default.fileExists(atPath: Self.folder.appending(path: "guernika.json").path)
            if !isReady { error = "The download finished but the model is incomplete. Try again." }
        } catch {
            self.error = error.explanation
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.folder)
        isReady = false
    }

    /// A download task on its own session: the async `download(from:delegate:)` never reports progress,
    /// so the bar sat at the start for the whole 2 GB.
    private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let report: @Sendable (Double) -> Void
        private let finished: (Result<Void, Error>) -> Void

        private init(destination: URL, report: @escaping @Sendable (Double) -> Void, finished: @escaping (Result<Void, Error>) -> Void) {
            self.destination = destination
            self.report = report
            self.finished = finished
        }

        static func run(_ url: URL, to destination: URL, report: @escaping @Sendable (Double) -> Void) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = Download(destination: destination, report: report) { continuation.resume(with: $0) }
                // the session keeps its delegate until it's invalidated, so it lives as long as the download
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                session.downloadTask(with: url).resume()
                session.finishTasksAndInvalidate()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        // the file is deleted when this returns, so it moves here
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                    throw URLError(.badServerResponse)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finished(.success(()))
            } catch {
                finished(.failure(error))
            }
        }

        // errors only: a finished download already resumed above
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finished(.failure(error)) }
        }
    }
}

extension Spatial {
    /// Stable Diffusion repaints the hole in a few squares along it, each as wide as the hole's short side,
    /// shown to SD with the whole subject hidden. `report(done, total)` follows the squares;
    /// `cancelled` stops between steps.
    static func sharpen(_ photo: Photo, _ split: Split, layers: SceneLayers, cancelled: OSAllocatedUnfairLock<Bool>,
                        report: @escaping @Sendable (Int, Int) -> Void) throws -> SceneLayers {
        guard let box = split.holeBox else { return layers }
        let (W, H, N, size) = (photo.width, photo.height, photo.width * photo.height, 512)
        // a quarter of room around the hole, so SD sees the background it continues
        let padX = (box.x1 - box.x0) / 4, padY = (box.y1 - box.y0) / 4
        let (x0, y0) = (max(0, box.x0 - padX), max(0, box.y0 - padY))
        let (x1, y1) = (min(W - 1, box.x1 + padX), min(H - 1, box.y1 + padY))
        let t = max(64, min(x1 - x0 + 1, y1 - y0 + 1))
        var tiles: [(x: Int, y: Int)] = []
        for y in tileStarts(y0, y1, H, t) {
            for x in tileStarts(x0, x1, W, t) { tiles.append((x, y)) }
        }

        guard let pipeline = try GuernikaKit.load(at: SharpBackgrounds.folder) as? StableDiffusionMainPipeline else {
            throw CocoaError(.featureUnsupported)
        }
        pipeline.reduceMemory = true
        pipeline.disableSafety = true
        defer { pipeline.unloadResources() }

        let hide = hidden(split, width: W, height: H)
        let rgb = photo.rgb
        var sum = [Float](repeating: 0, count: N * 3), weight = [Float](repeating: 0, count: N)
        for (k, tile) in tiles.enumerated() {
            report(k, tiles.count)
            let region = (tile.x, tile.y, t, t)
            guard let image = cgImage(resize(rgb, W, 3, region: region, to: size, size), alpha: nil, size: size),
                  let mask = cgImage(nil, alpha: resize(hide, W, 1, region: region, to: size, size), size: size) else {
                throw CocoaError(.featureUnsupported)
            }
            let input = SampleInput(
                prompt: "background scenery only, seamless continuation, same art style and colours, detailed, sharp",
                negativePrompt: "character, person, animal, body, face, hands, text, watermark, blurry, frame",
                initImage: image, inpaintMask: mask, strength: 1, seed: 7, stepCount: 20)
            guard let painted = try pipeline.generateImages(input: input, progressHandler: { _ in !cancelled.withLock { $0 } }),
                  !cancelled.withLock({ $0 }) else { throw CancellationError() }
            let result = resize(floats(painted, size: size), size, 3, region: (0, 0, size, size), to: t, t)
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
        var layers = layers
        for i in 0..<N where weight[i] > 0 {
            for c in 0..<3 { layers.background[i * 4 + c] = byte(sum[i * 3 + c] / weight[i]) }
        }
        return layers
    }

    /// A `size` square as a CGImage: colours from `rgb` (0…255, three per pixel) or black, opacity from `alpha` (1 where
    /// SD repaints) or opaque.
    private static func cgImage(_ rgb: [Float]?, alpha: [Float]?, size: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<size * size {
            for c in 0..<3 { bytes[i * 4 + c] = rgb.map { byte($0[i * 3 + c]) } ?? 0 }
            if let alpha { bytes[i * 4 + 3] = alpha[i] > 0 ? 255 : 0 }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = alpha == nil ? CGImageAlphaInfo.noneSkipLast : .last
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// SD's result as 0…255 floats, three per pixel.
    private static func floats(_ image: CGImage, size: Int) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        var rgb = [Float](repeating: 0, count: size * size * 3)
        for i in 0..<size * size {
            for c in 0..<3 { rgb[i * 3 + c] = Float(bytes[i * 4 + c]) }
        }
        return rgb
    }
}

/// Settings → Library & Viewer: download or remove the model.
struct SharpBackgroundsSettings: View {
    @State private var model = SharpBackgrounds.shared

    var body: some View {
        if SharpBackgrounds.isSupported {
            Section {
                if let progress = model.progress {
                    ProgressView(value: progress) { Label("Downloading…", systemImage: "sparkles") }
                } else if model.isReady {
                    Label("Sharper Backgrounds On", systemImage: "sparkles")
                    Button("Remove (frees 2.1 GB)", role: .destructive) { model.remove() }
                } else {
                    Button { Task { await model.download() } } label: {
                        Label("Download Sharper Backgrounds (2 GB)", systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text("Spatial Scenes")
            } footer: {
                Text("Stable Diffusion repaints what's hidden behind the subject with real detail instead of a soft blur. It runs on this iPhone and adds up to a minute per new scene. Keep WoofPhoto open while it downloads.")
            }
            .messageAlert($model.error)
        }
    }
}
