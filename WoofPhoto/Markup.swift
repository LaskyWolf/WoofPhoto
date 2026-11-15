import PencilKit
import SwiftUI

/// Markup's drawing, made on a PencilKit canvas that sits on the editor's photo (see `EditorStage`).
/// The editor's Done flattens the drawing onto the photo with `flatten`.
enum MarkupCanvas {
    /// The drawing on `canvas` painted onto `image` at the photo's size; nil when nothing was drawn.
    static func flatten(_ canvas: PKCanvasView, onto image: CIImage) -> CIImage? {
        let drawing = canvas.drawing, bounds = canvas.bounds
        guard !drawing.strokes.isEmpty, bounds.width > 0 else { return nil }
        let extent = image.extent
        // ponytail: the ink renders at most 4096 pixels wide and is scaled up past that; enough for strokes
        let scale = min(extent.width, 4096) / bounds.width
        var ink: UIImage?
        // light, as the canvas shows it: in dark mode PencilKit would turn black ink white
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = drawing.image(from: bounds, scale: scale) }
        guard let ink, let layer = CIImage(image: ink), layer.extent.width > 0, layer.extent.height > 0 else { return nil }
        let fit = CGAffineTransform(scaleX: extent.width / layer.extent.width, y: extent.height / layer.extent.height)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return layer.transformed(by: fit).composited(over: image).cropped(to: extent)
    }
}
