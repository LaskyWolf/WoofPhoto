import SwiftUI

/// The Search tab: smart search as you type, text found in photos, dates, people, places and albums,
/// with filters for media type, dates, camera and favorites.
struct SearchView: View {
    enum Scope: String, CaseIterable {
        case everything = "Everything", text = "Text in Photo", fileName = "File Name"
    }

    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var scope = Scope.everything
    @State private var filters = SearchFilters()
    @State private var showsFilters = false
    @State private var results: Timeline?
    @State private var searching = false
    @State private var error: String?
    @State private var people: [Person] = []
    @State private var albums: [Album] = []
    @State private var cities: [Asset] = []
    @AppStorage("search.recent") private var recent = ""
    @State private var pins = Pins()

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty && !filters.isActive {
                    suggestions
                } else {
                    resultsView
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Photos, People, Places…")
            .searchScopes($scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) }
            }
            .onSubmit(of: .search) { remember(query) }
            .toolbar {
                Button("Filters", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                    showsFilters = true
                }
            }
            .sheet(isPresented: $showsFilters) { FiltersSheet(filters: $filters) }
            .navigationDestination(for: Shelf.self) { $0.destination }
            .task(id: SearchKey(query: query, scope: scope, filters: filters)) { await search() }
            .task { await loadSuggestions() }
        }
        .environment(pins)
    }

    // MARK: Suggestions

    private var suggestions: some View {
        List {
            if !recent.isEmpty {
                Section("Recent Searches") {
                    ForEach(recent.split(separator: "\n").map(String.init), id: \.self) { text in
                        Button(text, systemImage: "clock") { query = text }
                    }
                    Button("Clear", role: .destructive) { recent = "" }
                }
            }
            if !people.isEmpty {
                Section("People") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(people.prefix(30)) { PersonTile(person: $0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            if !cities.isEmpty {
                Section("Places") {
                    ForEach(cities.prefix(30)) { asset in
                        if let city = asset.exifInfo?.city {
                            NavigationLink {
                                SearchedGrid(title: city) { try await $0.searchMetadata(["city": city]) }
                            } label: {
                                HStack {
                                    Thumbnail(asset: asset.ref).frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6))
                                    Text(city)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder private var resultsView: some View {
        let matches = query.count < 2 ? [] : people.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let albumMatches = query.count < 2 ? [] : albums.filter { $0.albumName.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            if !matches.isEmpty || !albumMatches.isEmpty || dateRange != nil {
                ScrollView(.horizontal) {
                    HStack {
                        if let dateRange {
                            NavigationLink {
                                SearchedGrid(title: dateRange.title) {
                                    try await $0.searchMetadata(["takenAfter": dateRange.start.formatted(.iso8601),
                                                                 "takenBefore": dateRange.end.formatted(.iso8601)])
                                }
                            } label: { chip(dateRange.title, symbol: "calendar") }
                        }
                        ForEach(matches) { person in
                            NavigationLink(value: Shelf.person(id: person.id, name: person.name)) { chip(person.name, symbol: "person.crop.circle") }
                        }
                        ForEach(albumMatches) { album in
                            NavigationLink(value: Shelf.album(id: album.id, name: album.albumName)) { chip(album.albumName, symbol: "rectangle.stack") }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
            if let results, results.count > 0 {
                AssetGrid(timeline: results)
            } else if searching {
                ProgressView().frame(maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results != nil {
                ContentUnavailableView.search(text: query)
            } else {
                Spacer()
            }
        }
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: .capsule)
    }

    /// "2023" or "May 2023" typed in the field, as a date range.
    private var dateRange: (title: String, start: Date, end: Date)? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        for format in ["MMMM yyyy", "MMM yyyy", "yyyy"] {
            formatter.dateFormat = format
            guard let start = formatter.date(from: text) else { continue }
            let end = calendar.date(byAdding: format == "yyyy" ? .year : .month, value: 1, to: start) ?? start
            return ("Photos from \(text)", start, end)
        }
        return nil
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let client = session.client, !text.isEmpty || filters.isActive else {
            results = nil
            return
        }
        // wait for a pause in typing, so each keystroke doesn't start a search
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        error = nil
        do {
            var body = filters.body
            let assets: [Asset]
            switch scope {
            case .everything where !text.isEmpty:
                assets = try await client.searchSmart(text, filters: body)
            case .text where !text.isEmpty:
                body["ocr"] = text
                assets = try await client.searchMetadata(body, limit: 1000)
            case .fileName where !text.isEmpty:
                body["originalFileName"] = text
                assets = try await client.searchMetadata(body, limit: 1000)
            default:
                assets = try await client.searchMetadata(body, limit: 2000)
            }
            guard !Task.isCancelled else { return }
            results = Timeline(assets: assets.reversed().map(\.ref))
        } catch {
            if !Task.isCancelled { self.error = error.explanation }
        }
    }

    private func loadSuggestions() async {
        guard let client = session.client else { return }
        people = ((try? await client.people()) ?? []).filter { !$0.name.isEmpty && $0.isHidden != true }
        albums = (try? await client.albums()) ?? []
        cities = (try? await client.get("/search/cities")) ?? []
    }

    private func remember(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let list = [text] + recent.split(separator: "\n").map(String.init).filter { $0 != text }
        recent = list.prefix(8).joined(separator: "\n")
    }
}

/// What restarts a search when it changes.
private struct SearchKey: Equatable {
    var query: String
    var scope: SearchView.Scope
    var filters: SearchFilters
}

struct SearchFilters: Equatable {
    enum Media: String, CaseIterable {
        case all = "All", photos = "Photos", videos = "Videos"
    }

    var media = Media.all
    var after: Date?
    var before: Date?
    var make = ""
    var model = ""
    var favoritesOnly = false

    var isActive: Bool { self != SearchFilters() }

    /// The filters as Immich search fields.
    var body: [String: Any] {
        var body: [String: Any] = [:]
        if media != .all { body["type"] = media == .photos ? "IMAGE" : "VIDEO" }
        if let after { body["takenAfter"] = after.formatted(.iso8601) }
        if let before { body["takenBefore"] = before.formatted(.iso8601) }
        if !make.isEmpty { body["make"] = make }
        if !model.isEmpty { body["model"] = model }
        if favoritesOnly { body["isFavorite"] = true }
        return body
    }
}

struct FiltersSheet: View {
    @Binding var filters: SearchFilters

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var makes: [String] = []
    @State private var models: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Picker("Media", selection: $filters.media) {
                    ForEach(SearchFilters.Media.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Section("Date") {
                    optionalDate("From", $filters.after)
                    optionalDate("To", $filters.before)
                }
                Section("Camera") {
                    Picker("Make", selection: $filters.make) {
                        Text("Any").tag("")
                        ForEach(makes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Model", selection: $filters.model) {
                        Text("Any").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Favorites Only", isOn: $filters.favoritesOnly)
                Button("Reset Filters", role: .destructive) { filters = SearchFilters() }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", role: .confirm) { dismiss() } }
            .task(id: filters.make) {
                guard let client = session.client else { return }
                makes = (try? await client.get("/search/suggestions", query: ["type": "camera-make"])) ?? []
                var query = ["type": "camera-model"]
                if !filters.make.isEmpty { query["make"] = filters.make }
                models = (try? await client.get("/search/suggestions", query: query)) ?? []
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionalDate(_ title: String, _ date: Binding<Date?>) -> some View {
        Toggle(isOn: Binding { date.wrappedValue != nil } set: { date.wrappedValue = $0 ? .now : nil }) {
            if let value = date.wrappedValue {
                DatePicker(title, selection: Binding { value } set: { date.wrappedValue = $0 }, displayedComponents: .date)
            } else {
                Text(title)
            }
        }
    }
}
