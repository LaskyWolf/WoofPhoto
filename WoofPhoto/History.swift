import Photos
import SwiftUI

/// One thing done in the app: a photo viewed, edited, deleted, favorited, hidden, archived, or moved in or out of an album.
struct HistoryEntry: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case viewed, edited, deleted, deletedForGood, recovered, favorited, unfavorited
        case hidden, unhidden, archived, addedToAlbum, removedFromAlbum

        var title: String {
            switch self {
            case .viewed: "Viewed"
            case .edited: "Edited"
            case .deleted: "Moved to Recently Deleted"
            case .deletedForGood: "Deleted for Good"
            case .recovered: "Recovered"
            case .favorited: "Added to Favorites"
            case .unfavorited: "Removed from Favorites"
            case .hidden: "Hidden"
            // out of Hidden or Archive: the server doesn't say which
            case .unhidden: "Moved to Library"
            case .archived: "Archived"
            case .addedToAlbum: "Added to an Album"
            case .removedFromAlbum: "Removed from an Album"
            }
        }

        var symbol: String {
            switch self {
            case .viewed: "eye"
            case .edited: "slider.horizontal.3"
            case .deleted, .deletedForGood: "trash"
            case .recovered: "arrow.uturn.backward"
            case .favorited, .unfavorited: "heart"
            case .hidden, .unhidden: "eye.slash"
            case .archived: "archivebox"
            case .addedToAlbum, .removedFromAlbum: "rectangle.stack"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let assetID: String
    var localID: String?
    var name: String?
    var albumID: String?
    /// For an edit: the new item it uploaded, `edits` for an Immich edit, `device` for one saved into Photos.
    var editID: String?
    var date = Date.now
    var undone = false

    var canUndo: Bool { !undone && ![.viewed, .deletedForGood, .unhidden].contains(kind) && !(kind == .edited && editID == nil) }

    var asset: AssetRef { AssetRef(id: assetID, localID: localID) }
}

/// Everything done in the app, newest first, kept in a file on this iPhone only.
@MainActor @Observable
final class History {
    static let shared = History()
    /// Keeps the file small; the oldest entries go first.
    private static let limit = 5000
    private static let file = URL.applicationSupportDirectory.appending(path: "history.json")

    private(set) var entries: [HistoryEntry] = []
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: Self.file) {
            entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    static var isPaused: Bool { UserDefaults.standard.bool(forKey: "history.paused") }

    func record(_ entry: HistoryEntry) {
        guard !Self.isPaused else { return }
        // paging back and forth over the same photo is one view
        if entry.kind == .viewed, let last = entries.first, last.kind == .viewed, last.assetID == entry.assetID { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func record(_ kind: HistoryEntry.Kind, _ ids: [String], albumID: String? = nil) {
        for id in ids { record(HistoryEntry(kind: kind, assetID: id, albumID: albumID)) }
    }

    func markUndone(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].undone = true
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Writes a second after the last change, so paging through photos doesn't write on every page.
    private func save() {
        saveTask?.cancel()
        let entries = entries
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
        }
    }

    /// Does the opposite of the entry.
    static func undo(_ entry: HistoryEntry, client: ImmichClient?) async throws {
        if entry.editID == "device", let localID = entry.localID {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { return }
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).revertAssetContentToOriginal() }
            return
        }
        guard let client else { return }
        let ids = [entry.assetID]
        switch entry.kind {
        case .viewed, .deletedForGood, .unhidden: return
        case .edited:
            if entry.editID == "edits" {
                try await client.call("DELETE", "/assets/\(entry.assetID)/edits")
            } else if let copy = entry.editID {
                try await client.deleteAssets([copy])
                // a new key photo moved the original to Recently Deleted
                try? await client.restoreTrash(ids)
            }
        case .deleted: try await client.restoreTrash(ids)
        case .recovered: try await client.deleteAssets(ids)
        case .favorited: try await client.updateAssets(ids, ["isFavorite": false])
        case .unfavorited: try await client.updateAssets(ids, ["isFavorite": true])
        case .hidden, .archived: try await client.updateAssets(ids, ["visibility": "timeline"])
        case .addedToAlbum: if let album = entry.albumID { try await client.removeFromAlbum(album, assets: ids) }
        case .removedFromAlbum: if let album = entry.albumID { try await client.addToAlbum(album, assets: ids) }
        }
    }
}

/// The History page: what was done, by day, with an undo on each entry.
struct HistoryView: View {
    enum Filter: String, CaseIterable {
        case all = "All", viewed = "Viewed", edited = "Edited", deleted = "Deleted", favorites = "Favorites"
        case albums = "Albums", hidden = "Hidden & Archive"

        func matches(_ kind: HistoryEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .viewed: kind == .viewed
            case .edited: kind == .edited
            case .deleted: [.deleted, .deletedForGood, .recovered].contains(kind)
            case .favorites: [.favorited, .unfavorited].contains(kind)
            case .albums: [.addedToAlbum, .removedFromAlbum].contains(kind)
            case .hidden: [.hidden, .unhidden, .archived].contains(kind)
            }
        }
    }

    @Environment(Session.self) private var session
    @State private var history = History.shared
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var busy: UUID?
    @State private var error: String?

    private struct Day: Identifiable {
        let day: Date
        var entries: [HistoryEntry]
        var id: Date { day }
    }

    private var days: [Day] {
        let shown = history.entries.filter { entry in
            filter.matches(entry.kind) && (query.isEmpty || [entry.name, entry.kind.title].compactMap { $0 }
                .contains { $0.localizedStandardContains(query) })
        }
        let calendar = Calendar.current
        var days: [Day] = []
        for entry in shown {
            let day = calendar.startOfDay(for: entry.date)
            if days.last?.day == day { days[days.count - 1].entries.append(entry) } else { days.append(Day(day: day, entries: [entry])) }
        }
        return days
    }

    var body: some View {
        List {
            Section {
                FilterChips(items: Filter.allCases, selection: $filter) { $0.rawValue }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if History.isPaused {
                Text("History is paused. Turn it back on in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(days) { day in
                Section(Self.title(day.day)) {
                    ForEach(day.entries) { row($0) }
                }
            }
        }
        .listSectionSpacing(.compact)
        .overlay {
            if history.entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Photos you view, edit, delete or move show up here."))
            } else if days.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "File name")
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .alert(error ?? "", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {}
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                OpenPhoto.shared.open(entry.asset, in: Timeline(assets: [entry.asset]))
            } label: {
                HStack(spacing: 12) {
                    Thumbnail(asset: entry.asset, cornerRadius: 8)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: entry.kind.symbol)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.tint, in: .circle)
                                .offset(x: 5, y: 5)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.kind.title).font(.subheadline.weight(.semibold))
                        Text([entry.date.formatted(date: .omitted, time: .shortened), entry.name, entry.undone ? "Undone" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if entry.canUndo {
                Button("Undo") { Task { await undo(entry) } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(busy != nil)
                    .overlay { if busy == entry.id { ProgressView() } }
            }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { history.remove(entry.id) }
        }
    }

    private static func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    private func undo(_ entry: HistoryEntry) async {
        busy = entry.id
        defer { busy = nil }
        do {
            try await History.undo(entry, client: session.client)
            history.markUndone(entry.id)
        } catch {
            self.error = error.explanation
        }
    }
}
