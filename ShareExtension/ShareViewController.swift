import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Upload to Immich": hosts the SwiftUI page and closes the sheet when it's done.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let page = SharePage(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: page)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// The photos and videos shared, an optional album, and Upload. Uses the account the app signed in with.
struct SharePage: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void

    private enum Phase: Equatable { case ready, uploading(Int), finished, failed(String) }

    private let client = ImmichClient.saved()
    @State private var albums: [AlbumRow] = []
    @State private var albumID: String?
    @State private var phase = Phase.ready

    var body: some View {
        NavigationStack {
            Group {
                if client == nil {
                    ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("Open WoofPhoto and sign in to your Immich server, then share again."))
                } else {
                    form
                }
            }
            .navigationTitle("Upload to Immich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { Task { await upload() } }
                        .disabled(!canUpload)
                }
            }
        }
        .task {
            guard let client else { return }
            await ImmichClient.chooseAddress()
            let list: [AlbumRow] = (try? await client.fetch("GET", "/albums")) ?? []
            albums = list.sorted { ($0.albumName ?? "").localizedStandardCompare($1.albumName ?? "") == .orderedAscending }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Again after a failure: the server answers "duplicate" for what already went up.
    private var canUpload: Bool { client != nil && !providers.isEmpty && (phase == .ready || isFailed) }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Items", value: providers.count.formatted())
                Picker("Album", selection: $albumID) {
                    Text("None").tag(String?.none)
                    ForEach(albums) { Text($0.albumName ?? "Untitled").tag(String?.some($0.id)) }
                }
            } footer: {
                Text("Uploads to \(client?.server.host() ?? "your server").")
            }
            Section {
                switch phase {
                case .ready: EmptyView()
                case let .uploading(done):
                    ProgressView("Uploading \(min(done + 1, providers.count)) of \(providers.count)",
                                 value: Double(done), total: Double(max(providers.count, 1)))
                case .finished: Label("Uploaded", systemImage: "checkmark.circle").foregroundStyle(.green)
                case let .failed(reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .disabled(phase != .ready && !isFailed)
    }

    private func upload() async {
        guard let client else { return }
        var ids: [String] = []
        do {
            for (index, provider) in providers.enumerated() {
                phase = .uploading(index)
                let file = try await Self.copy(provider)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                // Immich reads the date taken from the file's metadata; these are only the fallback
                ids.append(try await client.upload(file, fields: ["fileCreatedAt": date.formatted(.iso8601),
                                                                  "fileModifiedAt": date.formatted(.iso8601)]))
            }
            if let albumID, !ids.isEmpty {
                try await client.call("PUT", "/albums/\(albumID)/assets", body: ["ids": ids])
            }
            phase = .finished
            try? await Task.sleep(for: .seconds(0.8))
            done()
        } catch {
            phase = .failed(ids.isEmpty ? error.explanation : "\(ids.count) uploaded, then: \(error.explanation)")
        }
    }

    /// iOS deletes the shared file when the handler returns, so it's copied into a folder of its own, keeping its name.
    private static func copy(_ provider: NSItemProvider) async throws -> URL {
        let type = [UTType.movie, .image].first { provider.hasItemConformingToTypeIdentifier($0.identifier) } ?? .data
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                let folder = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)")
                let copy = folder.appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// The two album fields the picker needs, from `GET /albums`.
struct AlbumRow: Decodable, Identifiable {
    var id: String
    var albumName: String?
}
