import AVFoundation
import ClipCore
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import Autoklipp

/// Temporary diagnosis: drawing one 1080×1920 frame takes ~20 ms in CI, but exporting takes
/// ~0.9 s per frame. This times the parts of an export separately. Never fails; it only logs
/// lines starting with PROBE.
@Suite("Export benchmark", .serialized)
struct RenderBenchmarkTests {
    @Test func timePerFrame() async throws {
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
        let frames = edl.duration * 30
        Self.log("film: \(edl.duration) s, \(Int(frames)) frames")

        // 1. Decoding and drawing only, through the compositor (no encoding).
        await Self.time("read through the compositor", frames: frames) {
            let reader = try AVAssetReader(asset: built.composition)
            let tracks = try await built.composition.loadTracks(withMediaType: .video)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.videoComposition = built.videoComposition
            reader.add(output)
            reader.startReading()
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            if reader.status != .completed { throw reader.error ?? TestMedia.TestError.couldNotWrite }
            Self.log("  read \(count) frames")
        }

        // 2. Encoding only: plain 1080×1920 frames into H.264.
        await Self.time("encode with AVAssetWriter", frames: frames) {
            try await Self.encode(frames: Int(frames), to: folder.appending(path: "plain.mp4"))
        }

        // 3. The whole export, with the app's preset and with a fixed-size one.
        await Self.time("export, highest quality", frames: frames) {
            try await VideoExporter.export(built, resolution: .hd1080, to: folder.appending(path: "highest.mp4")) { _ in }
        }
        await Self.time("export, 1920x1080 preset", frames: frames) {
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPreset1920x1080) else {
                throw VideoExporter.ExportError.sessionUnavailable
            }
            session.videoComposition = built.videoComposition
            session.audioMix = built.audioMix
            try await session.export(to: folder.appending(path: "preset1080.mp4"), as: .mp4)
        }
    }

    static func encode(frames: Int, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestMedia.TestError.couldNotWrite }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw TestMedia.TestError.couldNotWrite }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw TestMedia.TestError.couldNotWrite }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 4 % 256), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestMedia.TestError.couldNotWrite }
    }

    static func time(_ label: String, frames: Double, _ work: () async throws -> Void) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await work()
            let elapsed = (clock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            log("\(label): \(Int(seconds * 1000 / max(1, frames))) ms per frame")
        } catch {
            log("\(label): failed: \(error)")
        }
    }

    static func log(_ text: String) {
        print("PROBE \(text)")
        NSLog("PROBE %@", text as NSString)
    }
}
