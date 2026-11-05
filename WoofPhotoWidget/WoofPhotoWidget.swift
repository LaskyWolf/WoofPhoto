import SwiftUI
import WidgetKit

/// M0 spike: shows the value the app wrote to the App Group. A different group or "Can't open" means
/// the signing tool gave the widget and the app different groups.
struct GroupEntry: TimelineEntry {
    var date = Date.now
    var value: String
    var group = AppGroup.id

    static func current() -> GroupEntry {
        guard let defaults = AppGroup.defaults else { return GroupEntry(value: "Can't open") }
        return GroupEntry(value: defaults.string(forKey: "spike.value") ?? "Nothing written")
    }
}

struct GroupProvider: TimelineProvider {
    func placeholder(in context: Context) -> GroupEntry { GroupEntry(value: "12:00:00") }
    func getSnapshot(in context: Context, completion: @escaping (GroupEntry) -> Void) { completion(.current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GroupEntry>) -> Void) {
        completion(Timeline(entries: [.current()], policy: .never))
    }
}

@main
struct WoofPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AppGroupCheck", provider: GroupProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text("App Group").font(.caption).foregroundStyle(.secondary)
                Text(entry.value).font(.headline).minimumScaleFactor(0.6)
                Spacer()
                Text(entry.group).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("WoofPhoto Check")
        .description("Shows whether the app and the widget share data.")
        .supportedFamilies([.systemSmall])
    }
}
