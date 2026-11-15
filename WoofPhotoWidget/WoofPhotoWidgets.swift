import SwiftUI
import WidgetKit

@main
struct WoofPhotoWidgets: WidgetBundle {
    var body: some Widget {
        WoofPhotoWidget()
        OnThisDayWidget()
        PeopleWidget()
        BackupWidget()
    }
}

// MARK: Shared pieces, in WoofMusic's widget style: a dark gradient, rounded heavy numbers, gold and teal.

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let gold = Color(hex: 0xFFD36E)
    static let teal = Color(hex: 0x5FB3A8)
}

/// What a widget shows: the file the app wrote, or nil before the app has written it.
struct SnapshotEntry<Value>: TimelineEntry {
    var date = Date.now
    var value: Value?
}

struct SnapshotProvider<Value: Codable>: TimelineProvider {
    let name: String

    func placeholder(in context: Context) -> SnapshotEntry<Value> { SnapshotEntry(value: nil) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry<Value>) -> Void) {
        completion(SnapshotEntry(value: WidgetData.read(Value.self, name)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry<Value>>) -> Void) {
        let entry = SnapshotEntry(value: WidgetData.read(Value.self, name))
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct WidgetPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetHeading: View {
    let text: String
    var color: Color = .gold

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: On This Day

/// Photos taken on today's date in earlier years, like Quick Picks' cover tiles: tap one to open it.
struct OnThisDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnThisDay", provider: SnapshotProvider<[WidgetData.Day]>(name: "OnThisDay")) { entry in
            OnThisDayView(days: entry.value)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(hex: 0x1B2430), Color(hex: 0x0E1218)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("On This Day")
        .description("Photos from this date in earlier years.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct OnThisDayView: View {
    @Environment(\.widgetFamily) private var family
    let days: [WidgetData.Day]?

    var body: some View {
        if let days, !days.isEmpty {
            switch family {
            case .systemSmall: small(days[0])
            case .systemLarge: large(days)
            default: medium(days)
            }
        } else {
            WidgetPlaceholder(symbol: "clock.arrow.circlepath", text: "Open WoofPhoto to find photos from this day")
        }
    }

    private func label(_ day: WidgetData.Day) -> String {
        let years = Calendar.current.component(.year, from: .now) - day.year
        return years <= 1 ? "1 year ago" : "\(years) years ago"
    }

    private func photo(_ day: WidgetData.Day) -> UIImage? {
        WidgetData.photos.flatMap { UIImage(contentsOfFile: $0.appending(path: day.file).path) }
    }

    /// A photo filling its frame, with the year over a fade at the bottom.
    private func tile(_ day: WidgetData.Day, text: String, size: CGFloat = 11, radius: CGFloat = 10) -> some View {
        Color.clear
            .overlay {
                if let image = photo(day) { Image(uiImage: image).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
            }
            .overlay(alignment: .bottomLeading) {
                Text(text)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel("Photo from \(label(day))")
    }

    private func link(_ day: WidgetData.Day, text: String, size: CGFloat = 11) -> some View {
        Link(destination: URL(string: "woofphoto://asset/\(day.id)")!) { tile(day, text: text, size: size) }
    }

    private func small(_ day: WidgetData.Day) -> some View {
        // the widget's own rounded corners cut it
        tile(day, text: label(day), size: 13, radius: 0)
            .widgetURL(URL(string: "woofphoto://asset/\(day.id)")!)
    }

    private func medium(_ days: [WidgetData.Day]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(text: "On this day")
            HStack(spacing: 6) {
                ForEach(Array(days.prefix(3)), id: \.id) { link($0, text: String($0.year)) }
            }
        }
        .padding(12)
    }

    private func large(_ days: [WidgetData.Day]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(text: "On this day")
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            if let day = days[safe: row * 2 + column] {
                                link(day, text: label(day), size: 12)
                            } else {
                                Color.white.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: People

/// The people Immich recognised, as round faces with their names, like WoofMusic's artist rows: tap one to open their photos.
/// The small widget shows one person and moves to the next every hour.
struct PeopleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "People", provider: SnapshotProvider<[WidgetData.Face]>(name: "People")) { entry in
            PeopleView(faces: entry.value, date: entry.date)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(hex: 0x123D4A), Color(hex: 0x0B0D12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("People")
        .description("The people in your library, one tap from their photos.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct PeopleView: View {
    @Environment(\.widgetFamily) private var family
    let faces: [WidgetData.Face]?
    let date: Date

    var body: some View {
        if let faces, !faces.isEmpty {
            switch family {
            case .systemSmall: small(faces)
            case .systemLarge: large(faces)
            default: medium(faces)
            }
        } else {
            WidgetPlaceholder(symbol: "person.2", text: "Name a person in WoofPhoto to see them here")
        }
    }

    private func url(_ face: WidgetData.Face) -> URL {
        var components = URLComponents()
        components.scheme = "woofphoto"
        components.host = "person"
        components.path = "/" + face.id
        components.queryItems = [URLQueryItem(name: "name", value: face.name)]
        return components.url!
    }

    private func image(_ face: WidgetData.Face) -> UIImage? {
        WidgetData.faces.flatMap { UIImage(contentsOfFile: $0.appending(path: face.file).path) }
    }

    private func circle(_ face: WidgetData.Face, size: CGFloat) -> some View {
        Group {
            if let image = image(face) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func person(_ face: WidgetData.Face, size: CGFloat) -> some View {
        Link(destination: url(face)) {
            VStack(spacing: 5) {
                circle(face, size: size)
                Text(face.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(face.name)
    }

    private func small(_ faces: [WidgetData.Face]) -> some View {
        let hour = Int(date.timeIntervalSinceReferenceDate / 3600)
        let face = faces[hour % faces.count]
        return VStack(spacing: 6) {
            WidgetHeading(text: "People · Woof")
            circle(face, size: 84)
            Text(face.name).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .widgetURL(url(face))
    }

    private func medium(_ faces: [WidgetData.Face]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeading(text: "People · Woof")
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(faces.prefix(4)), id: \.id) { person($0, size: 62) }
            }
            Spacer(minLength: 0)
        }
    }

    private func large(_ faces: [WidgetData.Face]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeading(text: "People · Woof")
            Grid(horizontalSpacing: 6, verticalSpacing: 14) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            if let face = faces[safe: row * 3 + column] { person(face, size: 84) } else { Color.clear }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Backup

/// Whether the iPhone's photos are on the server: a ring, what is waiting, and when the last backup ran.
/// A backup older than three days turns amber, because a revoked certificate stops it silently.
struct BackupWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BackupStatus", provider: SnapshotProvider<WidgetData.Backup>(name: "BackupStatus")) { entry in
            BackupView(backup: entry.value)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(hex: 0x1B2430), Color(hex: 0x0E1218)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Backup")
        .description("How much of this iPhone is on your server, and when it last backed up.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

private struct BackupView: View {
    @Environment(\.widgetFamily) private var family
    let backup: WidgetData.Backup?

    private static let amber = Color(hex: 0xF2A65A)

    private func fraction(_ backup: WidgetData.Backup) -> Double {
        let total = backup.done + backup.pending
        return total == 0 ? 1 : Double(backup.done) / Double(total)
    }

    private func isOld(_ backup: WidgetData.Backup) -> Bool {
        backup.enabled && (backup.last.map { Date.now.timeIntervalSince($0) > 3 * 86400 } ?? true)
    }

    var body: some View {
        if let backup {
            switch family {
            case .accessoryCircular: circular(backup)
            case .systemSmall: small(backup)
            default: medium(backup)
            }
        } else {
            WidgetPlaceholder(symbol: "icloud.and.arrow.up", text: "Open WoofPhoto to see your backup")
        }
    }

    private func ring(_ backup: WidgetData.Backup, line: CGFloat, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction(backup))
                .stroke(isOld(backup) ? Self.amber : Color.teal, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction(backup), format: .percent.precision(.fractionLength(0)))
                .font(.system(size: size * 0.24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Backed up")
        .accessibilityValue(fraction(backup).formatted(.percent.precision(.fractionLength(0))))
    }

    private func status(_ backup: WidgetData.Backup) -> String {
        if !backup.enabled { return "Backup is off" }
        return backup.pending == 0 ? "Everything is backed up" : "\(backup.pending) waiting"
    }

    @ViewBuilder private func lastRun(_ backup: WidgetData.Backup) -> some View {
        if let last = backup.last {
            (Text("Last backup ") + Text(last, style: .relative) + Text(" ago"))
                .font(.system(size: 11)).foregroundStyle(isOld(backup) ? Self.amber : .white.opacity(0.7))
        } else if backup.enabled {
            Text("No backup yet").font(.system(size: 11)).foregroundStyle(Self.amber)
        }
    }

    private func circular(_ backup: WidgetData.Backup) -> some View {
        Gauge(value: fraction(backup)) { Image(systemName: "icloud.and.arrow.up") }
            .gaugeStyle(.accessoryCircularCapacity)
    }

    private func small(_ backup: WidgetData.Backup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeading(text: "Backup · Woof", color: isOld(backup) ? Self.amber : .gold)
            ring(backup, line: 8, size: 70)
            Spacer(minLength: 0)
            Text(status(backup)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ backup: WidgetData.Backup) -> some View {
        HStack(spacing: 16) {
            ring(backup, line: 10, size: 92)
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeading(text: "Backup · Woof", color: isOld(backup) ? Self.amber : .gold)
                Text(status(backup)).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text("\(backup.done.formatted()) photos on the server").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                lastRun(backup)
                if isOld(backup) {
                    Text("Open WoofPhoto to back up.").font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
