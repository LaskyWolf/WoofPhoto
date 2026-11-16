import UIKit
import Vision

/// Plain rules for what Apple Intelligence used to write: trip titles, dates in a search, caption keywords.
enum Naming {
    /// "Weekend in Lisbon" for up to three days, otherwise "Summer in Lisbon".
    static func trip(place: String, start: Date, end: Date?) -> String {
        let days = end.flatMap { Calendar.current.dateComponents([.day], from: start, to: $0).day } ?? 0
        return days <= 3 ? "Weekend in \(place)" : "\(season(start)) in \(place)"
    }

    /// ponytail: northern hemisphere seasons; a southern one would need the photo's latitude.
    private static func season(_ date: Date) -> String {
        switch Calendar.current.component(.month, from: date) {
        case 3...5: "Spring"
        case 6...8: "Summer"
        case 9...11: "Autumn"
        default: "Winter"
        }
    }

    /// The first date in a search like "dog in march" or "beach 2023", as whole days, and the text without it.
    /// The server's smart search reads the rest of the sentence.
    static func date(in text: String) -> (after: Date, before: Date, rest: String)? {
        let nsText = text as NSString
        if let year = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#).firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
           let value = Int(nsText.substring(with: year.range)),
           let first = Calendar.current.date(from: DateComponents(year: value, month: 1, day: 1)),
           let last = Calendar.current.date(from: DateComponents(year: value, month: 12, day: 31)) {
            return (first, last, nsText.replacingCharacters(in: year.range, with: "").trimmingCharacters(in: .whitespaces))
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              let start = match.date else { return nil }
        let end = start.addingTimeInterval(max(match.duration, 1) - 1)
        return (start, end, nsText.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespaces))
    }

    /// What Vision sees in the photo, as words to edit into a caption, with the place after them.
    static func caption(for image: UIImage, place: String?) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let labels = (try? await ClassifyImageRequest().perform(on: cgImage))?
            .filter { $0.confidence > 0.3 }
            .prefix(4)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") } ?? []
        guard !labels.isEmpty else { return nil }
        return (labels + (place.map { [$0] } ?? [])).joined(separator: ", ").capitalized
    }
}
