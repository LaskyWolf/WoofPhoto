import AuthenticationServices
import AVFoundation
import BackgroundTasks
import CoreSpotlight
import SwiftUI

@main
struct WoofPhotoApp: App {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accent") private var accent = AccentPreset.all[0].name

    init() {
        // Downloaded thumbnails stay on disk up to this size; iOS removes the oldest beyond it.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        // videos play with sound when the iPhone's silent switch is on, like in Photos
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Backup.shared.refreshPending()
        // ponytail: models older builds downloaded (Stable Diffusion in 44–45, onnxruntime models up to 53); drop once those are gone
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Models/Runway_SD1.5_Inpaint_chunked"))
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "models/inpainting_lama_2025jan.onnx"))
        // the 6-bit LaMa that painted purple (51–52), and the 390 MB depth model for onnxruntime (up to 53)
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "models/LaMa.mlmodelc"))
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "models/model.onnx"))
        // Depth Anything V2 Small (54–56), which flattened the subject
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "models/DepthAnythingV2Small.mlmodelc"))
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Backup.taskID, using: .main) { task in
            MainActor.assumeIsolated { Self.runBackup(task) }
        }
    }

    /// The background run iOS starts: back up until done or until iOS says time is up.
    @MainActor private static func runBackup(_ task: BGTask) {
        let backup = Backup.shared
        guard let client = ImmichClient.saved() else {
            task.setTaskCompleted(success: false)
            return
        }
        task.expirationHandler = { MainActor.assumeIsolated { backup.stop() } }
        backup.start(with: client)
        Task {
            while backup.isRunning { try? await Task.sleep(for: .seconds(1)) }
            backup.scheduleBackground()
            task.setTaskCompleted(success: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabs()
            .environment(session)
            .tint(AccentPreset.named(accent).color)
            .onOpenURL { url in
                // woofphoto://asset/<id>
                if url.host() == "asset", let id = url.pathComponents.last {
                    let asset = AssetRef(id: id)
                    OpenPhoto.shared.open(asset, in: Timeline(assets: [asset]))
                } else {
                    Router.shared.handle(url)
                }
            }
            // a Spotlight result: its identifier is the woofphoto:// link made in Spotlight.index
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let link = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: link) {
                    Router.shared.handle(url)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                let backup = Backup.shared
                if phase == .active, backup.enabled, let client = session.client { backup.start(with: client) }
                if phase == .active, let client = session.client { Task { await FeaturedPhotos.refreshIfStale(client: client) } }
                if phase == .active, let client = session.client { Task { await WidgetSync.refresh(client: client) } }
                if phase == .background { backup.scheduleBackground() }
            }
            // not only in debug builds: this keeps the thumbnail folder under its limit
            .task { Task.detached(priority: .utility) { OfflineFiles.trimThumbs() } }
            #if DEBUG
            .task { ImmichClient.selfCheck(); Connection.selfCheck(); OfflineIndex.selfCheck(); WidgetData.selfCheck(); FoldersView.selfCheck(); GlyphScript.selfCheck(); FileLog.selfCheck(); AppUpdate.selfCheck() }
            #endif
        }
    }
}

/// The tabs, with the open photo full screen above them, or in WoofTube's floating card.
struct MainTabs: View {
    @Environment(Session.self) private var session
    @Bindable private var open = OpenPhoto.shared
    @Namespace private var zoom
    @Bindable private var router = Router.shared
    @State private var libraryReselects = 0
    private var tab: Int {
        get { router.tab }
        nonmutating set { router.tab = newValue }
    }

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { selected in
            if selected == tab, selected == 0 { libraryReselects += 1 }
            tab = selected
        })) {
            Tab("Library", systemImage: "photo.on.rectangle", value: 0) {
                LibraryView().environment(\.libraryReselects, libraryReselects)
            }
            // without a server the app is a viewer for this iPhone's photos
            if session.client != nil {
                Tab("Collections", systemImage: "rectangle.stack", value: 1) { CollectionsView() }
                Tab(value: 2, role: .search) { SearchView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // things that finish while the screen is elsewhere
        .modifier(FinishHaptics())
        .environment(\.photoZoom, zoom)
        .onChange(of: session.client == nil) { _, signedOut in if signedOut { open.close(); tab = 0 } }
        .overlay { MiniViewer(zoom: zoom) }
        // a collection asked for by a widget, Spotlight or Shortcuts
        .sheet(item: $router.shelf) { shelf in
            NavigationStack { shelf.destination }
                .environment(session)
        }
        .fullScreenCover(isPresented: $open.isExpanded) {
            if let timeline = open.timeline, let asset = open.asset {
                Viewer(timeline: timeline, start: asset)
                    .navigationTransition(.zoom(sourceID: open.zoomSource, in: zoom))
                    .environment(session)
            }
        }
    }
}

/// A tap when a backup or a Keep Offline download finishes while the screen is elsewhere.
private struct FinishHaptics: ViewModifier {
    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: Backup.shared.state) { old, new in
                new == .finished && old != .finished ? .success : nil
            }
            .sensoryFeedback(trigger: OfflineDownloads.shared.isRunning) { old, new in old && !new ? .success : nil }
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(.rect(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .accessibilityHidden(true)
                Text("WoofPhoto").font(.largeTitle.bold()).padding(.top, 8)
                Text("Your Immich photos, on your iPhone.").foregroundStyle(.secondary).padding(.bottom, 12)

                field {
                    TextField("Server address", text: $server, prompt: Text("photos.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                }
                field {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                }
                field {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { if canSignIn { Task { await signIn() } } }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await signIn() }
                } label: {
                    Group { if busy { ProgressView() } else { Text("Sign In") } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .fontWeight(.semibold)
                .disabled(!canSignIn)
                .padding(.top, 8)
                Button { Task { await signInWithSSO() } } label: {
                    Text("Sign In with SSO").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .fontWeight(.semibold)
                .disabled(busy || server.isEmpty)

                Text("The server is the address you open the Immich web app with. SSO needs app.immich:///oauth-callback in the server's OAuth redirect list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, Tokens.screenPadding)
            .padding(.top, 64)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var canSignIn: Bool { !busy && !server.isEmpty && !email.isEmpty && !password.isEmpty }

    /// A text field on its own card.
    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Tokens.cardColor, in: .rect(cornerRadius: Tokens.tileRadius))
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await session.signIn(server: server, email: email, password: password)
            dismiss()
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
            dismiss()
        } catch ASWebAuthenticationSessionError.canceledLogin {
        } catch {
            self.error = error.explanation
        }
    }
}
