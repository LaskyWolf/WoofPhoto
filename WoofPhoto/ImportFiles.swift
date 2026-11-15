import SwiftUI
import UniformTypeIdentifiers

/// Uploads photos and videos from the Files app (iCloud Drive, other apps' folders) to the server as new assets.
struct ImportFilesView: View {
    @Environment(Session.self) private var session
    @State private var picking = false
    @State private var busy = false
    @State private var done = 0
    @State private var total = 0
    @State private var failures: [String] = []

    var body: some View {
        List {
            Section {
                Button("Choose Photos and Videos…", systemImage: "folder") { picking = true }
                    .disabled(busy)
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total)) { Text("Uploaded \(done) of \(total)") }
                }
                ForEach(failures, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("Sends files from Files, iCloud Drive or another app to your Immich server as new photos and videos. A file the server already has is skipped.")
            }
        }
        .sensoryFeedback(trigger: busy) { old, new in old && !new && failures.isEmpty ? .success : nil }
        .navigationTitle("Import from Files")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await upload(urls) } }
        }
    }

    private func upload(_ urls: [URL]) async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        total = urls.count
        done = 0
        failures = []
        for url in urls {
            // a file picked from outside the app can be read only between these two calls
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let created = values?.creationDate ?? .now
            let modified = values?.contentModificationDate ?? created
            do {
                _ = try await client.upload(url, fields: ["fileCreatedAt": created.formatted(.iso8601),
                                                          "fileModifiedAt": modified.formatted(.iso8601)])
            } catch {
                failures.append("\(url.lastPathComponent): \(error.explanation)")
            }
            done += 1
        }
    }
}
