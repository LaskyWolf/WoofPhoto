import SwiftUI

/// The faces Immich found on one photo, boxed where they are. Tap a box to move or remove it; Add Face draws a new one.
struct FacesView: View {
    let assetID: String

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var faces: [Face]?
    @State private var adding = false
    /// The box being drawn, as fractions of the photo.
    @State private var drawn: CGRect?
    @State private var picking: Pick?
    @State private var message: String?

    /// What the person picker is choosing for.
    private enum Pick: Identifiable {
        case move(Face)
        /// A new box, as fractions of the photo.
        case add(CGRect)

        var id: String {
            switch self {
            case .move(let face): face.id
            case .add: "new"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        // scaledToFit sizes the image to its aspect-fit frame, so the overlay's size is the photo's on screen.
                        .overlay { GeometryReader { boxes(in: $0.size) } }
                        .padding(Tokens.screenPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let hint {
                    Text(hint).font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Faces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", role: .confirm) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("Add Face", systemImage: "plus.viewfinder", isOn: $adding)
                        .disabled(image == nil)
                }
            }
            .sheet(item: $picking, onDismiss: { drawn = nil }) { pick in
                FacePersonPicker { await assign($0, for: pick) }
            }
            .messageAlert($message)
        }
        .task {
            image = await Still.load(assetID, size: "preview", client: session.client)
            await loadFaces()
        }
    }

    private var hint: String? {
        if adding { return "Drag around the face." }
        if faces?.isEmpty == true { return "No faces found. Tap Add Face to mark one." }
        return nil
    }

    @ViewBuilder private func boxes(in size: CGSize) -> some View {
        ForEach(faces ?? []) { face in
            if let rect = face.rect {
                let frame = rect.scaled(to: size)
                Menu {
                    Button("Change Person…", systemImage: "person.crop.circle") { picking = .move(face) }
                    Button("Remove Face", systemImage: "trash", role: .destructive) { Task { await remove(face) } }
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.white, lineWidth: 2)
                        .shadow(radius: 2)
                        .contentShape(.rect)
                        .overlay(alignment: .top) {
                            Text(face.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: .capsule)
                                .fixedSize()
                                .alignmentGuide(.top) { $0[.bottom] + 4 }
                        }
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .accessibilityLabel("Face: \(face.name)")
                .accessibilityHint("Change or remove this face.")
            }
        }
        .allowsHitTesting(!adding)
        if adding {
            Color.clear
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { drawn = Self.fraction(from: $0.startLocation, to: $0.location, in: size) }
                        .onEnded { _ in
                            // Ignore slips too small to be a face.
                            if let drawn, drawn.width > 0.02, drawn.height > 0.02 { picking = .add(drawn) } else { drawn = nil }
                        }
                )
        }
        if let drawn {
            let frame = drawn.scaled(to: size)
            RoundedRectangle(cornerRadius: 4)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
        }
    }

    /// The rectangle between two drag points, clamped to the photo, as fractions of it.
    private static func fraction(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        func clamp(_ value: CGFloat, _ length: CGFloat) -> CGFloat { min(max(value / length, 0), 1) }
        let x1 = clamp(min(start.x, end.x), size.width), x2 = clamp(max(start.x, end.x), size.width)
        let y1 = clamp(min(start.y, end.y), size.height), y2 = clamp(max(start.y, end.y), size.height)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    private func loadFaces() async {
        do {
            faces = try await session.client?.faces(asset: assetID)
        } catch {
            message = error.explanation
        }
    }

    private func assign(_ person: Person, for pick: Pick) async {
        guard let client = session.client else { return }
        do {
            switch pick {
            case .move(let face):
                try await client.reassignFace(face.id, to: person.id)
            case .add(let rect):
                guard let image else { return }
                // Boxes are in the pixels of the image they were drawn on: the preview, like Immich web.
                let width = image.size.width * image.scale, height = image.size.height * image.scale
                try await client.createFace(asset: assetID, person: person.id, imageWidth: Int(width), imageHeight: Int(height),
                                            box: CGRect(x: rect.minX * width, y: rect.minY * height,
                                                        width: rect.width * width, height: rect.height * height))
                adding = false
            }
            await loadFaces()
        } catch {
            message = error.explanation
        }
    }

    private func remove(_ face: Face) async {
        do {
            try await session.client?.deleteFace(face.id)
            await loadFaces()
        } catch {
            message = error.explanation
        }
    }
}

/// Choose who a face belongs to, or make a new person named after the search.
struct FacePersonPicker: View {
    let onPick: (Person) async -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Button { Task { await create() } } label: {
                    Label(name.isEmpty ? "New Person" : "New Person “\(name)”", systemImage: "person.badge.plus")
                }
                ForEach(matches) { person in
                    Button { Task { await pick(person) } } label: {
                        HStack {
                            PersonPhoto(id: person.id).frame(width: 44, height: 44).clipShape(.circle)
                            Text(person.name.isEmpty ? "Unnamed" : person.name)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "Name")
            .overlay { if let error { Text(error).foregroundStyle(.secondary).padding() } }
            .navigationTitle("Choose Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel", role: .cancel) { dismiss() } }
        }
        .task {
            do {
                people = try await session.client?.people() ?? []
            } catch {
                self.error = error.explanation
            }
        }
    }

    private var name: String { search.trimmingCharacters(in: .whitespaces) }

    /// Named people first, alphabetically; hidden people stay pickable, as on the web.
    private var matches: [Person] {
        people.filter { name.isEmpty || $0.name.localizedCaseInsensitiveContains(name) }
            .sorted { ($0.name.isEmpty ? 1 : 0, $0.name) < ($1.name.isEmpty ? 1 : 0, $1.name) }
    }

    private func pick(_ person: Person) async {
        dismiss()
        await onPick(person)
    }

    private func create() async {
        do {
            guard let person = try await session.client?.createPerson(name: name) else { return }
            await pick(person)
        } catch {
            self.error = error.explanation
        }
    }
}

/// One face as `GET /faces` returns it. The box is in pixels of an image `imageWidth` × `imageHeight`.
struct Face: Decodable, Identifiable {
    var id: String
    var imageWidth: Int?
    var imageHeight: Int?
    var boundingBoxX1: Int?
    var boundingBoxY1: Int?
    var boundingBoxX2: Int?
    var boundingBoxY2: Int?
    var person: Person?

    var name: String { person.map { $0.name.isEmpty ? "Unnamed" : $0.name } ?? "Unnamed" }

    /// The box as fractions of the photo, so it lands in the right place at any display size.
    var rect: CGRect? {
        guard let width = imageWidth, let height = imageHeight, width > 0, height > 0,
              let x1 = boundingBoxX1, let y1 = boundingBoxY1, let x2 = boundingBoxX2, let y2 = boundingBoxY2 else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: CGFloat(x1) / w, y: CGFloat(y1) / h, width: CGFloat(x2 - x1) / w, height: CGFloat(y2 - y1) / h)
    }
}

private extension CGRect {
    /// A rectangle of fractions turned into points inside `size`.
    func scaled(to size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }
}

/// Endpoints for editing the faces on a photo.
extension ImmichClient {
    func faces(asset: String) async throws -> [Face] {
        try await get("/faces", query: ["id": asset])
    }

    /// The path names the person the face moves to; the body names the face.
    func reassignFace(_ face: String, to person: String) async throws {
        try await call("PUT", "/faces/\(person)", body: ["id": face])
    }

    /// `force: false`, like the web app: the server soft-deletes the face.
    func deleteFace(_ id: String) async throws {
        try await call("DELETE", "/faces/\(id)", body: ["force": false])
    }

    /// A face the server missed. `box` is in pixels of an image `imageWidth` × `imageHeight`.
    func createFace(asset: String, person: String, imageWidth: Int, imageHeight: Int, box: CGRect) async throws {
        try await call("POST", "/faces", body: [
            "assetId": asset, "personId": person, "imageWidth": imageWidth, "imageHeight": imageHeight,
            "x": Int(box.minX), "y": Int(box.minY), "width": Int(box.width), "height": Int(box.height),
        ])
    }

    /// An empty name makes an unnamed person.
    func createPerson(name: String) async throws -> Person {
        try await fetch("POST", "/people", body: name.isEmpty ? [:] as [String: Any] : ["name": name])
    }
}
