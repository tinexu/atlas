import CoreGraphics
import Foundation

/// The main colours of a picture: k-means on a small downsampled copy
/// (48 × 48), most common first. Deterministic, so the same picture always
/// gives the same palette.
public enum ColorPalette {
    public static let sampleSize = 48

    /// Up to `count` distinct colours as "#RRGGBB" (fewer only for a picture
    /// with fewer colours than that).
    public static func extract(from image: CGImage, count: Int = 5) -> [String] {
        let pixels = samples(image)
        guard !pixels.isEmpty else { return [] }
        // Start from spread-out pixels: the first, then each next the farthest from those chosen.
        var centres = [pixels[0]]
        while centres.count < count {
            guard let far = pixels.max(by: { nearest($0, centres).distance < nearest($1, centres).distance }),
                  nearest(far, centres).distance > 0.0004 else { break }
            centres.append(far)
        }
        var sizes = [Int](repeating: 0, count: centres.count)
        for _ in 0..<12 {
            var sums = [SIMD3<Double>](repeating: .zero, count: centres.count)
            sizes = [Int](repeating: 0, count: centres.count)
            for pixel in pixels {
                let index = nearest(pixel, centres).index
                sums[index] += pixel
                sizes[index] += 1
            }
            let next = centres.indices.map { sizes[$0] > 0 ? sums[$0] / Double(sizes[$0]) : centres[$0] }
            if next == centres { break }
            centres = next
        }
        return centres.indices.sorted { sizes[$0] > sizes[$1] }.map { hex(centres[$0]) }
    }

    /// RGB in 0…1, one per pixel of the downsampled picture (transparent ones skipped).
    static func samples(_ image: CGImage) -> [SIMD3<Double>] {
        let side = sampleSize
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .none  // no blended in-between colours at edges
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var pixels: [SIMD3<Double>] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 128 {
            let alpha = Double(bytes[index + 3]) / 255
            pixels.append(SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255 / alpha)
        }
        return pixels
    }

    private static func nearest(_ pixel: SIMD3<Double>, _ centres: [SIMD3<Double>]) -> (index: Int, distance: Double) {
        var best = (index: 0, distance: Double.infinity)
        for (index, centre) in centres.enumerated() {
            let d = pixel - centre
            let distance = (d * d).sum()
            if distance < best.distance { best = (index, distance) }
        }
        return best
    }

    static func hex(_ color: SIMD3<Double>) -> String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.x), byte(color.y), byte(color.z))
    }
}
