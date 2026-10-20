import AVFoundation
import ClipCore
import CoreImage
import Foundation
import Testing

@testable import Autoklipp

/// Phase 3 acceptance: "Cuts lie within 50 ms of the beat; the styles feel clearly different."
@Suite("Phase 3 – rhythm, styles and mix", .serialized)
struct RhythmTests {
    static let tolerance = 0.05

    /// Distance from `trackTime` to the nearest beat of `beats`.
    func distanceToBeat(_ trackTime: Double, _ beats: [Double]) -> Double {
        beats.map { abs($0 - trackTime) }.min() ?? .infinity
    }

    /// Track time heard at a film time, following the music layout.
    func trackTime(atFilmTime time: Double, _ segments: [MusicSegment]) -> Double? {
        guard let segment = segments.last(where: { $0.filmStart <= time + 1e-9 }) else { return nil }
        return segment.trackStart + (time - segment.filmStart)
    }

    @Test(arguments: ["sommarvind", "full-fart", "morgondimma"])
    func bundledSongsDecodeOnTheirBeatGrid(id: String) async throws {
        let track = try #require(MusicCatalog.track(id: id))
        let url = try #require(track.url)
        let envelope = try await AudioAnalyzer.analyse(url: url)
        let result = try #require(BeatTracker.track(envelope: envelope.onset, frameRate: envelope.frameRate, timeOffset: envelope.timeOffset))
        let truth = track.info.beats.filter { $0 > 3 && $0 < track.loopEnd - 3 }
        let errors = truth.map { beat in result.beats.map { $0 - beat }.min { abs($0) < abs($1) } ?? .infinity }
        let hits = errors.filter { abs($0) <= Self.tolerance }
        let sortedErrors = hits.sorted()
        let median = sortedErrors.isEmpty ? .infinity : sortedErrors[sortedErrors.count / 2]
        print("\(id): \(result.bpm) BPM detected (true \(track.bpm)), \(hits.count)/\(truth.count) beats within 50 ms, median offset \(median * 1000) ms")
        #expect(Double(hits.count) / Double(truth.count) > 0.9)
        // Decoding adds no delay (AAC priming is handled), so beats are not systematically late.
        #expect(abs(median) < 0.02)
        let ratio = result.bpm / track.bpm
        #expect([0.5, 1, 2].contains { abs(ratio - $0) < 0.03 }, "tempo \(result.bpm) for \(track.bpm)")
    }

    @Test(arguments: StyleID.allCases)
    func cutsLandOnTheBeatOfBuiltInSongs(style: StyleID) throws {
        let song = try #require(MusicCatalog.suggestion(for: style)?.choice)
        let media = (0..<40).map { index in
            MediaItem(
                id: "m\(index)", kind: index % 3 == 0 ? .photo : .video,
                creationDate: TestMedia.baseDate.addingTimeInterval(Double(index) * 60), duration: 30
            )
        }.map { ImportedMedia(item: $0, url: URL(filePath: "/dev/null")) }
        let input = GenerationInput(media: media, targetDuration: 90, style: style, song: song, seed: 4, format: .portrait)
        let edl = FilmGenerator.plan(input)
        let segments = try #require(edl.music?.segments)
        for clip in edl.clips.dropFirst() {
            let time = try #require(trackTime(atFilmTime: clip.timelineStart, segments))
            #expect(distanceToBeat(time, song.info.beats) <= Self.tolerance, "\(style): cut at \(clip.timelineStart)")
        }
    }

    /// The user's own song: beats are detected, and cuts must still land on the real beats.
    @Test(.timeLimit(.minutes(5)))
    func cutsLandOnTheBeatOfAnImportedSong() async throws {
        let truth = try #require(MusicCatalog.track(id: "vagen-soderut"))
        let url = try #require(truth.url)
        let detected = try await AudioAnalyzer.trackInfo(id: "custom-test", url: url)
        let song = SongChoice(id: detected.id, title: "Imported", url: url, info: detected, isCustom: true)
        let media = (0..<30).map { index in
            ImportedMedia(
                item: MediaItem(id: "m\(index)", kind: .video, creationDate: TestMedia.baseDate.addingTimeInterval(Double(index) * 60), duration: 40),
                url: URL(filePath: "/dev/null")
            )
        }
        for style in [StyleID.energetic, .travel, .calm] {
            let input = GenerationInput(media: media, targetDuration: 60, style: style, song: song, seed: 2, format: .portrait)
            let edl = FilmGenerator.plan(input)
            let segments = try #require(edl.music?.segments)
            var worst = 0.0
            for clip in edl.clips.dropFirst() {
                let time = try #require(trackTime(atFilmTime: clip.timelineStart, segments))
                worst = max(worst, distanceToBeat(time, truth.info.beats))
            }
            print("imported song, \(style): worst cut \(worst * 1000) ms from the beat")
            #expect(worst <= Self.tolerance)
        }
    }

    @Test func stylesLookAndPaceDifferently() throws {
        // Pace: average clip length per style on the same material and song.
        let song = try #require(MusicCatalog.track(id: "sommarvind")?.choice)
        let media = (0..<30).map { index in
            ImportedMedia(
                item: MediaItem(id: "m\(index)", kind: .video, creationDate: TestMedia.baseDate.addingTimeInterval(Double(index) * 60), duration: 60),
                url: URL(filePath: "/dev/null")
            )
        }
        var averages: [StyleID: Double] = [:]
        var transitions: [StyleID: Set<TransitionKind>] = [:]
        for style in StyleID.allCases {
            let edl = FilmGenerator.plan(GenerationInput(media: media, targetDuration: 60, style: style, song: song, seed: 1, format: .portrait))
            averages[style] = edl.duration / Double(edl.clips.count)
            transitions[style] = Set(edl.clips.dropFirst().map(\.transitionIn.kind))
        }
        print("average clip length by style: \(averages)")
        #expect(averages[.calm]! > 2.5 * averages[.energetic]!)
        #expect(transitions[.calm] == [.crossfade])
        #expect(transitions[.energetic]!.contains(.cut))
        #expect(transitions[.nostalgic]!.contains(.dipToWhite))
        #expect(transitions[.cinematic]!.contains(.dipToBlack))

        // Look: every style's colour treatment changes the same picture differently.
        let image = CIImage(color: CIColor(red: 0.7, green: 0.45, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let context = CIContext()
        var colours: [FilterKind: SIMD3<Double>] = [:]
        for style in StyleID.allCases {
            let filter = StyleParameters.preset(style).filter
            let output = FrameRenderer.apply(filter, to: image, bounds: bounds)
            let average = output.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: bounds)])
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            colours[filter] = SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
        }
        let values = Array(colours.values)
        #expect(values.count == StyleID.allCases.count)
        for i in values.indices {
            for j in values.indices where j > i {
                let difference = values[i] - values[j]
                #expect((difference * difference).sum().squareRoot() > 0.02)
            }
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func musicIsLoweredUnderLoudOriginalSound() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var media: [ImportedMedia] = []
        for index in 0..<3 {
            let url = folder.appending(path: "talk-\(index).mov")
            try await TestMedia.writeVideo(
                to: url, duration: 6, width: 320, height: 180, color: TestMedia.RGB.palette[index],
                date: TestMedia.baseDate.addingTimeInterval(Double(index) * 60), toneLevel: 0.4
            )
            let info = try await MediaMetadataReader.readVideo(at: url)
            #expect(info.hasAudio)
            media.append(ImportedMedia(
                item: MediaItem(id: "talk-\(index)", kind: .video, creationDate: info.date, duration: info.duration,
                                pixelWidth: info.width, pixelHeight: info.height, hasAudio: true),
                url: url
            ))
        }
        var analyses: [String: MediaAnalysis] = [:]
        for item in media { analyses[item.id] = try await MediaAnalyzer.analyse(item) }
        #expect((analyses["talk-0"]?.segments.compactMap(\.metrics.audioLevel).max() ?? 0) > AudioMixPlan.loudnessForDucking)

        let song = try #require(MusicCatalog.track(id: "sommarvind")?.choice)
        var input = GenerationInput(media: media, analyses: analyses, targetDuration: 12, style: .travel, song: song, seed: 3, format: .square)
        input.originalAudio = true
        let edl = FilmGenerator.plan(input)
        #expect(edl.clips.allSatisfy { $0.audioVolume == AudioMixPlan.loudClipVolume })
        let built = try await FilmGenerator.build(edl, media: media, song: song, settings: .preview(.square))
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count >= 2, "music plus the videos' own sound")

        // The music's mix parameters: lowered in the middle of the film.
        let middle = CMTime(seconds: edl.duration / 2, preferredTimescale: 600)
        let levels = built.audioMix.inputParameters.map { parameters -> Float in
            var start: Float = -1
            var end: Float = -1
            var range = CMTimeRange.zero
            _ = parameters.getVolumeRamp(for: middle, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
        #expect(levels.contains { abs($0 - Float(AudioMixPlan.duckedMusicVolume)) < 0.01 }, "levels \(levels)")
    }
}
