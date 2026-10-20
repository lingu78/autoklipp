import AVFoundation
import ClipCore
import Foundation
import ImageIO
import Testing

@testable import Autoklipp

/// Phase 2 acceptance: "Blurry and shaky segments are skipped; faces are prioritised in a test set."
@Suite("Phase 2 – analysis and smart selection", .serialized)
struct AnalysisTests {
    /// 4 s steady and sharp, 4 s blurred, 4 s shaking, 4 s panning smoothly.
    static let looks: [PatternVideo.Look] =
        Array(repeating: .steady, count: 4) + Array(repeating: .blurred, count: 4)
        + Array(repeating: .shaky, count: 4) + Array(repeating: .pan, count: 4)

    func analysedVideo() async throws -> (ImportedMedia, MediaAnalysis, URL) {
        let folder = try TestMedia.makeFolder()
        let url = folder.appending(path: "quality.mov")
        try await PatternVideo.write(to: url, looks: Self.looks)
        let info = try await MediaMetadataReader.readVideo(at: url)
        let media = ImportedMedia(
            item: MediaItem(id: "quality", kind: .video, creationDate: TestMedia.baseDate, duration: info.duration,
                            pixelWidth: info.width, pixelHeight: info.height),
            url: url
        )
        return (media, try await MediaAnalyzer.analyse(media), folder)
    }

    func mean(_ analysis: MediaAnalysis, _ seconds: Range<Double>, _ value: (FrameMetrics) -> Double) -> Double {
        // Skip the half second at each boundary, where samples straddle two looks.
        let inner = (seconds.lowerBound + 0.5)..<(seconds.upperBound - 0.5)
        let picked = analysis.segments.filter { inner.contains($0.start + $0.duration / 2) }
        return picked.map { value($0.metrics) }.reduce(0, +) / Double(max(1, picked.count))
    }

    @Test(.timeLimit(.minutes(10)))
    func blurAndShakeAreMeasuredAndAvoided() async throws {
        let (media, analysis, folder) = try await analysedVideo()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(analysis.segments.count == 32)

        let sharpSteady = mean(analysis, 0..<4) { $0.sharpness }
        let sharpBlurred = mean(analysis, 4..<8) { $0.sharpness }
        print("sharpness steady \(sharpSteady), blurred \(sharpBlurred)")
        #expect(sharpSteady > 0.45)
        #expect(sharpBlurred < Scorer.blurThreshold)

        let shakeSteady = mean(analysis, 0..<4) { $0.shake }
        let shakeShaky = mean(analysis, 8..<12) { $0.shake }
        let shakePan = mean(analysis, 12..<16) { $0.shake }
        print("shake steady \(shakeSteady), shaky \(shakeShaky), pan \(shakePan)")
        #expect(shakeShaky > Scorer.shakeThreshold)
        #expect(shakeSteady < 0.3)
        #expect(shakePan < 0.3)

        // The planner keeps out of the blurred and shaky seconds.
        let input = GenerationInput(
            media: [media], analyses: [media.id: analysis], targetDuration: 5, style: .travel,
            track: MusicCatalog.defaultTrack, seed: 9, format: .portrait
        )
        let edl = FilmGenerator.plan(input)
        #expect(abs(edl.duration - 5) <= Timing.lengthTolerance)
        for clip in edl.clips {
            let middle = clip.sourceStart + clip.sourceDuration / 2
            #expect(!(4.0..<12.0).contains(middle), "picked weak footage at \(clip.sourceStart)–\(clip.sourceEnd)")
        }
    }

    @Test func stillsGetSharpnessExposureAndASignature() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sharpURL = folder.appending(path: "sharp.png")
        let blurURL = folder.appending(path: "blur.png")
        let image = try PatternVideo.pattern(width: 2000, height: 1500, seed: 3)
        try write(image, to: sharpURL)
        try write(try PatternVideo.blur(image, sigma: 18), to: blurURL)
        func analyse(_ url: URL) async throws -> MediaAnalysis {
            let media = ImportedMedia(item: MediaItem(id: url.lastPathComponent, kind: .photo, pixelWidth: 2000, pixelHeight: 1500), url: url)
            return try await MediaAnalyzer.analyse(media)
        }
        let sharp = try await analyse(sharpURL)
        let blurred = try await analyse(blurURL)
        let sharpness = (sharp.still?.sharpness ?? 0, blurred.still?.sharpness ?? 1)
        print("still sharpness \(sharpness)")
        #expect(sharpness.0 > 0.45)
        #expect(sharpness.1 < Scorer.blurThreshold)
        #expect(sharp.stillSignature?.count == 48)
        #expect((0.2...0.8).contains(sharp.still?.exposure ?? -1))
        #expect(Scorer.stillScore(sharp.still!) > Scorer.stillScore(blurred.still!))
    }

    /// Runs when CI has downloaded a public-domain portrait (AUTOKLIPP_FACE_IMAGE).
    @Test func facesAreFoundAndPreferredInATestSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUTOKLIPP_FACE_IMAGE"],
            FileManager.default.fileExists(atPath: path)
        else {
            print("Skipping: no portrait available (AUTOKLIPP_FACE_IMAGE).")
            return
        }
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var media: [ImportedMedia] = []
        let portraitURL = URL(filePath: path)
        let size = try MediaMetadataReader.readImage(at: portraitURL)
        let portrait = ImportedMedia(
            item: MediaItem(id: "portrait", kind: .photo, creationDate: TestMedia.baseDate.addingTimeInterval(300),
                            pixelWidth: size.width, pixelHeight: size.height),
            url: portraitURL
        )
        media.append(portrait)
        for index in 0..<9 {
            let url = folder.appending(path: "scene-\(index).png")
            try write(try PatternVideo.pattern(width: 800, height: 600, seed: UInt64(20 + index)), to: url)
            media.append(ImportedMedia(
                item: MediaItem(id: "scene-\(index)", kind: .photo, creationDate: TestMedia.baseDate.addingTimeInterval(Double(index) * 60), pixelWidth: 800, pixelHeight: 600),
                url: url
            ))
        }
        var analyses: [String: MediaAnalysis] = [:]
        for item in media { analyses[item.id] = try await MediaAnalyzer.analyse(item) }
        #expect((analyses["portrait"]?.still?.faceCount ?? 0) >= 1, "Vision should find the face")
        #expect(analyses["portrait"]?.faceRegions.isEmpty == false)
        #expect(analyses.filter { $0.key != "portrait" }.allSatisfy { $0.value.still?.faceCount == 0 })

        // Room for only a few of the ten photos: the portrait must be among them for any seed.
        for seed in UInt64(1)...5 {
            let input = GenerationInput(
                media: media, analyses: analyses, targetDuration: 8, style: .energetic,
                track: MusicCatalog.defaultTrack, seed: seed, format: .portrait
            )
            let edl = FilmGenerator.plan(input)
            #expect(edl.clips.contains { $0.mediaID == "portrait" }, "seed \(seed) left out the face")
        }
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw TestMedia.TestError.couldNotWrite
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestMedia.TestError.couldNotWrite }
    }
}
