import PencilKit
import SwiftUI

/// Markup: draw or write on the photo with PencilKit; Done flattens the drawing onto it.
struct MarkupView: View {
    let image: CIImage
    var onDone: (CIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var display: UIImage?
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let display {
                    Image(uiImage: display)
                        .resizable()
                        .scaledToFit()
                        // the canvas covers exactly the photo, so its bounds map straight onto the pixels
                        .overlay { MarkupCanvas(canvas: canvas) }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Markup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { finish() }
                }
            }
        }
        .task { display = image.screenImage }
    }

    private func finish() {
        let drawing = canvas.drawing, bounds = canvas.bounds
        guard !drawing.strokes.isEmpty, bounds.width > 0 else { return dismiss() }
        let extent = image.extent
        // ponytail: the ink renders at most 4096 pixels wide and is scaled up past that; enough for strokes
        let scale = min(extent.width, 4096) / bounds.width
        var ink: UIImage?
        // light, as the canvas shows it: in dark mode PencilKit would turn black ink white
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = drawing.image(from: bounds, scale: scale) }
        guard let ink, let layer = CIImage(image: ink), layer.extent.width > 0, layer.extent.height > 0 else { return dismiss() }
        let fit = CGAffineTransform(scaleX: extent.width / layer.extent.width, y: extent.height / layer.extent.height)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        onDone(layer.transformed(by: fit).composited(over: image).cropped(to: extent))
        dismiss()
    }
}

/// The PencilKit canvas with the system tool picker, which brings its own undo and redo.
private struct MarkupCanvas: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeCoordinator() -> PKToolPicker { PKToolPicker() }

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.overrideUserInterfaceStyle = .light
        let picker = context.coordinator
        picker.colorUserInterfaceStyle = .light
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        // the picker appears once the canvas is in a window and first responder
        Task { @MainActor in canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}
}
