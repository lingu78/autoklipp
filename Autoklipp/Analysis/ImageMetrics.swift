import Accelerate
import CoreGraphics
import Foundation

/// A small greyscale copy of a frame, the working format for the pixel measurements.
struct GrayImage: Sendable {
    let width: Int
    let height: Int
    /// Row-major luminance 0...1.
    let pixels: [Float]

    /// Draws `image` into a greyscale bitmap whose long side is `longSide` pixels.
    init?(_ image: CGImage, longSide: Int = 256) {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        let width = max(8, Int((Double(image.width) * min(1, scale)).rounded()))
        let height = max(8, Int((Double(image.height) * min(1, scale)).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var floats = [Float](repeating: 0, count: bytes.count)
        vDSP.convertElements(of: bytes, to: &floats)
        vDSP.multiply(1 / 255, floats, result: &floats)
        self.width = width
        self.height = height
        pixels = floats
    }
}

/// Pixel measurements behind `FrameMetrics`, done with Accelerate on small greyscale frames.
enum ImageMetrics {
    /// Sharpness 0...1: Laplacian energy relative to the frame's contrast, so a crisp but flat
    /// scene (sky, snow) is not mistaken for blur. Below ~0.25 counts as blurry.
    static func sharpness(_ image: GrayImage) -> Double {
        guard image.width > 4, image.height > 4 else { return 0 }
        var laplacian = [Float](repeating: 0, count: image.pixels.count)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        vDSP_imgfir(image.pixels, vDSP_Length(image.height), vDSP_Length(image.width), kernel, &laplacian, 3, 3)
        // The filter leaves a one-pixel border of zeros; measure the interior only.
        var interior: [Float] = []
        interior.reserveCapacity((image.width - 2) * (image.height - 2))
        for row in 1..<(image.height - 1) {
            let start = row * image.width + 1
            interior.append(contentsOf: laplacian[start..<(start + image.width - 2)])
        }
        let edges = standardDeviation(interior)
        let contrast = standardDeviation(image.pixels)
        let ratio = edges / (contrast + 0.02)
        return min(1, max(0, (log10(max(ratio, 1e-6)) + 1.3) / 1.3))
    }

    /// Mean luminance 0...1.
    static func exposure(_ image: GrayImage) -> Double {
        Double(vDSP.mean(image.pixels))
    }

    /// Mean absolute difference between two frames after shifting `next` by (dx, dy) pixels,
    /// i.e. how much moved apart from the camera. 0...1.
    static func motion(_ previous: GrayImage, _ next: GrayImage, dx: Int, dy: Int) -> Double {
        guard previous.width == next.width, previous.height == next.height else { return 0 }
        let width = previous.width
        let height = previous.height
        let x0 = max(0, -dx)
        let x1 = min(width, width - dx)
        let y0 = max(0, -dy)
        let y1 = min(height, height - dy)
        guard x1 - x0 > 4, y1 - y0 > 4 else { return 1 }
        var total: Float = 0
        var count = 0
        var difference = [Float](repeating: 0, count: x1 - x0)
        for y in y0..<y1 {
            let a = y * width + x0
            let b = (y + dy) * width + x0 + dx
            previous.pixels.withUnsafeBufferPointer { first in
                next.pixels.withUnsafeBufferPointer { second in
                    vDSP_vsub(second.baseAddress! + b, 1, first.baseAddress! + a, 1, &difference, 1, vDSP_Length(x1 - x0))
                }
            }
            total += vDSP.meanMagnitude(difference) * Float(x1 - x0)
            count += x1 - x0
        }
        let mean = Double(total) / Double(max(1, count))
        return min(1, mean * 5)
    }

    /// 4×4 grid of mean colours (48 values, 0...1) for spotting near-identical shots.
    static func colorSignature(_ image: CGImage) -> [Float] {
        let side = 4
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        var signature: [Float] = []
        signature.reserveCapacity(side * side * 3)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 {
                signature.append(Float(bytes[pixel * 4 + channel]) / 255)
            }
        }
        return signature
    }

    /// Camera shake 0...1 from camera displacements between consecutive samples (as fractions
    /// of the frame width): smooth pans move steadily, handheld jitter changes direction.
    static func shake(displacements: [CGVector]) -> [Double] {
        guard !displacements.isEmpty else { return [] }
        return displacements.indices.map { index in
            let current = displacements[index]
            let neighbours = [index - 1, index + 1].filter { displacements.indices.contains($0) }.map { displacements[$0] }
            guard !neighbours.isEmpty else { return 0 }
            let change = neighbours.map { hypot(Double(current.dx - $0.dx), Double(current.dy - $0.dy)) }.max() ?? 0
            return min(1, change * 12)
        }
    }

    static func standardDeviation(_ values: [Float]) -> Double {
        guard values.count > 1 else { return 0 }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &deviation, vDSP_Length(values.count))
        return Double(deviation)
    }
}
