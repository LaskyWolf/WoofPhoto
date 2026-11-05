import AuthenticationServices
import BackgroundTasks
import SwiftUI

@main
struct WoofPhotoApp: App {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accent") private var accent = AccentPreset.all[0].name

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
                    MainTabs()
                } else {
                    SignInView()
                }
            }
            .environment(session)
            .tint(AccentPreset.named(accent).color)
            .onOpenURL { url in
                // woofphoto://asset/<id>
                if url.host() == "asset", let id = url.pathComponents.last {
                    let asset = AssetRef(id: id)
                    OpenPhoto.shared.open(asset, in: Timeline(assets: [asset]))
                }
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

/// The tabs, with the open photo in the mini viewer above them.
struct MainTabs: View {
    @Environment(Session.self) private var session
    @Bindable private var open = OpenPhoto.shared
    @Namespace private var zoom

    var body: some View {
        TabView {
            Tab("Library", systemImage: "photo.on.rectangle") { LibraryView() }
            Tab("Collections", systemImage: "rectangle.stack") { CollectionsView() }
            Tab(role: .search) { SearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .bottomAccessory(open.asset != nil) {
            MiniViewer()
                .matchedTransitionSource(id: OpenPhoto.miniID, in: zoom) { $0.clipShape(.capsule) }
        }
        .environment(\.photoZoom, zoom)
        .fullScreenCover(isPresented: $open.isExpanded, onDismiss: open.dismissed) {
            if let timeline = open.timeline, let asset = open.asset {
                Viewer(timeline: timeline, start: asset)
                    .navigationTransition(.zoom(sourceID: open.zoomSource, in: zoom))
                    .environment(session)
            }
        }
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuthentication
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
                    Button("Sign In with SSO") { Task { await signInWithSSO() } }
                        .disabled(busy || server.isEmpty)
                } footer: {
                    Text("SSO needs app.immich:///oauth-callback in the server's OAuth redirect list.")
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

    private func signInWithSSO() async {
        busy = true
        defer { busy = false }
        do {
            try await session.signInWithSSO(server: server) { page in
                try await webAuthentication.authenticate(using: page, callbackURLScheme: "app.immich")
            }
        } catch ASWebAuthenticationSessionError.canceledLogin {
        } catch {
            self.error = error.explanation
        }
    }
}
