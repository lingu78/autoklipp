import AVFoundation
import ClipCore
import CoreImage
import Foundation
import Photos
import Testing

@testable import Autoklipp

/// Phase 1 acceptance: "A 1-minute film of 20 mixed clips is exported to Photos, length 60 s ±1 s."
@Suite("Phase 1 acceptance", .serialized)
struct PhaseOneAcceptanceTests {
    @Test(.timeLimit(.minutes(30)))
    func oneMinuteFilmOfTwentyMixedClipsExportsToPhotos() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = try await TestMedia.mixedSet(count: 20, in: folder)
        #expect(media.filter { $0.item.kind == .video }.count == 10)
        #expect(media.allSatisfy { $0.item.creationDate != nil })

        let song = try #require(MusicCatalog.defaultTrack?.choice, "the bundled song is missing")
        let input = GenerationInput(media: media, targetDuration: 60, style: .travel, song: song, seed: 42, format: .portrait)
        let edl = FilmGenerator.plan(input)
        #expect(abs(edl.duration - 60) <= Timing.lengthTolerance)
        #expect(Set(edl.clips.map(\.mediaID)).count == 20, "every clip should be used")

        // Chronological order from the files' own metadata.
        let dates = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.item.creationDate!) })
        let order = edl.clips.map { dates[$0.mediaID]! }
        #expect(order == order.sorted())

        let settings = RenderSettings(format: .portrait, resolution: .hd1080)
        let built = try await FilmGenerator.build(edl, media: media, song: song, settings: settings)
        let url = folder.appending(path: "film.mp4")
        let log = ProgressLog("export")
        try await VideoExporter.export(built, resolution: .hd1080, to: url) { log.report($0) }

        let film = AVURLAsset(url: url)
        let duration = try await film.load(.duration).seconds
        #expect(abs(duration - 60) <= Timing.lengthTolerance, "exported film is \(duration) s")
        let videoTrack = try #require(try await film.loadTracks(withMediaType: .video).first)
        let size = try await videoTrack.load(.naturalSize)
        #expect(size == CGSize(width: 1080, height: 1920))
        #expect(try await !film.loadTracks(withMediaType: .audio).isEmpty, "the film has music")

        // The compositor really drew pictures: frames are not black.
        let generator = AVAssetImageGenerator(asset: film)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for seconds in [1.0, 20.0, 45.0] {
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let brightness = TestMedia.brightness(frame)
            print("frame at \(seconds) s: brightness \(brightness)")
            #expect(brightness > 0.15, "frame at \(seconds) s is too dark")
        }

        // Saving to Photos. CI grants add-only access before the run and sets AUTOKLIPP_CI.
        let inCI = ProcessInfo.processInfo.environment["AUTOKLIPP_CI"] == "1"
        if inCI || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized {
            try await PhotoLibrarySaver.save(videoAt: url)
        } else {
            print("Skipping the Photos step: add-only access has not been granted on this simulator.")
        }
    }
}
