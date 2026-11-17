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
    /// A photo deleted in WoofPhoto also goes from this iPhone's library, when it was backed up from here.
    var deletesOnDevice = UserDefaults.standard.object(forKey: "backup.deleteOnDevice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(deletesOnDevice, forKey: "backup.deleteOnDevice") }
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
    /// Server asset ids whose copy is still in this iPhone's library, for the grid badges.
    private(set) var onDeviceIDs: Set<String> = []
    /// Server photos the grid matched to a copy on this iPhone by capture time, not yet known to the backup record.
    private(set) var matchedOnDevice: Set<String> = []
    /// False until photo access is granted: without it every server photo would look server-only.
    private(set) var tracksDevice = false
    /// Goes up whenever the lists of photos not backed up changed, so the Library merges again.
    private(set) var revision = 0
    /// iPhone photos whose checksum the server already answered for.
    private var checked: Set<String>
    private var matchTask: Task<Void, Never>?
    /// Progress of the checksum check against the server, nil when it isn't running.
    private(set) var matching: (done: Int, total: Int)?
    private var task: Task<Void, Never>?
    private var saving: Task<Void, Never>?

    private static let recordURL = URL.applicationSupportDirectory.appending(path: "backup.json")
    private static let checkedURL = URL.applicationSupportDirectory.appending(path: "backup-checked.json")

    private init() {
        uploaded = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: Self.recordURL))) ?? [:]
        checked = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: Self.checkedURL))) ?? [])
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
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(uploaded.keys), options: nil)
            .enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        onDeviceIDs = Set(uploaded.filter { present.contains($0.key) }.map(\.value))
        tracksDevice = true
        revision += 1
    }

    /// Asks the server which of the photos not backed up it already has, by checksum, and uploads nothing.
    /// A match is remembered like an upload, so the photo shows once. Photos whose original is only in iCloud are skipped.
    /// `limit` keeps the automatic run short; the button in Backup passes none.
    func matchExisting(with client: ImmichClient, limit: Int = .max) {
        guard matchTask == nil, task == nil else { return }
        matchTask = Task {
            defer { matchTask = nil; matching = nil }
            guard await authorize() else { return }
            if pending.isEmpty { refreshPending() }
            let todo = Array(pending.filter { !checked.contains($0.localIdentifier) }.prefix(limit))
            var found = 0
            for start in stride(from: 0, to: todo.count, by: 50) {
                if Task.isCancelled { break }
                matching = (start, todo.count)
                var entries: [[String: String]] = []
                for asset in todo[start..<min(start + 50, todo.count)] {
                    guard !Task.isCancelled, let sum = await checksum(of: asset) else { continue }
                    entries.append(["id": asset.localIdentifier, "checksum": sum])
                }
                guard !entries.isEmpty else { continue }
                do {
                    let reply: UploadCheck = try await client.fetch("POST", "/assets/bulk-upload-check", body: ["assets": entries])
                    let answer = Matching.duplicates(in: reply.results)
                    checked.formUnion(answer.checked)
                    for (local, server) in answer.found { uploaded[local] = server }
                    found += answer.found.count
                } catch {
                    break // offline or the server is busy: the rest waits for the next run
                }
            }
            if let data = try? JSONEncoder().encode(checked) { try? data.write(to: Self.checkedURL, options: .atomic) }
            if found > 0 {
                persist()
                refreshPending()
            }
        }
    }

    func stopMatching() { matchTask?.cancel() }

    /// The SHA-1 the server knows a file by, read from the original in the library without copying it; nil when it isn't on this iPhone.
    private func checksum(of asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let main = resources.first(where: { [.photo, .video].contains($0.type) }) ?? resources.first else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let hasher = SHA1Box()
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: main, options: options) { hasher.sha1.update(data: $0) } completionHandler: { error in
                continuation.resume(returning: error == nil ? hasher.hex : nil)
            }
        }
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
            let reason = "WoofPhoto can't see your photos. Allow access in Settings > Privacy & Security > Photos."
            state = .failed(reason)
            await Gotify.backupEnded(uploaded: 0, errors: [], failure: reason)
            return
        }
        state = .scanning
        errors = []
        await ImmichClient.chooseAddress()
        refreshPending()
        var sent = 0
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
                if try await upload(asset, client: client) { sent += 1 }
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
                persist()
                state = .waiting(wifiOnly ? "Waiting for Wi-Fi." : "Waiting for a connection.")
                return
            } catch let error as URLError where error.code == .cancelled {
                // Stop was tapped: not an error to list
                break
            } catch let error as URLError where Connection.isUnreachable(error) {
                // the server went away; trying every remaining photo would only fill the list with the same failure
                persist()
                state = .waiting("Can't reach the server.")
                return
            } catch is CancellationError {
                break
            } catch {
                errors.append("\(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "An item"): \(error.explanation)")
            }
        }
        current = nil
        persist()
        refreshPending()
        state = Task.isCancelled ? .idle : .finished
        if !Task.isCancelled { UserDefaults.standard.set(Date.now, forKey: "backup.lastRun") }
        WidgetSync.writeBackup()
        if !Task.isCancelled { await Gotify.backupEnded(uploaded: sent, errors: errors) }
    }

    /// False when there was nothing to send: the file isn't readable, or the server already has it.
    private func upload(_ asset: PHAsset, client: ImmichClient) async throws -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let main = resources.first(where: { [.photo, .video].contains($0.type) }) ?? resources.first else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "backup/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = try await export(main, to: folder)
        let checksum = try Self.sha1(file)
        let check: UploadCheck = try await client.fetch("POST", "/assets/bulk-upload-check",
                                                        body: ["assets": [["id": asset.localIdentifier, "checksum": checksum]]])
        if let result = check.results.first, result.action == "reject" {
            remember(asset, server: result.assetId ?? "")
            return false
        }
        var videoID: String?
        if let paired = resources.first(where: { $0.type == .pairedVideo }) {
            // the moving part of a Live Photo goes up first, hidden, and the photo points to it
            videoID = try await send(try await export(paired, to: folder), of: asset, client: client, extra: ["visibility": "hidden"])
        }
        let id = try await send(file, of: asset, client: client, extra: videoID.map { ["livePhotoVideoId": $0] } ?? [:])
        remember(asset, server: id)
        return true
    }

    func noteOnDevice(_ serverIDs: Set<String>) { matchedOnDevice.formUnion(serverIDs) }

    private func remember(_ asset: PHAsset, server id: String) {
        uploaded[asset.localIdentifier] = id
        onDeviceIDs.insert(id)
        // the whole record is rewritten, so it waits for a pause in uploading instead of following every photo
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { persist() }
        }
    }

    private func persist() {
        saving?.cancel()
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

    /// Moves the iPhone's own copies of photos deleted on the server to Recently Deleted. iOS asks to confirm.
    /// What this app never backed up has no record here, so it is left alone. A refused prompt leaves the copy,
    /// and the record stays, so the next backup doesn't upload it again.
    func deleteOnDevice(serverIDs: [String]) async {
        guard deletesOnDevice else { return }
        let wanted = Set(serverIDs)
        let local = uploaded.filter { wanted.contains($0.value) }.map(\.key)
        guard !local.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: local, options: nil)
        guard assets.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        refreshPending()
    }

    /// Forgets what was backed up, for signing out: another account's server doesn't have these.
    func forget() {
        stop()
        uploaded = [:]
        onDeviceIDs = []
        matchedOnDevice = []
        matchTask?.cancel()
        checked = []
        try? FileManager.default.removeItem(at: Self.checkedURL)
        try? FileManager.default.removeItem(at: Self.recordURL)
        refreshPending()
    }

    /// Deletes from the iPhone only what the server still has, out of Recently Deleted.
    func freeUpSpace(client: ImmichClient) async throws {
        // ponytail: one request per item; a bulk check if thousands make it slow
        let kept = await withTaskGroup(of: String?.self) { group in
            for (local, server) in uploaded {
                group.addTask { (try? await client.asset(server)).flatMap { $0.isTrashed == true ? nil : local } }
            }
            return await group.reduce(into: [String]()) { if let id = $1 { $0.append(id) } }
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: kept, options: nil)
        guard assets.count > 0 else { return }
        // iOS shows its own confirmation and moves the items to Recently Deleted on the iPhone
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        refreshPending()
    }
}

private struct UploadCheck: Decodable {
    var results: [Matching.Check]
}

/// A SHA-1 fed by PhotoKit's callbacks, which run one after another on a background queue.
private final class SHA1Box: @unchecked Sendable {
    var sha1 = Insecure.SHA1()
    var hex: String { sha1.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// Backup settings, progress and errors.
struct BackupView: View {
    @Environment(Session.self) private var session
    @State private var backup = Backup.shared
    @State private var albums: [PHAssetCollection] = []
    @State private var message: String?
    @State private var gotifyServer = Gotify.server
    @State private var gotifyToken = Gotify.token
    @State private var testing = false

    var body: some View {
        @Bindable var backup = backup
        List {
            Section {
                Toggle(isOn: $backup.enabled) { Label("Back Up This iPhone", systemImage: "icloud.and.arrow.up") }
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
                    Button("Stop", systemImage: "stop.circle", role: .destructive) { backup.stop() }
                } else {
                    Button("Back Up Now", systemImage: "arrow.up.circle") { if let client = session.client { backup.start(with: client) } }
                }
            }
            Section {
                if let progress = backup.matching {
                    ProgressView("Checking \(progress.done + 1) of \(progress.total)", value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Button("Stop", systemImage: "stop.circle", role: .destructive) { backup.stopMatching() }
                } else {
                    Button("Find Photos Already on the Server", systemImage: "link") { if let client = session.client { backup.matchExisting(with: client) } }
                        .disabled(backup.isRunning)
                }
            } footer: {
                Text("Compares each photo with the server's by content, without uploading, so a photo on both shows once in the Library.")
            }
            Section("Options") {
                Toggle(isOn: $backup.wifiOnly) { Label("Wi-Fi Only", systemImage: "wifi") }
                Toggle(isOn: $backup.chargingOnly) { Label("Only While Charging", systemImage: "bolt") }
                Toggle(isOn: $backup.deletesOnDevice) { Label("Delete from This iPhone Too", systemImage: "trash") }
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
                Button("Free Up Space", systemImage: "iphone.and.arrow.forward") {
                    Task {
                        do {
                            guard let client = session.client else { return }
                            try await backup.freeUpSpace(client: client)
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            } footer: {
                Text("Deletes from this iPhone the \(backup.onDeviceIDs.count.formatted()) items your server already has. iOS asks before deleting.")
            }
            Section {
                TextField("Server", text: $gotifyServer, prompt: Text("https://gotify.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                SecureField("App Token", text: $gotifyToken)
                Button("Send Test", systemImage: "paperplane") { Task { await sendTest() } }
                    .disabled(testing || gotifyServer.isEmpty || gotifyToken.isEmpty)
            } header: {
                Text("Gotify")
            } footer: {
                Text("Sends a message to your Gotify server when a backup uploads something or fails. Create an app in Gotify and paste its token.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: gotifyServer) { Gotify.server = gotifyServer }
            .onChange(of: gotifyToken) { Gotify.token = gotifyToken }
            if !backup.errors.isEmpty {
                Section("Errors") {
                    ForEach(backup.errors, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .messageAlert($message)
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

    private func sendTest() async {
        testing = true
        defer { testing = false }
        do {
            try await Gotify.send(title: "WoofPhoto", message: "Backup messages will arrive here.")
            message = "Test message sent."
        } catch {
            message = error.explanation
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
