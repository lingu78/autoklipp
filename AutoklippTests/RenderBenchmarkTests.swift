import ClipCore
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing

@testable import Autoklipp

/// Temporary diagnosis: how long one 1080×1920 frame takes to draw here, on the GPU and on the
/// CPU path. Never fails; it only logs lines starting with PROBE.
@Suite("Render benchmark", .serialized)
struct RenderBenchmarkTests {
    @Test func timePerFrame() throws {
        Self.log("Metal device: \(MTLCreateSystemDefaultDevice()?.name ?? "none")")
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let portrait = folder.appending(path: "portrait.jpg")
        let landscape = folder.appending(path: "landscape.jpg")
        try TestMedia.writeImage(to: portrait, width: 1200, height: 1600, color: TestMedia.RGB.palette[0], date: nil)
        try TestMedia.writeImage(to: landscape, width: 1600, height: 1200, color: TestMedia.RGB.palette[1], date: nil)
        let zoom = KenBurns(startScale: 1, endScale: 1.15, startCenter: .center, endCenter: NormalizedPoint(x: 0.4, y: 0.45))
        let layers = [
            RenderTimeline.Layer(
                content: .still(url: portrait, pixelWidth: 1200, pixelHeight: 1600), mediaID: "portrait", start: 0, end: 5,
                transitionIn: .cut, filter: .warm, kenBurns: zoom
            ),
            RenderTimeline.Layer(
                content: .still(url: landscape, pixelWidth: 1600, pixelHeight: 1200), mediaID: "landscape", start: 5, end: 10,
                transitionIn: .cut, filter: .warm, kenBurns: zoom
            ),
            RenderTimeline.Layer(
                content: .video(trackID: 1, orientation: .up), mediaID: "video", start: 10, end: 15,
                transitionIn: .cut, filter: .warm, kenBurns: nil
            ),
        ]
        let renderer = FrameRenderer(timeline: RenderTimeline(renderSize: CGSize(width: 1080, height: 1920), duration: 15, layers: layers))
        let source = try Self.pixelBuffer(width: 640, height: 360)
        let output = try Self.pixelBuffer(width: 1080, height: 1920)
        let contexts = [
            ("gpu", CIContext(options: [.cacheIntermediates: false])),
            ("cpu", CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])),
        ]
        for (name, context) in contexts {
            for (label, start) in [("portrait still", 0.0), ("landscape still", 5.0), ("landscape video", 10.0)] {
                let clock = ContinuousClock()
                var elapsed = Duration.zero
                for frame in 0...10 {
                    let began = clock.now
                    let image = renderer.image(at: start + 0.5 + Double(frame) * 0.4) { _ in source }
                    context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920), colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
                    if frame > 0 { elapsed += clock.now - began }
                }
                Self.log("\(name) \(label): \(elapsed / 10) per frame")
            }
        }
    }

    static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw TestMedia.TestError.couldNotWrite }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func log(_ text: String) {
        print("PROBE \(text)")
        NSLog("PROBE %@", text as NSString)
    }
}
