import SwiftUI

/// Everyone Immich recognised, as a grid of faces. Favorites first, hidden people behind a switch.
struct PeopleView: View {
    @Environment(Session.self) private var session
    @State private var people: [Person]?
    @State private var showsHidden = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
                ForEach(shown) { PersonTile(person: $0) }
            }
            .padding()
        }
        .overlay {
            if people == nil, error == nil { ProgressView() }
            if let error { ContentUnavailableView("Can't Load People", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
        .navigationTitle("People")
        .toolbar {
            Toggle("Show Hidden", systemImage: "eye.slash", isOn: $showsHidden)
        }
        .task {
            do {
                people = try await session.client?.people()
            } catch {
                self.error = error.explanation
            }
        }
    }

    private var shown: [Person] {
        (people ?? []).filter { showsHidden || $0.isHidden != true }
            .sorted { ($0.isFavorite == true ? 0 : 1, $0.name.isEmpty ? 1 : 0, $0.name) < ($1.isFavorite == true ? 0 : 1, $1.name.isEmpty ? 1 : 0, $1.name) }
    }
}

struct PersonTile: View {
    let person: Person
    @Environment(Pins.self) private var pins

    var body: some View {
        NavigationLink(value: Shelf.person(id: person.id, name: person.name)) {
            VStack(spacing: 6) {
                PersonPhoto(id: person.id)
                    .frame(width: 88, height: 88)
                    .clipShape(.circle)
                    .overlay(alignment: .bottomTrailing) {
                        if person.isFavorite == true {
                            Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2)
                        }
                    }
                    .opacity(person.isHidden == true ? 0.4 : 1)
                Text(person.name.isEmpty ? "Add Name" : person.name)
                    .font(.subheadline)
                    .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
        .pinnable(.person(id: person.id, name: person.name), pins: pins)
    }
}

/// The face Immich picked for a person.
struct PersonPhoto: View {
    let id: String
    @Environment(Session.self) private var session
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image = image ?? ImageCache.image(id, size: "person") {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: id) {
                guard ImageCache.image(id, size: "person") == nil,
                      let data = try? await session.client?.personImage(id), let image = UIImage(data: data) else { return }
                ImageCache.store(image, for: id, size: "person")
                self.image = image
            }
    }
}

/// One person's photos, with rename, birthday, favorite, hide and merge.
struct PersonView: View {
    let id: String

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var timeline: Timeline
    @State private var renaming = false
    @State private var newName = ""
    @State private var editsBirthday = false
    @State private var birthday = Date.now
    @State private var merging = false
    @State private var message: String?

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
        _timeline = State(initialValue: Timeline(.person(id)))
    }

    var body: some View {
        AssetGrid(timeline: timeline)
            .navigationTitle(name.isEmpty ? "Add Name" : name)
            .navigationSubtitle(timeline.months == nil ? "" : "\(timeline.count.formatted()) Items")
            .toolbar {
                Menu("More", systemImage: "ellipsis") {
                    Button("Rename", systemImage: "pencil") {
                        newName = name
                        renaming = true
                    }
                    Button("Set Birthday", systemImage: "birthday.cake") { editsBirthday = true }
                    Button("Favorite", systemImage: "heart") { Task { await update(["isFavorite": true], done: "Added to favorites.") } }
                    Button("Merge with…", systemImage: "arrow.triangle.merge") { merging = true }
                    Button("Hide", systemImage: "eye.slash") {
                        Task {
                            await update(["isHidden": true], done: nil)
                            dismiss()
                        }
                    }
                }
            }
            .alert("Name", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    Task {
                        await update(["name": newName], done: nil)
                        name = newName
                    }
                }
            }
            .sheet(isPresented: $editsBirthday) {
                NavigationStack {
                    DatePicker("Birthday", selection: $birthday, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("Birthday")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            Button("Save", role: .confirm) {
                                editsBirthday = false
                                let text = birthday.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
                                Task { await update(["birthDate": text], done: "Birthday saved.") }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $merging) {
                MergePicker(source: id) { dismiss() }
            }
            .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {}
    }

    private func update(_ fields: [String: Any], done: String?) async {
        do {
            try await session.client?.updatePerson(id, fields)
            message = done
        } catch {
            message = error.explanation
        }
    }
}

/// Pick the person this one is the same as; all faces move there.
struct MergePicker: View {
    let source: String
    let onMerged: () -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(people.filter { $0.id != source && !$0.name.isEmpty }) { person in
                Button {
                    Task { await merge(into: person) }
                } label: {
                    HStack {
                        PersonPhoto(id: person.id).frame(width: 44, height: 44).clipShape(.circle)
                        Text(person.name)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay { if let error { Text(error).foregroundStyle(.secondary).padding() } }
            .navigationTitle("Merge with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel", role: .cancel) { dismiss() } }
        }
        .task { people = (try? await session.client?.people()) ?? [] }
    }

    private func merge(into person: Person) async {
        do {
            try await session.client?.merge([source], into: person.id)
            dismiss()
            onMerged()
        } catch {
            self.error = error.explanation
        }
    }
}
