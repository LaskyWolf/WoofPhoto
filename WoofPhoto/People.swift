import SwiftUI

/// Everyone Immich recognised, as a grid of faces. Favorites first, hidden people behind a switch.
struct PeopleView: View {
    @Environment(Session.self) private var session
    @State private var people: [Person]?
    @State private var showsHidden = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.sectionGap) {
                PetsSection()
                if !shown.isEmpty {
                    Text("People").font(.title3.bold()).padding(.horizontal, Tokens.screenPadding)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 20) {
                        ForEach(shown) { PersonTile(person: $0, size: nil) }
                    }
                    .padding(.horizontal, Tokens.screenPadding)
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if people == nil, error == nil { ProgressView() }
            if let error { ContentUnavailableView("Can't Load People", systemImage: "exclamationmark.triangle", description: Text(error)) }
        }
        .navigationTitle("People & Pets")
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
    /// Fixed width in a row; nil fills a grid column.
    var size: CGFloat? = 88
    /// WoofMusic's list layout: a small round photo beside the name.
    var isRow = false
    @Environment(\.shelfZoom) private var shelfZoom

    var body: some View {
        let shelf = Shelf.person(id: person.id, name: person.name)
        NavigationLink(value: shelf) {
            if isRow {
                HStack(spacing: 12) {
                    PersonPhoto(id: person.id)
                        .frame(width: 72, height: 72)
                        .clipShape(.circle)
                    Text(person.name.isEmpty ? "Add Name" : person.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            } else {
            VStack(spacing: 6) {
                PersonPhoto(id: person.id)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.circle)
                    .overlay(alignment: .bottomTrailing) {
                        if person.isFavorite == true {
                            Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2).accessibilityLabel("Favorite")
                        }
                    }
                    .opacity(person.isHidden == true ? 0.4 : 1)
                Text(person.name.isEmpty ? "Add Name" : person.name)
                    .font(.subheadline)
                    .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .frame(width: size)
            }
        }
        .buttonStyle(.plain)
        .zoomSource(shelf, in: shelfZoom)
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
            .contentShape(.rect)
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
    @State private var playsSlideshow = false
    @State private var slideshow: [AssetRef] = []

    init(id: String, name: String) {
        self.id = id
        _name = State(initialValue: name)
        _timeline = State(initialValue: Timeline(.person(id)))
    }

    var body: some View {
        AssetGrid(timeline: timeline, hero: AnyView(hero))
            .detailBarTitle(name.isEmpty ? "Add Name" : name)
            .fullScreenCover(isPresented: $playsSlideshow) { Slideshow(assets: slideshow, start: 0) }
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

    /// WoofMusic's artist header: the face in a circle, the name, the count, then More, Shuffle and Play.
    private var hero: some View {
        DetailHeader(meta: "Person", title: name.isEmpty ? "Add Name" : name, circle: true) {
            PersonPhoto(id: id)
        } secondary: {
            if timeline.months != nil {
                Text("\(timeline.count.formatted()) Items").font(.subheadline).foregroundStyle(.secondary)
            }
        } buttons: {
            Menu {
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
            } label: {
                RoundIcon(systemImage: "ellipsis")
            }
            .accessibilityLabel("More")
            if !timeline.assets.isEmpty {
                Button { play(timeline.assets.shuffled()) } label: { RoundIcon(systemImage: "shuffle") }
                    .accessibilityLabel("Shuffle Slideshow")
                Button { play(timeline.assets) } label: { RoundIcon(systemImage: "play.fill", filled: true) }
                    .accessibilityLabel("Play Slideshow")
            }
        }
    }

    private func play(_ assets: [AssetRef]) {
        slideshow = assets
        playsSlideshow = true
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
