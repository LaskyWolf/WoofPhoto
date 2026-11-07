import SwiftUI

/// The Search tab: smart search as you type, text found in photos, dates, people, places and albums,
/// with filters for media type, dates, places, camera, albums, tags, text and favorites, shown as removable chips.
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
            if !matches.isEmpty || !albumMatches.isEmpty || dateRange != nil || filters.isActive {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(filters.chips) { active in
                            Button {
                                withAnimation(.snappy) { active.clear(&filters) }
                            } label: {
                                chip(active.title, symbol: active.symbol, removes: true)
                            }
                            .buttonStyle(ZoomPressStyle())
                            .accessibilityLabel("Remove filter \(active.title)")
                        }
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

    /// `removes`: an active filter, with an x that says tapping takes it off.
    private func chip(_ title: String, symbol: String, removes: Bool = false) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.primary)
                if removes { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
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

    /// Waits for a pause in typing, then searches with what the field and the Filters sheet hold.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard session.client != nil, !text.isEmpty || filters.isActive else {
            results = nil
            return
        }
        // so each keystroke doesn't start a search
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        // ponytail: 3+ words means a sentence; shorter text goes straight to smart search
        if scope == .everything, text.split(separator: " ").count >= 3, let parsed = await Intelligence.searchQuery(text) {
            guard !Task.isCancelled else { return }
            var combined = filters
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            if combined.city.isEmpty { combined.city = parsed.city }
            if combined.country.isEmpty { combined.country = parsed.country }
            if combined.after == nil { combined.after = day.date(from: parsed.after) }
            if combined.before == nil { combined.before = day.date(from: parsed.before) }
            if combined.media == .all { combined.media = parsed.media == "photos" ? .photos : parsed.media == "videos" ? .videos : .all }
            await performSearch(text: parsed.subject, scope: scope, filters: combined)
            return
        }
        await performSearch(text: text, scope: scope, filters: filters)
    }

    /// Runs one search and shows its results. Without text the filters alone pick the photos; with text,
    /// `scope` sends it to smart search, the text Immich read in photos, or file names, narrowed by the same filters.
    private func performSearch(text: String, scope: Scope, filters: SearchFilters) async {
        guard let client = session.client else { return }
        searching = true
        defer { searching = false }
        error = nil
        do {
            var filter = filters.filter
            let assets: [Asset]
            switch scope {
            case .everything where !text.isEmpty:
                assets = try await client.searchAssets(matching: text, filter: filter)
            case .text where !text.isEmpty:
                filter["ocr"] = ["matches": text]
                assets = try await client.searchAssets(filter: filter, limit: 1000)
            case .fileName where !text.isEmpty:
                filter["originalFileName"] = ["like": text]
                assets = try await client.searchAssets(filter: filter, limit: 1000)
            default:
                assets = try await client.searchAssets(filter: filter)
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

/// Everything the Filters sheet can narrow a search by. Sent as Immich's structured search filter (3.2+).
struct SearchFilters: Equatable {
    enum Media: String, CaseIterable {
        case all = "All", photos = "Photos", videos = "Videos"
    }

    var media = Media.all
    var after: Date?
    var before: Date?
    var country = ""
    var state = ""
    var city = ""
    var make = ""
    var model = ""
    var lens = ""
    var tags: [AssetTag] = []
    var album: Album?
    var notInAlbum = false
    var favoritesOnly = false
    var fileName = ""
    var details = ""

    var isActive: Bool { self != SearchFilters() }

    /// The text filters: search field, chip symbol, and whether the server matches part of the text.
    private static let texts: [(field: String, path: WritableKeyPath<SearchFilters, String>, symbol: String, partial: Bool)] = [
        ("country", \.country, "globe", false), ("state", \.state, "map", false), ("city", \.city, "mappin.and.ellipse", false),
        ("make", \.make, "camera", false), ("model", \.model, "camera", false), ("lensModel", \.lens, "camera.aperture", false),
        ("originalFileName", \.fileName, "doc", true), ("description", \.details, "text.alignleft", true),
    ]

    /// The filters as Immich's `filter` object. Leaves out trashed items and the hidden halves of Live Photos.
    var filter: [String: Any] {
        var filter: [String: Any] = ["trashedAt": ["eq": NSNull()], "visibility": ["in": ["timeline", "archive"]]]
        if media != .all { filter["type"] = ["eq": media == .photos ? "IMAGE" : "VIDEO"] }
        // whole days: from the start of the first to the end of the last
        let calendar = Calendar.current
        var taken: [String: String] = [:]
        if let after { taken["gte"] = calendar.startOfDay(for: after).formatted(.iso8601) }
        if let before, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: before)) {
            taken["lt"] = end.formatted(.iso8601)
        }
        if !taken.isEmpty { filter["takenAt"] = taken }
        for text in Self.texts where !self[keyPath: text.path].isEmpty {
            filter[text.field] = [(text.partial ? "like" : "eq"): self[keyPath: text.path]]
        }
        if !tags.isEmpty { filter["tagIds"] = ["all": tags.map(\.id)] }
        if notInAlbum {
            filter["hasAlbums"] = ["eq": false]
        } else if let album {
            filter["albumIds"] = ["any": [album.id]]
        }
        if favoritesOnly { filter["isFavorite"] = ["eq": true] }
        return filter
    }

    /// One active filter, shown as a chip that removes it.
    struct Chip: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let clear: (inout SearchFilters) -> Void
    }

    var chips: [Chip] {
        var chips: [Chip] = []
        if media != .all { chips.append(Chip(id: "media", title: media.rawValue, symbol: media == .photos ? "photo" : "video") { $0.media = .all }) }
        if after != nil || before != nil {
            let day = { (date: Date?) in date?.formatted(date: .abbreviated, time: .omitted) ?? "…" }
            chips.append(Chip(id: "date", title: "\(day(after)) – \(day(before))", symbol: "calendar") { $0.after = nil; $0.before = nil })
        }
        for text in Self.texts where !self[keyPath: text.path].isEmpty {
            let path = text.path
            chips.append(Chip(id: text.field, title: self[keyPath: path], symbol: text.symbol) { $0[keyPath: path] = "" })
        }
        for tag in tags {
            chips.append(Chip(id: "tag-\(tag.id)", title: tag.path, symbol: "tag") { filters in filters.tags.removeAll { $0.id == tag.id } })
        }
        if notInAlbum {
            chips.append(Chip(id: "notInAlbum", title: "Not in an Album", symbol: "rectangle.stack.badge.minus") { $0.notInAlbum = false })
        } else if let album {
            chips.append(Chip(id: "album", title: album.albumName, symbol: "rectangle.stack") { $0.album = nil })
        }
        if favoritesOnly { chips.append(Chip(id: "favorites", title: "Favorites", symbol: "heart") { $0.favoritesOnly = false }) }
        return chips
    }
}

struct FiltersSheet: View {
    @Binding var filters: SearchFilters

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var countries: [String] = []
    @State private var states: [String] = []
    @State private var cities: [String] = []
    @State private var makes: [String] = []
    @State private var models: [String] = []
    @State private var lenses: [String] = []
    @State private var albums: [Album] = []
    @State private var tags: [AssetTag] = []
    @State private var showsTags = false

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
                Section("Place") {
                    choice("Country", $filters.country, countries)
                    choice("State", $filters.state, states)
                    choice("City", $filters.city, cities)
                }
                Section("Camera") {
                    choice("Make", $filters.make, makes)
                    choice("Model", $filters.model, models)
                    choice("Lens", $filters.lens, lenses)
                }
                Section("Albums") {
                    Picker("Album", selection: $filters.album) {
                        Text("Any").tag(Album?.none)
                        ForEach(albums) { Text($0.albumName).tag(Optional($0)) }
                    }
                    .disabled(filters.notInAlbum)
                    Toggle("Not in Any Album", isOn: $filters.notInAlbum)
                }
                if showsTags {
                    NavigationLink {
                        TagChecklist(tags: tags, selection: $filters.tags)
                    } label: {
                        LabeledContent("Tags", value: filters.tags.isEmpty ? "Any" : filters.tags.map(\.title).joined(separator: ", "))
                    }
                }
                Section("Text") {
                    TextField("File Name", text: $filters.fileName)
                    TextField("Description", text: $filters.details)
                }
                Toggle("Favorites Only", isOn: $filters.favoritesOnly)
                Button("Reset Filters", role: .destructive) { filters = SearchFilters() }
            }
            .autocorrectionDisabled()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", role: .confirm) { dismiss() } }
            // each list narrows to the place or camera picked above it
            .task(id: [filters.country, filters.state, filters.make, filters.model]) {
                guard let client = session.client else { return }
                let f = filters
                async let countries = client.suggestions("country")
                async let states = client.suggestions("state", ["country": f.country])
                async let cities = client.suggestions("city", ["country": f.country, "state": f.state])
                async let makes = client.suggestions("camera-make")
                async let models = client.suggestions("camera-model", ["make": f.make])
                async let lenses = client.suggestions("camera-lens-model", ["make": f.make, "model": f.model])
                self.countries = (try? await countries) ?? []
                self.states = (try? await states) ?? []
                self.cities = (try? await cities) ?? []
                self.makes = (try? await makes) ?? []
                self.models = (try? await models) ?? []
                self.lenses = (try? await lenses) ?? []
            }
            .task {
                guard let client = session.client else { return }
                albums = ((try? await client.albums()) ?? []).sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
                showsTags = await tagsEnabled(client)
                if showsTags { tags = (try? await client.tags()) ?? [] }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// A menu of the server's values, with Any on top. A value picked earlier stays listed while its list loads.
    private func choice(_ title: String, _ value: Binding<String>, _ options: [String]) -> some View {
        Picker(title, selection: value) {
            Text("Any").tag("")
            ForEach(options.contains(value.wrappedValue) || value.wrappedValue.isEmpty ? options : [value.wrappedValue] + options, id: \.self) {
                Text($0).tag($0)
            }
        }
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
