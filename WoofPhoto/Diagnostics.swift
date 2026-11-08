import SwiftUI
import WidgetKit
import os

/// WoofMusic's hidden Diagnostics page, opened by long-pressing the account in Settings: build, signing,
/// widget storage, server, models and recent log problems, with a button that copies everything for a bug report.
struct DiagnosticsView: View {
    @Environment(Session.self) private var session
    @State private var sections: [DiagnosticsSection] = []
    @State private var accountCheck: String?
    @State private var isCheckingAccount = false
    @State private var timeline: String?
    @State private var copied = false
    @State private var problems: [String] = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Actions") {
                Button("Reload Widgets", systemImage: "arrow.clockwise") {
                    // a fresh value in the App Group, which the WoofPhoto Check widget shows back
                    AppGroup.defaults?.set(Date.now.formatted(date: .omitted, time: .standard), forKey: "spike.value")
                    WidgetCenter.shared.reloadAllTimelines()
                    sections = DiagnosticsSection.all(session)
                }
                Button { Task { await checkAccount() } } label: {
                    LabeledContent {
                        if isCheckingAccount { ProgressView() } else if let accountCheck { Text(accountCheck) }
                    } label: {
                        Label("Check Account", systemImage: "person.badge.shield.checkmark")
                    }
                }
                .disabled(isCheckingAccount)
                Button { Task { await countTimeline() } } label: {
                    LabeledContent {
                        if let timeline { Text(timeline) }
                    } label: {
                        Label("Count Timeline", systemImage: "number")
                    }
                }
                if FileManager.default.fileExists(atPath: FileLog.shared.fileURL.path) {
                    ShareLink(item: FileLog.shared.fileURL) { Label("Share Log File", systemImage: "doc.text") }
                }
                Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = true
                }
            }

            Section {
                if problems.isEmpty {
                    Text("Nothing in the log.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Clear Problems", systemImage: "trash", role: .destructive) {
                        DiagnosticsSection.clearProblems()
                        problems = []
                    }
                }
            } header: {
                Text("Recent Problems")
            } footer: {
                Text("The last errors and model timings from the log file, newest last. Clearing hides them here; the log file keeps them.")
            }

            Section("Checks") {
                NavigationLink("Open a Live Photo from the Server") { LivePhotoSpike() }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sections = DiagnosticsSection.all(session)
            problems = DiagnosticsSection.recentProblems()
        }
    }

    private var report: String {
        var lines = sections.flatMap { section in ["## \(section.title)"] + section.rows.map { "\($0.label): \($0.value)" } }
        if let accountCheck { lines.append("Account check: \(accountCheck)") }
        if let timeline { lines.append("Timeline: \(timeline)") }
        lines.append("## Recent Problems")
        lines += problems
        return lines.joined(separator: "\n")
    }

    private func checkAccount() async {
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        guard let client = session.client else { return accountCheck = "Not signed in" }
        do {
            let me = try await client.me()
            accountCheck = "OK, \(me.name)"
        } catch {
            accountCheck = "Failed: \(error.explanation)"
        }
    }

    private func countTimeline() async {
        guard let client = session.client else { return }
        timeline = "Loading…"
        do {
            let buckets = try await client.buckets()
            timeline = "\(buckets.count) months, \(buckets.reduce(0) { $0 + $1.count }) items"
        } catch {
            timeline = error.explanation
        }
    }
}

struct DiagnosticsSection: Identifiable {
    struct Row {
        let label: String
        let value: String
    }

    let title: String
    let rows: [Row]
    var id: String { title }

    @MainActor
    static func all(_ session: Session) -> [DiagnosticsSection] {
        [app(), signing(), widgets(), server(session), models()]
    }

    private static func app() -> DiagnosticsSection {
        let info = Bundle.main.infoDictionary
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let widget = Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "WoofPhotoWidget.appex"))?.bundleIdentifier }
        let share = Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "WoofPhotoShare.appex"))?.bundleIdentifier }
        return DiagnosticsSection(title: "App", rows: [
            Row(label: "Version", value: info?["CFBundleShortVersionString"] as? String ?? "?"),
            Row(label: "Build", value: info?["CFBundleVersion"] as? String ?? "?"),
            Row(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "?"),
            Row(label: "Widget Bundle ID", value: widget ?? "Missing from the app"),
            Row(label: "Share Bundle ID", value: share ?? "Missing from the app"),
            Row(label: "iOS", value: UIDevice.current.systemVersion),
            Row(label: "Device", value: model),
            Row(label: "Language", value: Locale.current.identifier),
        ])
    }

    /// What the signing tool's provisioning profile allows, read from the app.
    private static func signing() -> DiagnosticsSection {
        guard let profile = SigningProfile.current else {
            return DiagnosticsSection(title: "Signing", rows: [Row(label: "Profile", value: "None (ad-hoc or unsigned)")])
        }
        func list(_ values: [String]) -> String { values.isEmpty ? "None" : values.joined(separator: ", ") }
        return DiagnosticsSection(title: "Signing", rows: [
            Row(label: "Profile", value: profile.name),
            Row(label: "Team", value: profile.team),
            Row(label: "Expires", value: profile.expires?.formatted(date: .abbreviated, time: .omitted) ?? "?"),
            Row(label: "Devices", value: profile.devices),
            Row(label: "App Groups", value: list(profile.appGroups)),
            Row(label: "Keychain Groups", value: list(profile.keychainGroups)),
        ])
    }

    private static func widgets() -> DiagnosticsSection {
        let updated = UserDefaults.standard.object(forKey: "featured.updated") as? Date
        return DiagnosticsSection(title: "Widgets", rows: [
            Row(label: "App Group", value: AppGroup.id),
            Row(label: "App Group Container", value: AppGroup.container == nil ? "Missing" : "OK"),
            Row(label: "Shared Value", value: AppGroup.defaults?.string(forKey: "spike.value") ?? "Nothing written"),
            Row(label: "Featured Photos", value: "\(Featured.items().count)"),
            Row(label: "Featured Updated", value: updated?.formatted(.relative(presentation: .named)) ?? "Never"),
        ])
    }

    @MainActor
    private static func server(_ session: Session) -> DiagnosticsSection {
        let client = session.client
        return DiagnosticsSection(title: "Server", rows: [
            Row(label: "Signed In", value: client == nil ? "No" : "Yes"),
            Row(label: "Address", value: client?.server.absoluteString ?? "–"),
            Row(label: "In Use", value: client?.address.absoluteString ?? "–"),
            Row(label: "Local Address", value: ImmichClient.localAddress?.absoluteString ?? "None"),
            Row(label: "Proxy Headers", value: ImmichClient.proxyHeaders.isEmpty ? "None" : "Set"),
        ])
    }

    private static func models() -> DiagnosticsSection {
        DiagnosticsSection(title: "AI Models", rows: [
            Row(label: "Depth", value: CoreMLModel.depth.isDownloaded ? "Downloaded" : "Not downloaded"),
            Row(label: "LaMa", value: CoreMLModel.lama.isDownloaded ? "Downloaded" : "Not downloaded"),
            Row(label: "Apple Intelligence", value: Intelligence.isAvailable ? "Available" : "Not available"),
            Row(label: "Free Memory", value: Int64(os_proc_available_memory()).formatted(.byteCount(style: .memory))),
        ])
    }

    /// Logged by Clear Problems: the list starts after the last one, so the log file stays whole for Share Log File.
    private static let clearedMarker = "Recent Problems cleared"

    static func clearProblems() { FileLog.shared.append("NOTICE", clearedMarker) }

    /// The last 30 error and timing lines of the log file, after the last clear.
    static func recentProblems() -> [String] {
        guard let text = try? String(contentsOf: FileLog.shared.fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n")
        let start = lines.lastIndex { $0.hasSuffix(clearedMarker) }.map { $0 + 1 } ?? lines.startIndex
        return lines[start...].filter { $0.contains("[ERROR]") || $0.contains("[TIME]") }.suffix(30).map(String.init)
    }
}
