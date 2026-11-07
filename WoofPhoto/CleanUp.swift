import CoreImage
import SwiftUI
import os

/// Clean Up's photo in the editor: brush over something and LaMa, the model Spatial Scenes uses, paints it away.
struct CleanUpCanvas: View {
    let image: CIImage
    /// Brush width in points on screen.
    let brush: CGFloat
    var onErased: (CIImage) -> Void

    @State private var display: UIImage?
    /// The stroke being drawn, in points over the shown photo; it stays while LaMa works on it.
    @State private var stroke: [CGPoint] = []
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let display {
                Image(uiImage: display)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geometry in
                            Path { $0.addLines(stroke) }
                                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: brush, lineCap: .round, lineJoin: .round))
                                .contentShape(.rect)
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { stroke.append($0.location) }
                                    .onEnded { _ in erase(shownWidth: geometry.size.width) })
                        }
                    }
                    .allowsHitTesting(status == nil)
                    .accessibilityLabel("Photo to clean up")
                    .accessibilityHint("Brush over something to remove it.")
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if let status {
                Label { Text(status) } icon: { ProgressView() }
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding()
            }
        }
        .task(id: ObjectIdentifier(image)) { display = image.screenImage }
        .messageAlert($error)
    }

    private func erase(shownWidth: CGFloat) {
        guard !stroke.isEmpty, shownWidth > 0 else { return }
        // from points on screen to the photo's own pixels
        let scale = image.extent.width / shownWidth
        let points = stroke.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        let radius = brush / 2 * scale
        let image = image
        Task {
            defer {
                stroke = []
                status = nil
            }
            do {
                guard Spatial.lamaFits else { throw CleanUp.Failure.memory }
                if !LaMa.isDownloaded {
                    status = "Downloading Clean Up, once…"
                }
                let model = try await LaMa.download()
                status = "Cleaning up…"
                let result = try await Task.detached { try CleanUp.erase(image, stroke: points, radius: radius, model: model) }.value
                onErased(result)
            } catch {
                self.error = error.explanation
            }
        }
    }
}

/// The work behind Clean Up, off the main actor.
enum CleanUp {
    enum Failure: LocalizedError {
        case memory, render
        var errorDescription: String? {
            switch self {
            case .memory: "Not enough free memory for Clean Up. Close other apps and try again."
            case .render: "Clean Up couldn't paint this area."
            }
        }
    }

    /// Paints away what's under the stroke. `stroke` and `radius` are in the image's pixels, from its top left.
    /// Only a box around the stroke goes through LaMa's 512-pixel square, then it's blended back with a soft edge.
    /// ponytail: a big stroke on a big photo comes back softer, since its box is scaled to 512; tile the box if that shows.
    static func erase(_ image: CIImage, stroke: [CGPoint], radius: CGFloat, model: URL) throws -> CIImage {
        let extent = image.extent
        let xs = stroke.map(\.x), ys = stroke.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return image }
        // twice the stroke's size, so LaMa sees what surrounds it
        let side = max(maxX - minX, maxY - minY, 32) + 2 * radius
        var box = CGRect(x: (minX + maxX) / 2 - side, y: (minY + maxY) / 2 - side, width: side * 2, height: side * 2)
        // slid inside the photo where it fits, then clipped
        box.origin.x = max(0, min(box.minX, extent.width - box.width))
        box.origin.y = max(0, min(box.minY, extent.height - box.height))
        box = box.integral.intersection(CGRect(origin: .zero, size: extent.size))
        guard box.width >= 1, box.height >= 1 else { return image }
        // Core Image counts from the bottom left
        let ciBox = CGRect(x: extent.minX + box.minX, y: extent.maxY - box.maxY, width: box.width, height: box.height)

        let n = CGFloat(Spatial.lamaSize)
        let square = CGRect(x: 0, y: 0, width: n, height: n)
        let crop = image.cropped(to: ciBox)
            .transformed(by: CGAffineTransform(translationX: -ciBox.minX, y: -ciBox.minY))
            .transformed(by: CGAffineTransform(scaleX: n / ciBox.width, y: n / ciBox.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let maskImage = UIGraphicsImageRenderer(size: square.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(square)
            context.cgContext.scaleBy(x: n / box.width, y: n / box.height)
            context.cgContext.translateBy(x: -box.minX, y: -box.minY)
            let path = UIBezierPath()
            path.move(to: stroke[0])
            // a tap is a dot: a round cap on a zero-length line
            path.addLine(to: stroke[0])
            for point in stroke.dropFirst() { path.addLine(to: point) }
            path.lineWidth = radius * 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            UIColor.white.setStroke()
            path.stroke()
        }
        guard let cropImage = PhotoEdit.context.createCGImage(crop, from: square),
              let photo = Photo(UIImage(cgImage: cropImage)), let maskPhoto = Photo(maskImage),
              photo.width == Spatial.lamaSize, photo.height == Spatial.lamaSize,
              maskPhoto.width == Spatial.lamaSize, maskPhoto.height == Spatial.lamaSize else { throw Failure.render }
        let mask = (0..<Spatial.lamaSize * Spatial.lamaSize).map { maskPhoto.rgba[$0 * 4] > 127 ? Float(1) : 0 }

        let painted = try Spatial.lama(photo.rgb, mask: mask, model: model)
        var bytes = [UInt8](repeating: 255, count: mask.count * 4)
        for i in 0..<mask.count {
            for c in 0..<3 { bytes[i * 4 + c] = Spatial.byte(painted[i * 3 + c]) }
        }
        let size = Spatial.lamaSize
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let paintedImage = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let softMask = CIImage(image: maskImage) else { throw Failure.render }

        // back from the square to the box, blended in with a feathered edge
        let place = CGAffineTransform(scaleX: ciBox.width / n, y: ciBox.height / n)
            .concatenating(CGAffineTransform(translationX: ciBox.minX, y: ciBox.minY))
        let fill = CIImage(cgImage: paintedImage).transformed(by: place)
        let feather = softMask.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: square).transformed(by: place)
        return fill.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: feather])
            .cropped(to: extent)
    }
}

extension CIImage {
    /// At most 1600 pixels on the long side, for showing on screen.
    var screenImage: UIImage? {
        let scale = min(1, 1600 / max(extent.width, extent.height))
        let small = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return PhotoEdit.context.createCGImage(small, from: small.extent).map { UIImage(cgImage: $0) }
    }
}
