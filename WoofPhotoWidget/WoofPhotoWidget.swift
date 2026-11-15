import SwiftUI
import WidgetKit

/// Featured Photos: a different photo from the library every hour, like the Photos widget.
struct PhotoEntry: TimelineEntry {
    var date = Date.now
    var item: Featured.Item?
    var image: UIImage?
}

struct PhotoProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhotoEntry { PhotoEntry() }

    func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) {
        completion(entries(count: 1).first ?? PhotoEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
        let entries = entries(count: 12)
        completion(Timeline(entries: entries.isEmpty ? [PhotoEntry()] : entries, policy: .atEnd))
    }

    /// One entry per hour, each with the next photo.
    private func entries(count: Int) -> [PhotoEntry] {
        let items = Featured.items().shuffled()
        guard let folder = Featured.folder, !items.isEmpty else { return [] }
        return (0..<min(count, items.count)).map { hour in
            let item = items[hour]
            return PhotoEntry(date: .now.addingTimeInterval(Double(hour) * 3600), item: item,
                              image: UIImage(contentsOfFile: folder.appending(path: item.file).path))
        }
    }
}

struct WoofPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FeaturedPhotos", provider: PhotoProvider()) { entry in
            WidgetBody(entry: entry)
        }
        .configurationDisplayName("Featured Photos")
        .description("A different photo from your Immich library every hour.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

/// The Home Screen widget shows the photo with its month; the Lock Screen ones show it small, in the system's tint, or only the month.
private struct WidgetBody: View {
    let entry: PhotoEntry
    @Environment(\.widgetFamily) private var family

    private var month: String? { entry.item?.date?.formatted(.dateTime.month(.wide).year()) }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(month ?? "WoofPhoto", systemImage: "photo.on.rectangle")
                .widgetURL(entry.item.map { URL(string: "woofphoto://asset/\($0.id)")! })
        case .accessoryCircular, .accessoryRectangular:
            ZStack {
                if let image = entry.image {
                    Image(uiImage: image).resizable().scaledToFill().widgetAccentable()
                } else {
                    Image(systemName: "photo.on.rectangle")
                }
            }
            .containerBackground(.clear, for: .widget)
            .widgetURL(entry.item.map { URL(string: "woofphoto://asset/\($0.id)")! })
        default:
            ZStack(alignment: .bottomLeading) {
                if let image = entry.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle").font(.title)
                        Text("Open WoofPhoto to choose photos.").font(.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let date = entry.item?.date {
                    Text(date.formatted(.dateTime.month(.wide).year()))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(12)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.item.map { URL(string: "woofphoto://asset/\($0.id)")! })
        }
    }
}
