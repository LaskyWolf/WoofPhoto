import UIKit

/// Turns Immich's thumbhash (a ~25-byte summary of a photo) into a blurry 32-pixel preview,
/// shown while the real thumbnail downloads. Port of the reference decoder at github.com/evanw/thumbhash.
enum ThumbHash {
    static func image(base64: String) -> UIImage? {
        guard let hash = Data(base64Encoded: base64).map(Array.init), hash.count >= 5 else { return nil }
        let (w, h, rgba) = decode(hash)
        guard w > 0, h > 0,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private static func decode(_ hash: [UInt8]) -> (Int, Int, [UInt8]) {
        let header24 = Int(hash[0]) | Int(hash[1]) << 8 | Int(hash[2]) << 16
        let header16 = Int(hash[3]) | Int(hash[4]) << 8
        let lDC = Double(header24 & 63) / 63
        let pDC = Double((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Double((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Double((header24 >> 18) & 31) / 31
        let hasAlpha = header24 >> 23 != 0
        let pScale = Double((header16 >> 3) & 63) / 63
        let qScale = Double((header16 >> 9) & 63) / 63
        let isLandscape = header16 >> 15 != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7)
        let ly = max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7))
        let aDC = hasAlpha && hash.count > 5 ? Double(hash[5] & 15) / 15 : 1
        let aScale = hasAlpha && hash.count > 5 ? Double(hash[5] >> 4) / 15 : 0
        let acStart = hasAlpha ? 6 : 5
        var acIndex = 0

        func channel(_ nx: Int, _ ny: Int, _ scale: Double) -> [Double] {
            var ac: [Double] = []
            for cy in 0..<ny {
                var cx = cy == 0 ? 1 : 0
                while cx * ny < nx * (ny - cy) {
                    let byte = acStart + acIndex >> 1
                    let nibble = byte < hash.count ? (Int(hash[byte]) >> ((acIndex & 1) << 2)) & 15 : 0
                    ac.append((Double(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
            }
            return ac
        }
        let lAC = channel(lx, ly, lScale)
        let pAC = channel(3, 3, pScale * 1.25)
        let qAC = channel(3, 3, qScale * 1.25)
        let aAC = hasAlpha ? channel(5, 5, aScale) : []

        let ratio = Double(isLandscape ? (hasAlpha ? 5 : 7) : hash[3] & 7) / Double(isLandscape ? hash[3] & 7 : (hasAlpha ? 5 : 7))
        let w = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let h = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard w > 0, h > 0, ratio.isFinite else { return (0, 0, []) }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var fx = [Double](repeating: 0, count: max(lx, hasAlpha ? 5 : 3))
        var fy = [Double](repeating: 0, count: max(ly, hasAlpha ? 5 : 3))
        for y in 0..<h {
            for x in 0..<w {
                var l = lDC, p = pDC, q = qDC, a = aDC
                for cx in fx.indices { fx[cx] = cos(.pi / Double(w) * (Double(x) + 0.5) * Double(cx)) }
                for cy in fy.indices { fy[cy] = cos(.pi / Double(h) * (Double(y) + 0.5) * Double(cy)) }
                var j = 0
                for cy in 0..<ly {
                    var cx = cy == 0 ? 1 : 0
                    while cx * ly < lx * (ly - cy) { l += lAC[j] * fx[cx] * fy[cy] * 2; j += 1; cx += 1 }
                }
                j = 0
                for cy in 0..<3 {
                    var cx = cy == 0 ? 1 : 0
                    while cx < 3 - cy {
                        let f = fx[cx] * fy[cy] * 2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        j += 1; cx += 1
                    }
                }
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        var cx = cy == 0 ? 1 : 0
                        while cx < 5 - cy { a += aAC[j] * fx[cx] * fy[cy] * 2; j += 1; cx += 1 }
                    }
                }
                let b = l - 2 / 3 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                let alpha = max(0, min(1, a))
                let i = (y * w + x) * 4
                // premultiplied, to match the CGImage format above
                rgba[i] = UInt8(max(0, min(1, r)) * alpha * 255)
                rgba[i + 1] = UInt8(max(0, min(1, g)) * alpha * 255)
                rgba[i + 2] = UInt8(max(0, min(1, b)) * alpha * 255)
                rgba[i + 3] = UInt8(alpha * 255)
            }
        }
        return (w, h, rgba)
    }
}
