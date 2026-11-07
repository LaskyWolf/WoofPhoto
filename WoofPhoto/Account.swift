import SwiftUI

/// One signed-in device, from `GET /sessions`.
struct DeviceSession: Decodable, Identifiable {
    var id: String
    var deviceType: String?
    var deviceOS: String?
    var appVersion: String?
    var createdAt: String?
    var updatedAt: String?
    var current: Bool?
}

/// A passkey for the web app, from `GET /passkeys` (Immich 3.4 and later).
struct Passkey: Decodable, Identifiable {
    var id: String
    var name: String?
    var createdAt: String?
    var usedAt: String?
}

/// Account > Devices: every session on the server, this one marked. Swipe to sign one out, or sign out all the others.
struct DevicesSection: View {
    @Environment(Session.self) private var session
    @State private var devices: [DeviceSession]?
    @State private var confirmsAll = false
    @State private var message: String?

    var body: some View {
        Section {
            if let devices {
                ForEach(devices) { device in
                    row(device)
                        .swipeActions {
                            if device.current != true {
                                Button("Sign Out", role: .destructive) { Task { await revoke(device) } }
                            }
                        }
                }
                if devices.contains(where: { $0.current != true }) {
                    Button("Sign Out Other Devices", role: .destructive) { confirmsAll = true }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Swipe a device to sign it out.")
        }
        .confirmationDialog("Every device except this iPhone is signed out of your Immich account.", isPresented: $confirmsAll, titleVisibility: .visible) {
            Button("Sign Out Other Devices", role: .destructive) { Task { await revokeOthers() } }
        }
        .messageAlert($message)
        .task { await load() }
    }

    private func row(_ device: DeviceSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(device))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text([device.deviceType, device.deviceOS].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ").nonEmpty ?? "Unknown Device")
                    if device.current == true { Text("This iPhone").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                }
                .lineLimit(1)
                Text(detail(device)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ device: DeviceSession) -> String {
        let text = "\(device.deviceType ?? "") \(device.deviceOS ?? "")".lowercased()
        if text.contains("ios") || text.contains("iphone") || text.contains("android") { return "iphone" }
        if text.contains("ipad") { return "ipad" }
        return text.contains("mac") || text.contains("windows") || text.contains("linux") ? "laptopcomputer" : "globe"
    }

    private func detail(_ device: DeviceSession) -> String {
        let used = device.updatedAt.flatMap(Date.init(immich:)).map { "Active \($0.formatted(.relative(presentation: .named)))" }
        let created = device.createdAt.flatMap(Date.init(immich:)).map { "signed in \($0.formatted(date: .abbreviated, time: .omitted))" }
        return [used, created].compactMap { $0 }.joined(separator: ", ")
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let all: [DeviceSession] = try await client.fetch("GET", "/sessions")
            // this iPhone first, then the most recently active
            devices = all.sorted { ($0.current == true ? 1 : 0, $0.updatedAt ?? "") > ($1.current == true ? 1 : 0, $1.updatedAt ?? "") }
        } catch {
            devices = []
            message = error.explanation
        }
    }

    private func revoke(_ device: DeviceSession) async {
        do {
            try await session.client?.call("DELETE", "/sessions/\(device.id)")
            devices?.removeAll { $0.id == device.id }
        } catch {
            message = error.explanation
        }
    }

    private func revokeOthers() async {
        do {
            try await session.client?.call("DELETE", "/sessions")
            devices?.removeAll { $0.current != true }
        } catch {
            message = error.explanation
        }
    }
}

/// Account > Passkeys: the passkeys the web app signs in with, renamed or deleted here.
/// Hidden on servers before Immich 3.4, which answer 404. Adding one stays in the web app: see the note below.
struct PasskeysSection: View {
    @Environment(Session.self) private var session
    @State private var passkeys: [Passkey]?
    /// The server has no passkeys (before Immich 3.4) or they failed to load.
    @State private var unsupported = false
    @State private var renaming: Passkey?
    @State private var name = ""
    @State private var message: String?

    var body: some View {
        // a row while loading, so the section exists and its task runs; nothing on a server without passkeys
        if !unsupported {
            Section {
                if let passkeys {
                    ForEach(passkeys) { passkey in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(passkey.name?.nonEmpty ?? "Passkey")
                            Text(detail(passkey)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await delete(passkey) } }
                            Button("Rename") {
                                name = passkey.name ?? ""
                                renaming = passkey
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Passkeys")
            } footer: {
                // native passkeys need the server's domain in the app's signature, which a self-hosted server can't have
                Text(passkeys?.isEmpty == false ? "Swipe a passkey to rename or delete it. Add new ones in the Immich web app." : "Add a passkey in the Immich web app. It signs you in there.")
            }
            .alert("Rename Passkey", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let renaming { Task { await rename(renaming) } } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .messageAlert($message)
            .task { await load() }
        }
    }

    private func detail(_ passkey: Passkey) -> String {
        let created = passkey.createdAt.flatMap(Date.init(immich:)).map { "Added \($0.formatted(date: .abbreviated, time: .omitted))" }
        let used = passkey.usedAt.flatMap(Date.init(immich:)).map { "used \($0.formatted(.relative(presentation: .named)))" }
        return [created, used].compactMap { $0 }.joined(separator: ", ")
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            passkeys = try await client.fetch("GET", "/passkeys")
        } catch {
            // 404 before Immich 3.4; any other failure also just leaves passkeys out of the page
            unsupported = true
        }
    }

    private func rename(_ passkey: Passkey) async {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard let client = session.client else { return }
        do {
            let updated: Passkey = try await client.fetch("PATCH", "/passkeys/\(passkey.id)", body: ["name": new])
            if let i = passkeys?.firstIndex(where: { $0.id == passkey.id }) { passkeys?[i] = updated }
        } catch {
            message = error.explanation
        }
    }

    private func delete(_ passkey: Passkey) async {
        do {
            try await session.client?.call("DELETE", "/passkeys/\(passkey.id)")
            passkeys?.removeAll { $0.id == passkey.id }
        } catch {
            message = error.explanation
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
