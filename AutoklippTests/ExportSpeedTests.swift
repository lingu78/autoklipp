import AVFoundation
import ClipCore
import CoreVideo
import Foundation
import Testing

@testable import Autoklipp

/// Frames must reach the compositor in buffers shared with the GPU. With plain buffers Core
/// Image copied every 1080×1920 frame through the CPU: ~1.3 s per frame in the simulator
/// instead of ~25 ms.
///
/// The buffers and the renderer are checked directly. The time per frame is only a coarse check:
/// on the CI runners it varies with the load on the machine, and other simulators running at the
/// same time have made it 0.45–0.6 s with shared buffers on the GPU.
@Suite("Export speed")
struct ExportSpeedTests {
    @Test(.timeLimit(.minutes(5)))
    func framesPassThroughTheCompositorQuickly() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var media: [ImportedMedia] = []
        for index in 0..<2 {
            let url = folder.appending(path: "still-\(index).jpg")
            try TestMedia.writeImage(
                to: url, width: 1200, height: 1600, color: TestMedia.RGB.palette[index],
                date: TestMedia.baseDate.addingTimeInterval(Double(index) * 60)
            )
            let info = try MediaMetadataReader.readImage(at: url)
            let item = MediaItem(id: "s\(index)", kind: .photo, creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height)
            media.append(ImportedMedia(item: item, url: url))
        }
        let song = MusicCatalog.defaultTrack?.choice
        let edl = FilmGenerator.plan(GenerationInput(media: media, targetDuration: 4, style: .travel, song: song, seed: 1, format: .portrait))
        let built = try await FilmGenerator.build(edl, media: media, song: song, settings: RenderSettings(format: .portrait, resolution: .hd1080))

        // The CPU renderer, used while the app is not active, is many times slower.
        print("compositor: app inactive or in background: \(RenderEnvironment.isInBackground)")
        let trace = TraceLines()
        ClipCompositor.trace = { trace.append($0) }
        defer { ClipCompositor.trace = nil }
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        reader.add(output)
        let clock = ContinuousClock()
        let started = clock.now
        reader.startReading()
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        let elapsed = clock.now - started
        #expect(reader.status == .completed)
        #expect(frames >= 115, "\(frames) frames for a 4 s film")
        let perFrame = elapsed / max(1, frames)
        print("compositor: \(perFrame) per 1080x1920 frame")

        let first = trace.lines.first { $0.hasPrefix("first frame") }
        print("compositor: \(first ?? "no first frame")")
        #expect(first?.contains("output shared with the GPU: true") == true, "the compositor draws into a buffer shared with the GPU")
        #expect(first?.contains("sources shared with the GPU: false") == false, "and is handed frames shared with it")
        #expect(first?.contains("on the GPU: true") == true, "with Core Image on the GPU")
        // Plain buffers took ~1.3 s per frame here and the CPU renderer longer still.
        #expect(perFrame < .seconds(1), "\(perFrame) per frame")
    }
}

/// Lines from the compositor's trace, which it sends from its own queue.
final class TraceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    var lines: [String] { lock.withLock { stored } }
}
