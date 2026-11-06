import BackgroundTasks
import CryptoKit
import Photos
import SwiftUI

/// Uploads photos and videos from the iPhone to Immich, skipping what the server already has (same SHA-1).
/// Runs while the app is open, and in a background task that iOS starts when it decides to (more often while charging).
@MainActor @Observable
final class Backup {
    static let shared = Backup()
    static let taskID = "com.laskywolf.woofphoto.backup"

    enum State: Equatable {
        case idle, scanning, waiting(String), uploading(done: Int, total: Int), finished, failed(String)
    }

    var enabled = UserDefaults.standard.bool(forKey: "backup.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "backup.enabled") }
    }
    var wifiOnly = UserDefaults.standard.object(forKey: "backup.wifiOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: "backup.wifiOnly") }
    }
    var chargingOnly = UserDefaults.standard.bool(forKey: "backup.chargingOnly") {
        didSet { UserDefaults.standard.set(chargingOnly, forKey: "backup.chargingOnly") }
    }
    /// Device albums to back up; empty means every photo and video.
    var albumIDs = UserDefaults.standard.stringArray(forKey: "backup.albums") ?? [] {
        didSet { UserDefaults.standard.set(albumIDs, forKey: "backup.albums") }
    }

    private(set) var state = State.idle
    private(set) var current: String?
    private(set) var errors: [String] = []
    /// Device assets not on the server yet, newest first.
    private(set) var pending: [PHAsset] = []
    /// The same, as grid items grouped by timeline month ("2024-05-01").
    private(set) var pendingByMonth: [String: [AssetRef]] = [:]
    /// Device asset id → server asset id, for everything uploaded or found on the server.
    private var uploaded: [String: String]
    private var task: Task<Void, Never>?

    private static let recordURL = URL.applicationSupportDirectory.appending(path: "backup.json")

    private init() {
        uploaded = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.recordURL))) ?? [:]
    }

    var isRunning: Bool { task != nil }
    var backedUpCount: Int { uploaded.count }

    /// Asks for access to the photo library once; false when the user said no.
    func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Finds device assets that aren't backed up. Cheap: compares ids, doesn't read files.
    func refreshPending() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else { return }
        var assets: [PHAsset] = []
        var seen = Set<String>()
        for fetch in fetches() {
            fetch.enumerateObjects { asset, _, _ in
                if !self.uploaded.keys.contains(asset.localIdentifier), seen.insert(asset.localIdentifier).inserted {
                    assets.append(asset)
                }
            }
        }
        pending = assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        var months: [String: [AssetRef]] = [:]
        for asset in pending {
            months[monthKey(asset), default: []].append(AssetRef(device: asset))
        }
        pendingByMonth = months
    }

    func start(with client: ImmichClient) {
        guard task == nil else { return }
        task = Task {
            await run(client)
            task = nil
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Schedules the next background run; iOS picks the time.
    func scheduleBackground() {
        guard enabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = chargingOnly
        try? BGTaskScheduler.shared.submit(request)
    }

    private func run(_ client: ImmichClient) async {
        guard await authorize() else {
            state = .failed("WoofPhoto can't see your photos. Allow access in Settings > Privacy & Security > Photos.")
            return
        }
        state = .scanning
        errors = []
        refreshPending()
        let total = pending.count
        UIDevice.current.isBatteryMonitoringEnabled = true
        for (done, asset) in pending.reversed().enumerated() {
            if Task.isCancelled { break }
            if chargingOnly, ![.charging, .full].contains(UIDevice.current.batteryState) {
                state = .waiting("Waiting for the iPhone to charge.")
                return
            }
            state = .uploading(done: done, total: total)
            current = asset.localIdentifier
            do {
                try await upload(asset, client: client)
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
                state = .waiting(wifiOnly ? "Waiting for Wi-Fi." : "Waiting for a connection.")
                return
            } catch {
                errors.append("\(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "An item"): \(error.explanation)")
            }
        }
        current = nil
        refreshPending()
        state = Task.isCancelled ? .idle : .finished
    }

    private func upload(_ asset: PHAsset, client: ImmichClient) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let main = resources.first(where: { [.photo, .video].contains($0.type) }) ?? resources.first else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "backup/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = try await export(main, to: folder)
        let checksum = try Self.sha1(file)
        let check: UploadCheck = try await client.fetch("POST", "/assets/bulk-upload-check",
                                                        body: ["assets": [["id": asset.localIdentifier, "checksum": checksum]]])
        if let result = check.results.first, result.action == "reject" {
            remember(asset, server: result.assetId ?? "")
            return
        }
        var videoID: String?
        if let paired = resources.first(where: { $0.type == .pairedVideo }) {
            // the moving part of a Live Photo goes up first, hidden, and the photo points to it
            videoID = try await send(try await export(paired, to: folder), of: asset, client: client, extra: ["visibility": "hidden"])
        }
        let id = try await send(file, of: asset, client: client, extra: videoID.map { ["livePhotoVideoId": $0] } ?? [:])
        remember(asset, server: id)
    }

    private func remember(_ asset: PHAsset, server id: String) {
        uploaded[asset.localIdentifier] = id
        try? FileManager.default.createDirectory(at: Self.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(uploaded).write(to: Self.recordURL)
    }

    private func export(_ resource: PHAssetResource, to folder: URL) async throws -> URL {
        let file = folder.appending(path: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // the original may be in iCloud only
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
    }

    private func send(_ file: URL, of asset: PHAsset, client: ImmichClient, extra: [String: String]) async throws -> String {
        let fields = [
            "deviceAssetId": asset.localIdentifier,
            "fileCreatedAt": (asset.creationDate ?? .now).formatted(.iso8601),
            "fileModifiedAt": (asset.modificationDate ?? asset.creationDate ?? .now).formatted(.iso8601),
            "isFavorite": String(asset.isFavorite),
        ].merging(extra) { $1 }
        return try await client.upload(file, fields: fields, cellular: !wifiOnly)
    }

    private static func sha1(_ file: URL) throws -> String {
        var hasher = Insecure.SHA1()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fetches() -> [PHFetchResult<PHAsset>] {
        if albumIDs.isEmpty { return [PHAsset.fetchAssets(with: nil)] }
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        var results: [PHFetchResult<PHAsset>] = []
        albums.enumerateObjects { album, _, _ in results.append(PHAsset.fetchAssets(in: album, options: nil)) }
        return results
    }

    /// Device assets the server already has: safe to delete from the iPhone.
    func backedUpOnDevice() -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(withLocalIdentifiers: Array(uploaded.keys), options: nil)
    }

    func freeUpSpace() async throws {
        let assets = backedUpOnDevice()
        guard assets.count > 0 else { return }
        // iOS shows its own confirmation and moves the items to Recently Deleted on the iPhone
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        refreshPending()
    }
}

private struct UploadCheck: Decodable {
    var results: [Result]

    struct Result: Decodable {
        var action: String
        var assetId: String?
    }
}

/// Backup settings, progress and errors.
struct BackupView: View {
    @Environment(Session.self) private var session
    @State private var backup = Backup.shared
    @State private var albums: [PHAssetCollection] = []
    @State private var message: String?

    var body: some View {
        @Bindable var backup = backup
        Form {
            Section {
                Toggle("Back Up This iPhone", isOn: $backup.enabled)
                    .onChange(of: backup.enabled) { _, on in
                        if on, let client = session.client { backup.start(with: client) }
                    }
            } footer: {
                Text("New photos and videos upload to your Immich server while WoofPhoto is open, and in the background when iOS allows it.")
            }
            Section("Status") {
                LabeledContent("Backed Up", value: backup.backedUpCount.formatted())
                LabeledContent("Not Backed Up", value: backup.pending.count.formatted())
                switch backup.state {
                case .idle: EmptyView()
                case .scanning: Label("Checking the library…", systemImage: "magnifyingglass")
                case let .waiting(reason): Label(reason, systemImage: "pause.circle")
                case let .uploading(done, total):
                    ProgressView("Uploading \(done + 1) of \(total)", value: Double(done), total: Double(max(total, 1)))
                case .finished: Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
                case let .failed(reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if backup.isRunning {
                    Button("Stop", role: .destructive) { backup.stop() }
                } else {
                    Button("Back Up Now") { if let client = session.client { backup.start(with: client) } }
                }
            }
            Section("Options") {
                Toggle("Wi-Fi Only", isOn: $backup.wifiOnly)
                Toggle("Only While Charging", isOn: $backup.chargingOnly)
            }
            Section {
                ForEach(albums, id: \.localIdentifier) { album in
                    Toggle(album.localizedTitle ?? "Album", isOn: Binding {
                        backup.albumIDs.contains(album.localIdentifier)
                    } set: { on in
                        backup.albumIDs = on ? backup.albumIDs + [album.localIdentifier] : backup.albumIDs.filter { $0 != album.localIdentifier }
                        backup.refreshPending()
                    })
                }
            } header: {
                Text("Albums")
            } footer: {
                Text(backup.albumIDs.isEmpty ? "No album chosen: every photo and video is backed up." : "Only the chosen albums are backed up.")
            }
            Section {
                Button("Free Up Space") {
                    Task {
                        do {
                            try await backup.freeUpSpace()
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            } footer: {
                Text("Deletes from this iPhone the \(backup.backedUpOnDevice().count.formatted()) items your server already has. iOS asks before deleting.")
            }
            if !backup.errors.isEmpty {
                Section("Errors") {
                    ForEach(backup.errors, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {}
        .task {
            guard await backup.authorize() else { return }
            backup.refreshPending()
            var list: [PHAssetCollection] = []
            for type in [PHAssetCollectionType.smartAlbum, .album] {
                PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { album, _, _ in
                    if PHAsset.fetchAssets(in: album, options: nil).count > 0 { list.append(album) }
                }
            }
            albums = list
        }
    }
}

/// The timeline month a device asset belongs to, like "2024-05-01".
private func monthKey(_ asset: PHAsset) -> String {
    (asset.creationDate ?? .now).formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month()) + "-01"
}

extension AssetRef {
    /// A photo or video on this iPhone.
    init(device asset: PHAsset) {
        self.init(id: "local:" + asset.localIdentifier, isImage: asset.mediaType == .image, isFavorite: asset.isFavorite,
                  duration: asset.mediaType == .video ? Int(asset.duration * 1000) : nil,
                  date: asset.creationDate ?? .now, localID: asset.localIdentifier)
    }
}

extension Timeline {
    /// Every photo and video on this iPhone, for when no server is signed in.
    /// ponytail: built once on the main thread; move off it if huge libraries stall the launch.
    static func device() -> Timeline {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var months: [String: [AssetRef]] = [:]
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            months[monthKey(asset), default: []].append(AssetRef(device: asset))
        }
        return Timeline(months: months.keys.sorted().map { Month(key: $0, count: months[$0]?.count ?? 0, assets: months[$0]) })
    }
}
