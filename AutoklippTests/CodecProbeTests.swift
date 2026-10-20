import AVFoundation
import ClipCore
import Foundation
import Testing

@testable import Autoklipp

/// Temporary diagnosis: which video codecs this simulator can decode and export. Never fails;
/// it only logs lines starting with PROBE.
@Suite("Codec probe", .serialized)
struct CodecProbeTests {
    @Test func probe() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for codec in [AVVideoCodecType.h264, .hevc, .jpeg] {
            let url = folder.appending(path: "probe-\(codec.rawValue).mov")
            do {
                try await TestMedia.writeVideo(
                    to: url, duration: 1, width: 640, height: 360, color: TestMedia.RGB.palette[0], date: nil, codec: codec
                )
                Self.log("decode \(codec.rawValue): \(await Self.decode(url))")
            } catch {
                Self.log("write \(codec.rawValue): \(error)")
            }
        }

        let h264 = folder.appending(path: "probe-avc1.mov")
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: h264))
            let image = try await generator.image(at: CMTime(value: 1, timescale: 2)).image
            Self.log("image generator avc1: ok \(image.width)x\(image.height)")
        } catch {
            Self.log("image generator avc1: \(error)")
        }

        do {
            let blank = try await BlankVideo.shared.url()
            Self.log("decode blank: \(await Self.decode(blank))")
        } catch {
            Self.log("blank: \(error)")
        }

        do {
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: h264), presetName: AVAssetExportPresetHighestQuality)
            else { throw VideoExporter.ExportError.sessionUnavailable }
            try await session.export(to: folder.appending(path: "reencoded.mp4"), as: .mp4)
            Self.log("plain export avc1: ok")
        } catch {
            Self.log("plain export avc1: \(error)")
        }

        Self.log("film of stills: \(await Self.film(videoCodec: nil, in: folder))")
        for codec in [AVVideoCodecType.h264, .jpeg] {
            Self.log("film with \(codec.rawValue): \(await Self.film(videoCodec: codec, in: folder))")
        }
    }

    static func log(_ text: String) {
        print("PROBE \(text)")
        NSLog("PROBE %@", text as NSString)
    }

    static func decode(_ url: URL) async -> String {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return "no video track" }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            reader.add(output)
            reader.startReading()
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            return reader.status == .completed
                ? "ok, \(frames) frames" : "failed after \(frames) frames: \(String(describing: reader.error))"
        } catch {
            return "\(error)"
        }
    }

    /// Two stills and optionally one video clip, exported through the app's own pipeline.
    static func film(videoCodec: AVVideoCodecType?, in folder: URL) async -> String {
        do {
            var media: [ImportedMedia] = []
            for index in 0..<2 {
                let url = folder.appending(path: "still-\(index)-\(UUID().uuidString).jpg")
                let date = TestMedia.baseDate.addingTimeInterval(Double(index) * 60)
                try TestMedia.writeImage(to: url, width: 1200, height: 1600, color: TestMedia.RGB.palette[index], date: date)
                let info = try MediaMetadataReader.readImage(at: url)
                let item = MediaItem(
                    id: "s\(index)", kind: .photo, creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height
                )
                media.append(ImportedMedia(item: item, url: url))
            }
            if let videoCodec {
                let url = folder.appending(path: "clip-\(videoCodec.rawValue).mov")
                try await TestMedia.writeVideo(
                    to: url, duration: 4, width: 640, height: 360, color: TestMedia.RGB.palette[2],
                    date: TestMedia.baseDate.addingTimeInterval(30), codec: videoCodec
                )
                let info = try await MediaMetadataReader.readVideo(at: url)
                let item = MediaItem(
                    id: "v", kind: .video, creationDate: info.date, duration: info.duration,
                    pixelWidth: info.width, pixelHeight: info.height, hasAudio: info.hasAudio
                )
                media.append(ImportedMedia(item: item, url: url))
            }
            let song = MusicCatalog.defaultTrack?.choice
            let input = GenerationInput(media: media, targetDuration: 6, style: .travel, song: song, seed: 1, format: .portrait)
            let edl = FilmGenerator.plan(input)
            let settings = RenderSettings(format: .portrait, resolution: .hd1080)
            let built = try await FilmGenerator.build(edl, media: media, song: song, settings: settings)
            let url = folder.appending(path: "film-\(UUID().uuidString).mp4")
            try await VideoExporter.export(built, resolution: .hd1080, to: url) { _ in }
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            return "ok, \(duration) s"
        } catch {
            return "\(error)"
        }
    }
}
