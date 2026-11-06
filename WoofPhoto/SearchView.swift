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

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty && !filters.isActive {
                    suggestions
                } else {
                    resultsView
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .stickyHeader {
                TabHeader(title: "Search") {
                    HeaderButton(label: "Filters", systemImage: "line.3.horizontal.decrease", isOn: filters.isActive) { showsFilters = true }
                }
                FilterChips(items: Scope.allCases, selection: $scope) { $0.rawValue }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsFilters) { FiltersSheet(filters: $filters) }
            .navigationDestination(for: Shelf.self) { $0.destination }
            .task(id: SearchKey(query: query, scope: scope, filters: filters)) { await search() }
            .task { await loadSuggestions() }
        }
        .searchable(text: $query, prompt: "Photos, people, places")
        .autocorrectionDisabled()
        .onSubmit(of: .search) { remember(query) }
    }

    // MARK: Suggestions

    private var suggestions: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !recent.isEmpty {
                    // WoofMusic's history: a plain header, then one row per search
                    HStack {
                        Text("Recently Searched").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Clear") { withAnimation { recent = "" } }.font(.subheadline).foregroundStyle(.tint)
                    }
                    .padding(.horizontal, Tokens.screenPadding)
                    .padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(recent.split(separator: "\n").map(String.init), id: \.self) { text in
                            Button { query = text } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90").foregroundStyle(.tint)
                                    Text(text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, Tokens.screenPadding)
                                .padding(.vertical, 12)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .liftedMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { forget(text) }
                            }
                        }
                    }
                }
                if !people.isEmpty {
                    sectionTitle("People and Pets") {
                        NavigationLink("See All") { PeopleView() }.font(.subheadline.weight(.semibold))
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(people.prefix(30)) { PersonTile(person: $0) }
                        }
                        .padding(.horizontal, Tokens.screenPadding)
                    }
                    .scrollIndicators(.hidden)
                }
                if !cities.isEmpty {
                    sectionTitle("Places") { EmptyView() }
                    PlacesMosaic(cities: cities.filter { $0.exifInfo?.city != nil }.prefix(32).map { $0 })
                        .padding(.horizontal, Tokens.screenPadding)
                }
            }
            .padding(.bottom, Tokens.sectionGap)
        }
    }

    private func sectionTitle<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Tokens.screenPadding)
        .padding(.top, 16)
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
                            .buttonStyle(ZoomPressStyle())
                        }
                        ForEach(matches) { person in
                            NavigationLink(value: Shelf.person(id: person.id, name: person.name)) { chip(person.name, symbol: "person.crop.circle") }
                                .buttonStyle(ZoomPressStyle())
                        }
                        ForEach(albumMatches) { album in
                            NavigationLink(value: Shelf.album(id: album.id, name: album.albumName)) { chip(album.albumName, symbol: "rectangle.stack") }
                                .buttonStyle(ZoomPressStyle())
                        }
                    }
                    .padding(.horizontal, Tokens.screenPadding)
                    .padding(.bottom, 8)
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
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minHeight: Tokens.controlHeight)
        .background(Color(.systemGray5), in: .capsule)
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

    private func forget(_ text: String) {
        withAnimation { recent = recent.split(separator: "\n").map(String.init).filter { $0 != text }.joined(separator: "\n") }
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

/// Search's places as a mosaic: blocks of eight tiles in big, wide, tall and square shapes on a four-column grid.
private struct PlacesMosaic: View {
    let cities: [Asset]
    private static let gap: CGFloat = 6
    @State private var column: CGFloat = 80

    var body: some View {
        let gap = Self.gap
        let full = cities.count / 8 * 8
        // the server sends one photo per city and no count, so the shapes follow a fixed pattern, not popularity
        VStack(spacing: gap) {
            ForEach(Array(stride(from: 0, to: full, by: 8)), id: \.self) { i in
                let c = Array(cities[i..<i + 8])
                HStack(spacing: gap) {
                    tile(c[0], columns: 2, rows: 2)
                    VStack(spacing: gap) {
                        tile(c[1], columns: 2, rows: 1)
                        HStack(spacing: gap) { tile(c[2], columns: 1, rows: 1); tile(c[3], columns: 1, rows: 1) }
                    }
                }
                HStack(spacing: gap) {
                    tile(c[4], columns: 1, rows: 2)
                    VStack(spacing: gap) {
                        tile(c[5], columns: 3, rows: 1)
                        HStack(spacing: gap) { tile(c[6], columns: 2, rows: 1); tile(c[7], columns: 1, rows: 1) }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible())], spacing: gap) {
                ForEach(cities[full...]) { tile($0, columns: 2, rows: 1) }
            }
        }
        // full width first, so the measure is the space offered, not the tiles' own size
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { ($0.size.width - gap * 3) / 4 } action: { column = max($0, 1) }
    }

    private func tile(_ asset: Asset, columns: CGFloat, rows: CGFloat) -> some View {
        let city = asset.exifInfo?.city ?? ""
        return NavigationLink {
            SearchedGrid(title: city) { try await $0.searchMetadata(["city": city]) }
        } label: {
            Color.clear
                .frame(width: column * columns + Self.gap * (columns - 1), height: column * rows + Self.gap * (rows - 1))
                .overlay { Thumbnail(asset: asset.ref, size: "preview") }
                .overlay(alignment: .bottomLeading) {
                    Text(city)
                        .font(columns * rows >= 4 ? .title3.bold() : .subheadline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(.rect(cornerRadius: Tokens.tileRadius))
        }
        .buttonStyle(ZoomPressStyle())
    }
}
