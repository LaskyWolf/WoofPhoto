import MapKit
import SwiftUI

/// Every photo with a location on a map. Nearby pins merge into clusters; tapping one shows its photos.
struct PlacesView: View {
    @Environment(Session.self) private var session
    @State private var markers: [MapMarker]?
    @State private var selection: SelectedPlace?
    @State private var error: String?

    var body: some View {
        ClusterMap(markers: markers ?? []) { ids, title in
            selection = SelectedPlace(ids: ids, title: title)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if markers == nil, error == nil { ProgressView() }
            if let error { ContentUnavailableView("Can't Load the Map", systemImage: "map", description: Text(error)) }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selection) { place in
            NavigationStack {
                FixedGridScreen(title: place.title, assets: place.ids.map { AssetRef(id: $0) })
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            do {
                markers = try await session.client?.mapMarkers()
            } catch {
                self.error = error.explanation
            }
        }
    }
}

struct SelectedPlace: Identifiable {
    let ids: [String]
    let title: String
    var id: String { ids.first ?? title }
}

/// MKMapView, because SwiftUI's Map has no clustering.
struct ClusterMap: UIViewRepresentable {
    let markers: [MapMarker]
    let onSelect: ([String], String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        guard context.coordinator.count != markers.count else { return }
        context.coordinator.count = markers.count
        map.removeAnnotations(map.annotations)
        let pins = markers.map(PhotoPin.init)
        map.addAnnotations(pins)
        map.showAnnotations(pins, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var count = -1
        var onSelect: ([String], String) -> Void = { _, _ in }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is PhotoPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier, for: annotation)
            view.clusteringIdentifier = "photo"
            (view as? MKMarkerAnnotationView)?.glyphImage = UIImage(systemName: "photo")
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            let pins = (annotation as? MKClusterAnnotation)?.memberAnnotations.compactMap { $0 as? PhotoPin }
                ?? [annotation as? PhotoPin].compactMap { $0 }
            guard let first = pins.first else { return }
            onSelect(pins.map(\.marker.id), first.marker.city ?? first.marker.country ?? "Photos")
        }
    }

    final class PhotoPin: NSObject, MKAnnotation {
        let marker: MapMarker
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon) }
        init(_ marker: MapMarker) { self.marker = marker }
    }
}

/// Recently Deleted: recover or delete for good, one at a time in the viewer or all at once.
struct TrashView: View {
    @Environment(Session.self) private var session
    @State private var timeline = Timeline(.trash)
    @State private var confirmsEmpty = false
    @State private var error: String?

    var body: some View {
        AssetGrid(timeline: timeline)
            .navigationTitle("Recently Deleted")
            .navigationSubtitle("Items stay here for 30 days before they are deleted for good.")
            .toolbar {
                Menu("More", systemImage: "ellipsis") {
                    Button("Recover All", systemImage: "arrow.uturn.backward") { Task { await run { try await $0.restoreTrash() } } }
                    Button("Delete All", systemImage: "trash", role: .destructive) { confirmsEmpty = true }
                }
            }
            .confirmationDialog("These items will be deleted for good. This can't be undone.", isPresented: $confirmsEmpty, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { Task { await run { try await $0.emptyTrash() } } }
            }
            .messageAlert($error)
    }

    private func run(_ action: (ImmichClient) async throws -> Void) async {
        guard let client = session.client else { return }
        do {
            try await action(client)
            timeline = Timeline(.trash)
        } catch {
            self.error = error.explanation
        }
    }
}

/// Hidden: Immich's locked folder. Face ID opens it with the PIN saved on this iPhone;
/// the first time, the PIN is typed (or created) and saved.
struct HiddenView: View {
    enum Stage {
        case checking, createPIN, enterPIN, unlocked
    }

    @Environment(Session.self) private var session
    @State private var stage = Stage.checking
    @State private var pin = ""
    @State private var error: String?
    @State private var timeline = Timeline(.hidden)

    var body: some View {
        Group {
            switch stage {
            case .checking:
                ProgressView()
            case .createPIN, .enterPIN:
                Form {
                    Section {
                        SecureField("PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    } footer: {
                        Text(stage == .createPIN
                             ? "Create a 6-digit PIN for the Hidden album. Immich uses the same PIN in the web app."
                             : "Enter the PIN of the Hidden album (the locked folder in Immich). WoofPhoto saves it so Face ID can open the album next time.")
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    Button(stage == .createPIN ? "Create PIN" : "Unlock") { Task { await submit() } }
                        .disabled(pin.count != 6)
                }
            case .unlocked:
                AssetGrid(timeline: timeline)
            }
        }
        .navigationTitle("Hidden")
        .task { await open() }
        .onDisappear {
            guard stage == .unlocked, let client = session.client else { return }
            // the saved thumbnails go too, or History and other screens could show them without Face ID
            for asset in timeline.assets { ImageCache.forget(asset.id, client: client) }
            Still.forgetBlurs()
            Task { try? await client.lockSession() }
        }
    }

    private func open() async {
        guard let client = session.client else { return }
        do {
            let status = try await client.authStatus()
            guard status.pinCode else {
                stage = .createPIN
                return
            }
            if let saved = await Keychain.readProtected("hidden.pin", reason: "Open the Hidden album") {
                try await client.unlockSession(pin: saved)
                // a PIN saved by an older version moves behind iOS's own Face ID check
                Keychain.write("hidden.pin", saved, protected: true)
                stage = .unlocked
            } else {
                stage = .enterPIN
            }
        } catch {
            self.error = error.explanation
            stage = .enterPIN
        }
    }

    private func submit() async {
        guard let client = session.client else { return }
        error = nil
        do {
            if stage == .createPIN { try await client.setUpPIN(pin) }
            try await client.unlockSession(pin: pin)
            Keychain.write("hidden.pin", pin, protected: true)
            pin = ""
            stage = .unlocked
        } catch ImmichError.http(let code, _) where code == 400 || code == 401 {
            error = "Wrong PIN."
        } catch {
            self.error = error.explanation
        }
    }

}

/// Groups of photos Immich thinks are the same. Keep the suggested one or pick by tapping.
struct DuplicatesView: View {
    @Environment(Session.self) private var session
    @State private var groups: [DuplicateGroup]?
    @State private var keep: [String: Set<String>] = [:]
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(groups ?? []) { group in
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(group.assets) { asset in
                                let kept = kept(group).contains(asset.id)
                                Thumbnail(asset: asset.ref)
                                    .frame(width: 120, height: 120)
                                    .clipShape(.rect(cornerRadius: 8))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: kept ? "checkmark.circle.fill" : "trash.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white, kept ? .blue : .red)
                                            .padding(4)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        Text(size(asset)).font(.caption2.bold()).foregroundStyle(.white).shadow(radius: 2).padding(4)
                                    }
                                    .onTapGesture { toggle(asset.id, in: group) }
                            }
                        }
                    }
                    HStack {
                        Button("Not Duplicates") { Task { await dismiss(group) } }
                        Spacer()
                        Button("Keep Selected") { Task { await resolve(group) } }.bold()
                            // keeping none would send every copy to Recently Deleted
                            .disabled(kept(group).isEmpty)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .overlay {
            if groups == nil, error == nil { ProgressView() }
            if groups?.isEmpty == true { ContentUnavailableView("No Duplicates", systemImage: "square.on.square") }
        }
        .navigationTitle("Duplicates")
        .task { await load() }
    }

    private func kept(_ group: DuplicateGroup) -> Set<String> {
        keep[group.id] ?? Set(group.suggestedKeepAssetIds ?? [group.assets.first?.id].compactMap { $0 })
    }

    private func toggle(_ id: String, in group: DuplicateGroup) {
        var set = kept(group)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        keep[group.id] = set
    }

    private func size(_ asset: Asset) -> String {
        asset.exifInfo?.fileSizeInByte?.value.map { Int64($0).formatted(.byteCount(style: .file)) } ?? ""
    }

    private func load() async {
        do {
            groups = try await session.client?.duplicates()
        } catch {
            self.error = error.explanation
        }
    }

    private func resolve(_ group: DuplicateGroup) async {
        let keep = kept(group)
        do {
            try await session.client?.resolveDuplicates(group.id, keep: Array(keep), trash: group.assets.map(\.id).filter { !keep.contains($0) })
            groups?.removeAll { $0.id == group.id }
        } catch {
            self.error = error.explanation
        }
    }

    private func dismiss(_ group: DuplicateGroup) async {
        do {
            try await session.client?.dismissDuplicates(group.id)
            groups?.removeAll { $0.id == group.id }
        } catch {
            self.error = error.explanation
        }
    }
}
