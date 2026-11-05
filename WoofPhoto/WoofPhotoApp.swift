import SwiftUI

@main
struct WoofPhotoApp: App {
    @State private var session = Session()

    init() {
        // Downloaded thumbnails stay on disk up to this size; iOS removes the oldest beyond it.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.client != nil {
                    TabView {
                        Tab("Library", systemImage: "photo.on.rectangle") { LibraryView() }
                    }
                } else {
                    SignInView()
                }
            }
            .environment(session)
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
