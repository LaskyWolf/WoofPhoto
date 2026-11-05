import SwiftUI
import WidgetKit

/// M0 test screen: each section answers one question from FEASIBILITY.md on a real iPhone.
struct SpikesView: View {
    @Environment(Session.self) private var session
    @State private var timeline = "Not checked"
    @State private var groupValue = AppGroup.defaults?.string(forKey: "spike.value") ?? "Nothing written"

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Address", value: session.client?.server.absoluteString ?? "?")
                LabeledContent("Timeline", value: timeline)
                Button("Count Timeline") { Task { await countTimeline() } }
            }

            Section {
                if let profile = SigningProfile.current {
                    LabeledContent("Profile", value: profile.name)
                    LabeledContent("Team", value: profile.team)
                    LabeledContent("Expires", value: profile.expires?.formatted(date: .abbreviated, time: .omitted) ?? "?")
                    LabeledContent("App Groups", value: profile.appGroups.isEmpty ? "None" : profile.appGroups.joined(separator: ", "))
                    LabeledContent("Keychain Groups", value: profile.keychainGroups.isEmpty ? "None" : profile.keychainGroups.joined(separator: ", "))
                } else {
                    LabeledContent("Profile", value: "None (unsigned or ad-hoc)")
                }
            } header: {
                Text("Signing")
            }

            Section {
                LabeledContent("Group", value: AppGroup.id)
                LabeledContent("Access", value: AppGroup.container == nil ? "No" : "Yes")
                LabeledContent("Value", value: groupValue)
                Button("Write Value for the Widget") { writeGroupValue() }
            } header: {
                Text("App Group")
            } footer: {
                Text("Add the WoofPhoto Check widget to the Home Screen. It passes when it shows the same value and group.")
            }

            Section("Live Photo") {
                NavigationLink("Open a Live Photo from the Server") { LivePhotoSpike() }
            }

            Section("AI Models") {
                NavigationLink("Measure Depth and LaMa") { ModelSpike() }
            }

            Section {
                Button("Sign Out", role: .destructive) { session.signOut() }
            }
        }
        .navigationTitle("M0 Checks")
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

    private func writeGroupValue() {
        guard let defaults = AppGroup.defaults else {
            groupValue = "The App Group can't be opened"
            return
        }
        let value = Date().formatted(date: .omitted, time: .standard)
        defaults.set(value, forKey: "spike.value")
        groupValue = defaults.string(forKey: "spike.value") ?? "Not saved"
        WidgetCenter.shared.reloadAllTimelines()
    }
}
