import Foundation

/// The Adjust sliders and the filter of an edit, copied in the editor and pasted on another photo.
/// Crop, Clean Up, Markup and the key photo stay behind: they belong to one photo's pixels.
struct EditRecipe: Codable {
    var values: [String: Double]
    var filter: String?
    var filterAmount: Double?

    private static let key = "copiedEdit"

    init(_ edit: PhotoEdit) {
        values = Dictionary(uniqueKeysWithValues: edit.values.map { ($0.key.rawValue, $0.value) })
        filter = edit.filter
        filterAmount = edit.filterAmount
    }

    func apply(to edit: inout PhotoEdit) {
        edit.values = [:]
        for (name, value) in values {
            if let slider = PhotoEdit.Slider(rawValue: name) { edit[slider] = value }
        }
        edit.filter = filter
        edit.filterAmount = filterAmount ?? 1
    }

    static var saved: EditRecipe? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
