import Foundation
import UIKit
import WidgetKit

/// Writes what the extra widgets show into the App Group folder and reloads them.
/// Photos are copied out of the app only while an On This Day widget is on the Home Screen, as for Featured Photos.
@MainActor
enum WidgetSync {
    static let onThisDay = "OnThisDay"
    static let month = "MonthStats"
    static let backup = "BackupStatus"

    /// At most once an hour, when the app opens; the widgets ask for nothing from the server themselves.
    private static var last = Date.distantPast

    static func refresh(client: ImmichClient) async {
        guard Date.now.timeIntervalSince(last) > 3600,
              let widgets = try? await WidgetCenter.shared.currentConfigurations(), !widgets.isEmpty else { return }
        last = .now
        let kinds = Set(widgets.map(\.kind))
        writeBackup()
        if kinds.contains(month) { await writeMonth(client: client) }
        if kinds.contains(onThisDay) { await writeOnThisDay(client: client) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// After a backup run, and when the app opens.
    static func writeBackup() {
        let backup = Backup.shared
        let done = backup.backedUpCount
        WidgetData.write(WidgetData.Backup(enabled: backup.enabled, pending: backup.pending.count, done: done,
                                           last: UserDefaults.standard.object(forKey: "backup.lastRun") as? Date),
                         WidgetSync.backup)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSync.backup)
    }

    private static func writeMonth(client: ImmichClient) async {
        let key = Date.now.formatted(.iso8601.year().month())
        guard let buckets = try? await client.buckets(.library),
              let bucket = buckets.first(where: { $0.timeBucket.hasPrefix(key) }),
              let assets = try? await client.bucket(bucket.timeBucket, .library).refs else { return }
        let calendar = Calendar.current
        let today = calendar.component(.day, from: .now)
        var weeks = Array(repeating: 0, count: (today - 1) / 7 + 1)
        var perDay: [Int: Int] = [:]
        for date in assets.compactMap(\.date) {
            let day = calendar.component(.day, from: date)
            perDay[day, default: 0] += 1
            if (day - 1) / 7 < weeks.count { weeks[(day - 1) / 7] += 1 }
        }
        // a day without a photo yet doesn't break a streak that ran through yesterday
        var day = perDay[today] == nil ? today - 1 : today
        var streak = 0
        while day >= 1, perDay[day] != nil {
            streak += 1
            day -= 1
        }
        let best = perDay.max { $0.value < $1.value }
        WidgetData.write(WidgetData.Month(name: Date.now.formatted(.dateTime.month(.wide)), count: assets.count, weeks: weeks,
                                          streak: streak,
                                          bestDay: best.flatMap { calendar.date(bySetting: .day, value: $0.key, of: .now) },
                                          bestCount: best?.value ?? 0), WidgetSync.month)
    }

    /// One photo from each earlier year that has this date, up to six, as 600-pixel JPEGs.
    private static func writeOnThisDay(client: ImmichClient) async {
        guard let folder = WidgetData.photos, let memories = try? await client.memories() else { return }
        let days = memories.filter { $0.type == "on_this_day" }.compactMap { memory -> (Asset, Int)? in
            guard let asset = memory.assets.first(where: { $0.type != "VIDEO" }), let year = memory.data?.year else { return nil }
            return (asset, year)
        }.prefix(6)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [WidgetData.Day] = []
        for (asset, year) in days {
            guard let data = try? await client.image(asset.id, size: "preview"), let image = UIImage(data: data) else { continue }
            let scale = min(1, 600 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            guard let jpeg = image.preparingThumbnail(of: size)?.jpegData(compressionQuality: 0.8) else { continue }
            let file = "\(asset.id).jpg"
            try? jpeg.write(to: folder.appending(path: file))
            items.append(WidgetData.Day(id: asset.id, file: file, year: year))
        }
        WidgetData.write(items, WidgetSync.onThisDay)
    }

    /// At sign-out: the widgets show their "open the app" state, and no photo stays in the shared folder.
    static func clear() {
        if let folder = WidgetData.folder { try? FileManager.default.removeItem(at: folder) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
