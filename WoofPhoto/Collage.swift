import Photos
import SwiftUI

/// Makes a square collage from 2–9 selected photos and saves it to the library on the server or to this iPhone.
struct CollageEditor: View {
    let ids: [String]
    /// After saving, with a message for the grid to show.
    var onSaved: (String) -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var images: [UIImage] = []
    @State private var layout = CollageLayout.grid
    /// Both as a fraction of the collage's side, so the preview and the full render match.
    @State private var spacing: CGFloat = 0.015
    @State private var radius: CGFloat = 0
    @State private var background = Color.white
    @State private var busy = false
    @State private var error: String?

    /// The saved collage's side in pixels.
    private static let side: CGFloat = 3000

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    CollageCanvas(images: images, layout: layout, spacing: spacing, radius: radius, background: background, side: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal)
                .overlay { if images.isEmpty { ProgressView() } }
                Picker("Layout", selection: $layout) {
                    ForEach(CollageLayout.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Form {
                    LabeledContent("Spacing") { Slider(value: $spacing, in: 0...0.05) }
                    LabeledContent("Corners") { Slider(value: $radius, in: 0...0.08) }
                    ColorPicker("Background", selection: $background, supportsOpacity: false)
                }
                .scrollDisabled(true)
                .frame(height: 190)
            }
            .navigationTitle("Collage")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("Save") {
                        Button("Save to Library", systemImage: "icloud.and.arrow.up") { Task { await save(toServer: true) } }
                        Button("Save to iPhone", systemImage: "square.and.arrow.down") { Task { await save(toServer: false) } }
                    }
                    .disabled(images.count != ids.count || busy)
                }
            }
            .messageAlert($error)
        }
        .task { await load() }
    }

    private func load() async {
        var loaded: [UIImage] = []
        // ponytail: previews are about 1440 pixels, sharp for every cell of a 3000-pixel collage except a very large first one
        for id in ids {
            guard let image = await Still.load(id, size: "preview", client: session.client, cache: false) else {
                error = "A photo couldn't be loaded for the collage."
                return
            }
            loaded.append(image)
        }
        images = loaded
    }

    private func save(toServer: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let renderer = ImageRenderer(content: CollageCanvas(images: images, layout: layout, spacing: spacing, radius: radius,
                                                                background: background, side: Self.side))
            renderer.scale = 1
            guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.92) else { throw EditorView.EditError.render }
            if toServer {
                guard let client = session.client else { return }
                let file = FileManager.default.temporaryDirectory.appending(path: "Collage-\(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let now = Date.now.formatted(.iso8601)
                _ = try await client.upload(file, fields: ["fileCreatedAt": now, "fileModifiedAt": now])
                onSaved("The collage is in your library.")
            } else {
                guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw DeviceLibrary.Failure.denied }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                onSaved("The collage is saved to Photos.")
            }
            dismiss()
        } catch {
            self.error = error.explanation
        }
    }
}

/// Where the photos go, as rectangles in a unit square.
enum CollageLayout: String, CaseIterable {
    case grid = "Grid", feature = "Feature", rows = "Rows"

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .feature: "rectangle.grid.1x2"
        case .rows: "rectangle.split.1x2"
        }
    }

    func cells(_ count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        switch self {
        case .grid:
            // 2×2 for 4, 3×3 for 9; a short last row stretches across
            let columns = Int(Double(count).squareRoot().rounded(.up))
            return Self.rows(Self.chunks(count, of: columns), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        case .feature:
            // the first photo big on top, the others in rows of up to four below
            let top = CGRect(x: 0, y: 0, width: 1, height: count == 1 ? 1 : 2.0 / 3)
            return [top] + Self.rows(Self.chunks(count - 1, of: 4), in: CGRect(x: 0, y: top.maxY, width: 1, height: 1 - top.maxY))
        case .rows:
            // one wide photo, then two side by side, and again
            var counts: [Int] = [], left = count
            while left > 0 {
                let next = min(left, counts.count % 2 == 0 ? 1 : 2)
                counts.append(next)
                left -= next
            }
            return Self.rows(counts, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// `count` split into rows of `size`, the last one shorter.
    private static func chunks(_ count: Int, of size: Int) -> [Int] {
        stride(from: 0, to: count, by: size).map { min(size, count - $0) }
    }

    /// Rows of equal height, each split into equal cells.
    private static func rows(_ counts: [Int], in rect: CGRect) -> [CGRect] {
        let height = rect.height / CGFloat(counts.count)
        return counts.enumerated().flatMap { row, count in
            let width = rect.width / CGFloat(count)
            return (0..<count).map { CGRect(x: rect.minX + CGFloat($0) * width, y: rect.minY + CGFloat(row) * height, width: width, height: height) }
        }
    }
}

/// The collage at any size: the same view is the preview and, at 3000 points, the saved image.
struct CollageCanvas: View {
    let images: [UIImage]
    let layout: CollageLayout
    let spacing: CGFloat
    let radius: CGFloat
    let background: Color
    let side: CGFloat

    var body: some View {
        let gap = spacing * side
        // half a gap around each cell plus half around the whole: every gap, inner and outer, is the same
        let inner = side - gap
        ZStack(alignment: .topLeading) {
            background
            ForEach(Array(layout.cells(images.count).enumerated()), id: \.offset) { index, cell in
                let rect = CGRect(x: gap / 2 + cell.minX * inner, y: gap / 2 + cell.minY * inner,
                                  width: cell.width * inner, height: cell.height * inner).insetBy(dx: gap / 2, dy: gap / 2)
                Image(uiImage: images[index])
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .clipShape(.rect(cornerRadius: radius * side))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
