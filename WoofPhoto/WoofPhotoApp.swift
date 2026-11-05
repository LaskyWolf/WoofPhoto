import BackgroundTasks
import SwiftUI

@main
struct WoofPhotoApp: App {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    /// A photo opened from the widget.
    @State private var opened: AssetRef?

    init() {
        // Downloaded thumbnails stay on disk up to this size; iOS removes the oldest beyond it.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        Backup.shared.refreshPending()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Backup.taskID, using: .main) { task in
            MainActor.assumeIsolated { Self.runBackup(task) }
        }
    }

    /// The background run iOS starts: back up until done or until iOS says time is up.
    @MainActor private static func runBackup(_ task: BGTask) {
        let backup = Backup.shared
        guard let text = UserDefaults.standard.string(forKey: "server"), let url = URL(string: text),
              let token = Keychain.read("token") else {
            task.setTaskCompleted(success: false)
            return
        }
        task.expirationHandler = { MainActor.assumeIsolated { backup.stop() } }
        backup.start(with: ImmichClient(server: url, token: token))
        Task {
            while backup.isRunning { try? await Task.sleep(for: .seconds(1)) }
            backup.scheduleBackground()
            task.setTaskCompleted(success: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.client != nil {
                    TabView {
                        Tab("Library", systemImage: "photo.on.rectangle") { LibraryView() }
                        Tab("Collections", systemImage: "rectangle.stack") { CollectionsView() }
                        Tab(role: .search) { SearchView() }
                    }
                } else {
                    SignInView()
                }
            }
            .environment(session)
            .onOpenURL { url in
                // woofphoto://asset/<id>
                if url.host() == "asset", let id = url.pathComponents.last { opened = AssetRef(id: id) }
            }
            .fullScreenCover(item: $opened) { asset in
                Viewer(timeline: Timeline(assets: [asset]), start: asset).environment(session)
            }
            .onChange(of: scenePhase) { _, phase in
                let backup = Backup.shared
                if phase == .active, backup.enabled, let client = session.client { backup.start(with: client) }
                if phase == .active, let client = session.client { Task { await FeaturedPhotos.refreshIfStale(client: client) } }
                if phase == .background { backup.scheduleBackground() }
            }
            #if DEBUG
            .task { ImmichClient.selfCheck() }
            #endif
        }
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @State private var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $server, prompt: Text("photos.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The address you open the Immich web app with.")
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        if busy { ProgressView() } else { Text("Sign In") }
                    }
                    .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("WoofPhoto")
        }
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await session.signIn(server: server, email: email, password: password)
        } catch {
            self.error = error.explanation
        }
    }
}
