import FoundationModels
import UIKit
import Vision

/// Apple Intelligence on the iPhone, as Photos uses it: short titles and captions written by the on-device model.
/// Everything returns nil when the model is off, not supported, or declines, so callers keep their plain text.
enum Intelligence {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    @Generable
    struct Title {
        @Guide(description: "A short, warm title like Apple Photos memories use, 2 to 5 words, no quotes, no emoji")
        var text: String
    }

    @Generable
    struct Caption {
        @Guide(description: "One plain sentence describing the photo, under 15 words, no hashtags, no emoji")
        var text: String
    }

    @Generable
    struct SearchQuery {
        @Guide(description: "What the photos show, for visual search, without places, dates or media words; empty if nothing")
        var subject: String
        @Guide(description: "City named in the request, or empty")
        var city: String
        @Guide(description: "Country named in the request, or empty")
        var country: String
        @Guide(description: "First day of the time asked for, as yyyy-MM-dd, or empty")
        var after: String
        @Guide(description: "Last day of the time asked for, as yyyy-MM-dd, or empty")
        var before: String
        @Guide(.anyOf(["photos", "videos", "all"]))
        var media: String
    }

    /// Titles already written this session, so cards don't ask the model again while scrolling.
    @MainActor private static var titles: [String: String] = [:]

    /// A Photos-style title for a group of photos: a trip, a memory, a day.
    @MainActor
    static func title(key: String, kind: String, places: [String], start: Date?, end: Date?, people: [String] = []) async -> String? {
        if let title = titles[key] { return title }
        guard isAvailable else { return nil }
        var facts = ["Kind: \(kind)"]
        if !places.isEmpty { facts.append("Places, most photos first: \(places.prefix(5).joined(separator: ", "))") }
        if let start { facts.append("From: \(start.formatted(.dateTime.day().month(.wide).year()))") }
        if let end { facts.append("To: \(end.formatted(.dateTime.day().month(.wide).year()))") }
        if !people.isEmpty { facts.append("People: \(people.prefix(4).joined(separator: ", "))") }
        let session = LanguageModelSession(instructions: """
            You name photo collections for a gallery app, in the style of Apple Photos memories \
            ("Summer in Lisbon", "Weekend in the Alps", "Milan Through the Years"). Use only the facts given.
            """)
        guard let title = try? await session.respond(to: facts.joined(separator: "\n"), generating: Title.self).content.text,
              !title.isEmpty else { return nil }
        titles[key] = title
        return title
    }

    /// A sentence like "videos of the beach in Lisbon last summer" split into Immich search filters.
    static func searchQuery(_ text: String) async -> SearchQuery? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a photo search request into filters. Today is \(Date.now.formatted(.iso8601.year().month().day())). \
            Resolve relative times like "last summer" to dates. Leave a field empty when the request doesn't say it.
            """)
        return try? await session.respond(to: text, generating: SearchQuery.self).content
    }

    /// A one-line caption from what Vision sees in the photo plus its place, date and people.
    static func caption(for image: UIImage, place: String?, date: Date?, people: [String]) async -> String? {
        guard isAvailable, let cgImage = image.cgImage else { return nil }
        // the language model reads text only, so Vision first names what's in the picture
        let labels = (try? await ClassifyImageRequest().perform(on: cgImage))?
            .filter { $0.confidence > 0.3 }
            .prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") } ?? []
        guard !labels.isEmpty else { return nil }
        var facts = ["Things seen: \(labels.joined(separator: ", "))"]
        if let place { facts.append("Place: \(place)") }
        if let date { facts.append("Date: \(date.formatted(.dateTime.day().month(.wide).year()))") }
        if !people.isEmpty { facts.append("People: \(people.joined(separator: ", "))") }
        let session = LanguageModelSession(instructions: "You write short, neutral photo captions from the facts given. Don't invent details.")
        return try? await session.respond(to: facts.joined(separator: "\n"), generating: Caption.self).content.text
    }
}
