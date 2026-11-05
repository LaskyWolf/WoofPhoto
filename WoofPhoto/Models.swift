import Foundation

/// What a grid cell and the viewer need about one asset. Comes from a timeline month or a full `Asset`.
struct AssetRef: Identifiable, Hashable {
    let id: String
    var isImage = true
    var isFavorite = false
    var thumbhash: String?
    /// Milliseconds, for videos.
    var duration: Int?
    var livePhotoVideoId: String?
    var stackID: String?
    var stackCount = 0
}

/// One asset as `GET /assets/{id}` and the search endpoints return it. Every field is optional,
/// so a server version that drops or retypes one shows less instead of failing.
struct Asset: Decodable, Identifiable {
    var id: String
    var type: String?
    var originalFileName: String?
    var originalMimeType: String?
    var fileCreatedAt: String?
    var localDateTime: String?
    var thumbhash: String?
    var isFavorite: Bool?
    var isTrashed: Bool?
    var visibility: String?
    var livePhotoVideoId: String?
    var checksum: String?
    var width: Lossy<Int>?
    var height: Lossy<Int>?
    /// Milliseconds on Immich 3; older servers send text, which reads as nil.
    var duration: Lossy<Int>?
    var exifInfo: Exif?
    var people: [Person]?
    var stack: StackInfo?

    struct StackInfo: Decodable {
        var id: String
        var assetCount: Int?
    }

    var ref: AssetRef {
        AssetRef(id: id, isImage: type != "VIDEO", isFavorite: isFavorite ?? false, thumbhash: thumbhash,
                 duration: duration?.value, livePhotoVideoId: livePhotoVideoId,
                 stackID: stack?.id, stackCount: stack?.assetCount ?? 0)
    }

    /// The date the photo was taken, in the time zone where it was taken.
    var date: Date? { (localDateTime ?? fileCreatedAt).flatMap(Date.init(immich:)) }
}

struct Exif: Decodable {
    var make: String?
    var model: String?
    var lensModel: String?
    var fNumber: Double?
    var focalLength: Double?
    var iso: Lossy<Int>?
    var exposureTime: String?
    var latitude: Double?
    var longitude: Double?
    var city: String?
    var state: String?
    var country: String?
    var description: String?
    var fileSizeInByte: Lossy<Int>?
    var exifImageWidth: Lossy<Int>?
    var exifImageHeight: Lossy<Int>?
}

struct Person: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var birthDate: String?
    var isHidden: Bool?
    var isFavorite: Bool?
}

struct Stack: Decodable {
    var id: String
    var primaryAssetId: String?
    var assets: [Asset]
}

/// Decodes a value when it has the expected type and gives nil otherwise, instead of failing the whole response.
struct Lossy<T: Decodable & Hashable>: Decodable, Hashable {
    var value: T?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

extension Date {
    /// Immich dates: "2024-05-01T10:20:30.000Z", with or without the fraction.
    init?(immich text: String) {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = (try? fractional.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) else { return nil }
        self = date
    }
}

extension TimeBucket {
    /// "2024-05-01" as a date at midnight UTC, the start of the month.
    var date: Date? { Date(immich: timeBucket.count == 10 ? timeBucket + "T00:00:00Z" : timeBucket) }
}
