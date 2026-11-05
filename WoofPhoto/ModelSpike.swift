import SwiftUI
import OnnxRuntimeBindings
import os

/// M0 spike: time and peak memory of the two Spatial Scenes models on this iPhone.
/// They are the same ONNX files the web prototype uses; the input is noise, which costs the same as a photo.
struct ModelSpike: View {
    @State private var results: [String: String] = [:]
    @State private var running: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Device RAM", value: bytes(ProcessInfo.processInfo.physicalMemory))
                LabeledContent("Available to the App", value: bytes(UInt64(os_proc_available_memory())))
            } footer: {
                Text("iOS closes the app when its memory reaches about the available amount.")
            }
            ForEach(SpikeModel.all, id: \.name) { model in
                Section {
                    LabeledContent("Result", value: results[model.name] ?? "Not run")
                    Button(running == model.name ? "Running…" : "Download and Run") {
                        Task { await run(model) }
                    }
                    .disabled(running != nil)
                } header: {
                    Text(model.name)
                } footer: {
                    Text(model.note)
                }
            }
        }
        .navigationTitle("AI Models")
    }

    private func run(_ model: SpikeModel) async {
        running = model.name
        defer { running = nil }
        do {
            results[model.name] = "Downloading \(model.size)…"
            let file = try await model.download()
            results[model.name] = "Running…"
            let sampler = PeakMemory()
            let before = PeakMemory.footprint()
            let (load, inference) = try await Task.detached { try model.run(file) }.value
            let peak = sampler.stop()
            results[model.name] = String(format: "Load %.1f s, run %.1f s, peak %@ (%@ before)", load, inference, bytes(peak), bytes(before))
        } catch {
            results[model.name] = "Failed: \(error.localizedDescription)"
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

struct SpikeModel: Sendable {
    var name: String
    var note: String
    var size: String
    var url: URL
    var inputs: [(name: String, shape: [Int])]
    var output: String

    static let all = [
        SpikeModel(
            name: "Depth Anything V2 Small (q8)",
            note: "Desktop, 4 threads: 0.6 s, about 300 MB.",
            size: "26 MB",
            url: URL(string: "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/model_quantized.onnx")!,
            inputs: [("pixel_values", [1, 3, 518, 518])],
            output: "predicted_depth"
        ),
        SpikeModel(
            name: "LaMa inpainting",
            note: "Desktop, 4 threads: 3.8 s, about 600 MB.",
            size: "92 MB",
            url: URL(string: "https://huggingface.co/opencv/inpainting_lama/resolve/main/inpainting_lama_2025jan.onnx")!,
            inputs: [("image", [1, 3, 512, 512]), ("mask", [1, 1, 512, 512])],
            output: "output"
        ),
    ]

    /// Kept in Caches, so a second run measures the model, not the download.
    func download() async throws -> URL {
        let folder = URL.cachesDirectory.appending(path: "models")
        let file = folder.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let (temp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }

    /// Returns load and run time in seconds. The session is released when this returns.
    func run(_ file: URL) throws -> (Double, Double) {
        try autoreleasepool {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(ProcessInfo.processInfo.activeProcessorCount))
            var start = Date.now
            let session = try ORTSession(env: env, modelPath: file.path, sessionOptions: options)
            let load = Date.now.timeIntervalSince(start)

            var feeds: [String: ORTValue] = [:]
            for input in inputs {
                let count = input.shape.reduce(1, *)
                // the mask must be 0 or 1; half of it marks a hole, like a real tear
                let values = (0..<count).map { input.name == "mask" ? Float($0 % 2) : Float.random(in: 0...1) }
                let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: count * 4) }
                feeds[input.name] = try ORTValue(tensorData: data, elementType: .float, shape: input.shape.map { NSNumber(value: $0) })
            }
            start = .now
            _ = try session.run(withInputs: feeds, outputNames: [output], runOptions: nil)
            return (load, Date.now.timeIntervalSince(start))
        }
    }
}

/// Samples the app's memory footprint every 20 ms and keeps the highest value.
final class PeakMemory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "peak-memory")
    private let timer: DispatchSourceTimer
    private var peak: UInt64 = 0   // only touched on `queue`

    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            peak = max(peak, Self.footprint())
        }
        timer.resume()
    }

    func stop() -> UInt64 {
        timer.cancel()
        return queue.sync { max(peak, Self.footprint()) }
    }

    /// The number iOS compares with the memory limit (what Xcode's memory gauge shows).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
