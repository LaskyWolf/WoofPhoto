import PencilKit
import SwiftUI

/// The editor's photo for every tool: pinch to zoom and two fingers to move it, kept while the tool changes.
/// The tool's own layer (the crop frame, Clean Up's brush) or the Markup canvas sits on the photo and zooms with it.
/// One finger is left to the tool: on the viewing tools holding it shows the original.
struct EditorStage: UIViewRepresentable {
    let image: UIImage
    /// Room around the photo, so a crop corner can be grabbed at the very corner.
    let inset: CGFloat
    /// The crop frame covers the room around the photo too; other layers cover the photo only.
    var overlayCoversStage = false
    var overlay: AnyView?
    var canvas: PKCanvasView?
    /// The photo shown turned by `degrees` (clockwise) and enlarged by `scale`: Crop's straighten, which turns the picture under a fixed frame.
    var tilt: (degrees: Double, scale: CGFloat) = (0, 1)
    /// Holding one finger and a double tap: on the tools that leave the photo alone.
    var viewing = true
    var twisting = true
    var onHold: (Bool) -> Void = { _ in }
    /// Degrees turned clockwise since two fingers started; nil when they lift.
    var onTwist: (Double?) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomPane { ZoomPane() }

    func updateUIView(_ pane: ZoomPane, context: Context) {
        pane.inset = inset
        pane.overlayCoversStage = overlayCoversStage
        pane.viewing = viewing
        pane.twisting = twisting
        pane.onHold = onHold
        pane.onTwist = onTwist
        pane.onZoom = onZoom
        pane.show(image)
        pane.setOverlay(overlay)
        pane.setCanvas(canvas)
        pane.setTilt(tilt.degrees, scale: tilt.scale)
    }
}

final class ZoomPane: UIScrollView, UIScrollViewDelegate {
    var onHold: (Bool) -> Void = { _ in }
    var onTwist: (Double?) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }
    var inset: CGFloat = 0 { didSet { if inset != oldValue { arrange() } } }
    var overlayCoversStage = false { didSet { if overlayCoversStage != oldValue { arrange() } } }
    var viewing = true { didSet { hold.isEnabled = viewing; doubleTap.isEnabled = viewing } }
    var twisting = true { didSet { twist.isEnabled = twisting } }

    /// What zooms: the photo, the tool's layer and the canvas.
    private let content = UIView()
    private let imageView = UIImageView()
    private var host: UIHostingController<AnyView>?
    private weak var canvas: PKCanvasView?
    private var tilt = (degrees: 0.0, scale: CGFloat(1))
    private let hold = UILongPressGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let twist = UIRotationGestureRecognizer()
    private let together = Together()

    /// Lets the twist run beside the pinch and the two-finger move.
    private final class Together: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 8
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // a finger on the brush or the crop frame must start at once, not after the scroll view decides it isn't a scroll
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        imageView.contentMode = .scaleToFill
        addSubview(content)
        content.addSubview(imageView)
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.1
        hold.numberOfTouchesRequired = 1
        addGestureRecognizer(hold)
        doubleTap.addTarget(self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        twist.addTarget(self, action: #selector(twisted(_:)))
        twist.delegate = together
        addGestureRecognizer(twist)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        // a different shape (a crop, a turn) starts again from the whole photo; the same shape keeps the zoom and the place
        if let old = imageView.image, abs(old.size.width / max(old.size.height, 1) - image.size.width / max(image.size.height, 1)) > 0.01 {
            zoomScale = 1
        }
        imageView.image = image
        arrange()
    }

    func setOverlay(_ view: AnyView?) {
        guard let view else {
            host?.view.removeFromSuperview()
            host = nil
            return
        }
        if let host {
            host.rootView = view
        } else {
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .clear
            controller.safeAreaRegions = []
            content.addSubview(controller.view)
            host = controller
            arrange()
        }
    }

    func setCanvas(_ new: PKCanvasView?) {
        guard new !== canvas else { return }
        canvas?.removeFromSuperview()
        canvas = new
        guard let new else { return }
        new.backgroundColor = .clear
        new.isOpaque = false
        new.drawingPolicy = .anyInput
        new.overrideUserInterfaceStyle = .light
        // the canvas must not scroll: the stage moves and zooms it
        new.isScrollEnabled = false
        content.addSubview(new)
        arrange()
    }

    func setTilt(_ degrees: Double, scale: CGFloat) {
        tilt = (degrees, scale)
        imageView.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180).scaledBy(x: scale, y: scale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale {
            content.frame = bounds
            contentSize = bounds.size
        }
        arrange()
    }

    /// Puts the photo, the layer and the canvas in place inside the unzoomed content.
    private func arrange() {
        let room = content.bounds.insetBy(dx: inset, dy: inset)
        guard let size = imageView.image?.size, size.height > 0, room.width > 0, room.height > 0 else { return }
        let aspect = size.width / size.height
        let width = min(room.width, room.height * aspect)
        let picture = CGRect(x: room.midX - width / 2, y: room.midY - width / aspect / 2, width: width, height: width / aspect)
        imageView.transform = .identity
        imageView.frame = picture
        imageView.transform = CGAffineTransform(rotationAngle: tilt.degrees * .pi / 180).scaledBy(x: tilt.scale, y: tilt.scale)
        host?.view.frame = overlayCoversStage ? content.bounds : picture
        canvas?.frame = picture
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { onZoom(zoomScale) }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: onHold(true)
        case .ended, .cancelled, .failed: onHold(false)
        default: break
        }
    }

    @objc private func twisted(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .changed: onTwist(Double(gesture.rotation) * 180 / .pi)
        case .ended, .cancelled, .failed: onTwist(nil)
        default: break
        }
    }

    @objc private func doubleTapped() {
        setZoomScale(zoomScale > minimumZoomScale ? minimumZoomScale : 3, animated: true)
    }
}
