import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Textured test videos whose quality changes over time: sharp or blurred, steady, panning
/// smoothly or shaking. Used to check that analysis and selection avoid weak footage.
enum PatternVideo {
    enum Look: Sendable {
        case steady
        case pan
        case shaky
        case blurred
    }

    /// Writes a video where second `n` uses `looks[n]`.
    static func write(to url: URL, looks: [Look], width: Int = 1280, height: Int = 720) async throws {
        let sharp = try pattern(width: width * 3 / 2, height: height * 3 / 2, seed: 7)
        let blurred = try blur(sharp, sigma: 12)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestMedia.TestError.couldNotWrite }
        writer.startSession(atSourceTime: .zero)
        var random = SplitMix(seed: 11)
        let fps = 30
        for frame in 0..<(looks.count * fps) {
            let look = looks[frame / fps]
            let time = Double(frame) / Double(fps)
            var x = Double(width) / 4
            var y = Double(height) / 4
            switch look {
            case .steady, .blurred:
                break
            case .pan:
                x += time * 25
            case .shaky:
                x += (random.unit() - 0.5) * Double(width) * 0.16
                y += (random.unit() - 0.5) * Double(height) * 0.16
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw TestMedia.TestError.couldNotWrite }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw TestMedia.TestError.couldNotWrite }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                let source = look == .blurred ? blurred : sharp
                context.draw(source, in: CGRect(x: -x, y: -y, width: Double(source.width), height: Double(source.height)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestMedia.TestError.couldNotWrite }
    }

    /// Many overlapping rectangles in varied tones and sizes: texture at every scale.
    static func pattern(width: Int, height: Int, seed: UInt64) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestMedia.TestError.couldNotWrite }
        var random = SplitMix(seed: seed)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<1500 {
            let side = 6 + random.unit() * 120
            context.setFillColor(red: random.unit(), green: random.unit(), blue: random.unit(), alpha: 1)
            context.fill(CGRect(x: random.unit() * Double(width), y: random.unit() * Double(height), width: side, height: side * (0.5 + random.unit())))
        }
        guard let image = context.makeImage() else { throw TestMedia.TestError.couldNotWrite }
        return image
    }

    static func blur(_ image: CGImage, sigma: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let result = CIContext().createCGImage(output, from: input.extent) else { throw TestMedia.TestError.couldNotWrite }
        return result
    }

    struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) * 0x1.0p-53
        }
    }
}
