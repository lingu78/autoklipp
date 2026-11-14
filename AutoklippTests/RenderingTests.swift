import AVFoundation
import ClipCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Autoklipp

@Suite("Rendering")
struct RenderingTests {
    let context = CIContext()

    func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> (Double, Double, Double) {
        var data = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &data, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    func twoStills(transition: ClipTransition) throws -> FrameRenderer {
        let folder = try TestMedia.makeFolder()
        let red = folder.appending(path: "red.png")
        let blue = folder.appending(path: "blue.png")
        try TestMedia.solidImage(to: red, color: .init(red: 1, green: 0, blue: 0))
        try TestMedia.solidImage(to: blue, color: .init(red: 0, green: 0, blue: 1))
        let timeline = RenderTimeline(
            renderSize: CGSize(width: 320, height: 568),
            duration: 4,
            layers: [
                .init(content: .still(url: red, pixelWidth: 400, pixelHeight: 300), mediaID: "red", start: 0, end: 2,
                      transitionIn: .cut, filter: .none, kenBurns: nil),
                .init(content: .still(url: blue, pixelWidth: 400, pixelHeight: 300), mediaID: "blue", start: 2, end: 4,
                      transitionIn: transition, filter: .none, kenBurns: nil),
            ]
        )
        return FrameRenderer(timeline: timeline)
    }

    @Test func stillsFillTheFrameAndCutOnTime() throws {
        let renderer = try twoStills(transition: .cut)
        let first = renderer.image(at: 1, sourceFrame: { _ in nil })
        #expect(first.extent == CGRect(x: 0, y: 0, width: 320, height: 568))
        let (r1, _, b1) = pixel(first, x: 160, y: 284)
        #expect(r1 > 0.8 && b1 < 0.2)
        let (r2, _, b2) = pixel(renderer.image(at: 2.01, sourceFrame: { _ in nil }), x: 160, y: 284)
        #expect(b2 > 0.8 && r2 < 0.2)
    }

    @Test func crossfadeMixesBothClipsAroundTheCut() throws {
        let renderer = try twoStills(transition: ClipTransition(kind: .crossfade, duration: 1))
        let (red, _, blue) = pixel(renderer.image(at: 2, sourceFrame: { _ in nil }), x: 160, y: 284)
        #expect(red > 0.2 && red < 0.85, "red \(red)")
        #expect(blue > 0.2 && blue < 0.85, "blue \(blue)")
        let (early, _, _) = pixel(renderer.image(at: 1.4, sourceFrame: { _ in nil }), x: 160, y: 284)
        #expect(early > 0.9, "before the transition window only the first clip shows")
    }

    @Test func dipToBlackIsDarkOnTheCut() throws {
        let renderer = try twoStills(transition: ClipTransition(kind: .dipToBlack, duration: 0.8))
        let (red, green, blue) = pixel(renderer.image(at: 2, sourceFrame: { _ in nil }), x: 160, y: 284)
        #expect(red + green + blue < 0.15)
    }

    @Test func widelyDifferentAspectIsFittedOverABlurredBackdrop() {
        #expect(FrameRenderer.fills(sourceAspect: 9.0 / 16, frameAspect: 9.0 / 16))
        #expect(FrameRenderer.fills(sourceAspect: 3.0 / 4, frameAspect: 9.0 / 16))
        #expect(!FrameRenderer.fills(sourceAspect: 16.0 / 9, frameAspect: 9.0 / 16))
    }

    @Test func layerLookupFindsTheOwningClip() throws {
        let renderer = try twoStills(transition: .cut)
        #expect(renderer.timeline.layerIndex(at: 0) == 0)
        #expect(renderer.timeline.layerIndex(at: 1.999) == 0)
        #expect(renderer.timeline.layerIndex(at: 2) == 1)
        #expect(renderer.timeline.layerIndex(at: 10) == 1)
    }

    @Test func videoOrientationFromTransform() {
        #expect(CGImagePropertyOrientation(videoTransform: .identity) == .up)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) == .down)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == .left)
        // Mirrored videos are flipped, not turned upside down.
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0)) == .upMirrored)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1080)) == .downMirrored)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)) == .leftMirrored)
        #expect(CGImagePropertyOrientation(videoTransform: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1080, ty: 1920)) == .rightMirrored)
    }

    @Test func renderSizes() {
        #expect(RenderSettings(format: .portrait).renderSize == CGSize(width: 1080, height: 1920))
        #expect(RenderSettings(format: .landscape, resolution: .uhd4k).renderSize == CGSize(width: 3840, height: 2160))
        #expect(RenderSettings(format: .square).renderSize == CGSize(width: 1080, height: 1080))
        #expect(RenderSettings.preview(.portrait).renderSize == CGSize(width: 720, height: 1280))
    }

    @Test func compositionLastsExactlyAsLongAsTheClipList() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = try await TestMedia.mixedSet(count: 4, in: folder)
        let song = try #require(MusicCatalog.defaultTrack?.choice)
        // Asking for far more than the material allows gives a shorter film with a notice.
        let input = GenerationInput(media: media, targetDuration: 120, style: .calm, song: song, seed: 1, format: .square)
        let edl = FilmGenerator.plan(input)
        #expect(edl.duration < 100)
        #expect(!edl.notices.isEmpty)
        let built = try await FilmGenerator.build(edl, media: media, song: song, settings: .preview(.square))
        let duration = try await built.composition.load(.duration).seconds
        #expect(abs(duration - edl.duration) < 0.05, "composition \(duration) vs list \(edl.duration)")
    }

    @Test func compositionEndsExactlyWithTheFilmWhenTheSongLoops() async throws {
        // At 240 s the looped pieces of this song, each rounded to 1/600 s, add up to one tick
        // more than the film: past the end of the video composition's only instruction.
        let song = try #require(MusicCatalog.track(id: "sommarvind")?.choice)
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "still.png")
        try TestMedia.solidImage(to: url, color: TestMedia.RGB.palette[0])
        let item = MediaItem(id: "still", kind: .photo, pixelWidth: 400, pixelHeight: 300)
        let length = 240.0
        let layout = MusicLayout.make(track: song.info, filmDuration: length)
        #expect(layout.segments.count > 1, "the song should loop")
        let edl = EditDecisionList(
            targetDuration: length, duration: length, style: .calm, seed: 1,
            music: MusicCue(trackID: song.id, segments: layout.segments),
            clips: [
                EDLClip(
                    id: "still", mediaID: "still", kind: .photo, sourceStart: 0, sourceDuration: length,
                    timelineStart: 0, duration: length, beats: 1
                )
            ]
        )
        let built = try await FilmGenerator.build(edl, media: [ImportedMedia(item: item, url: url)], song: song, settings: .preview(.square))
        let duration = try await built.composition.load(.duration)
        #expect(CMTimeCompare(duration, CompositionBuilder.time(length)) == 0, "composition \(duration.value)/\(duration.timescale)")
        let instruction = try #require(built.videoComposition.instructions.last)
        #expect(CMTimeCompare(instruction.timeRange.end, duration) >= 0)
    }

    /// Two videos, each used whole, so neither has footage to spare for the crossfade between them.
    func twoWholeVideos(in folder: URL) async throws -> BuiltComposition {
        var media: [String: ImportedMedia] = [:]
        var clips: [EDLClip] = []
        for (index, color) in [TestMedia.RGB.palette[3], TestMedia.RGB.palette[5]].enumerated() {
            let id = "video-\(index)"
            let url = folder.appending(path: "\(id).mov")
            try await TestMedia.writeVideo(to: url, duration: 3, width: 640, height: 360, color: color, date: nil)
            let item = MediaItem(id: id, kind: .video, duration: 3, pixelWidth: 640, pixelHeight: 360)
            media[id] = ImportedMedia(item: item, url: url)
            clips.append(
                EDLClip(
                    id: id, mediaID: id, kind: .video, sourceStart: 0, sourceDuration: 3,
                    timelineStart: Double(index) * 3, duration: 3, beats: 4,
                    transitionIn: index == 0 ? .cut : ClipTransition(kind: .crossfade, duration: 1)
                )
            )
        }
        let edl = EditDecisionList(targetDuration: 6, duration: 6, style: .calm, seed: 1, clips: clips)
        let settings = RenderSettings(format: .landscape, previewShortSide: 180)
        return try await CompositionBuilder.build(RenderInputs(edl: edl, media: media, musicURL: nil, settings: settings))
    }

    @Test(.timeLimit(.minutes(3)))
    func crossfadeHoldsTheEdgeFramesOfVideosWithoutSpareFootage() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ContinuousClock()
        let started = clock.now
        let built = try await twoWholeVideos(in: folder)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let builtAfter = clock.now - started

        // Reading frames through the compositor is slow on the iOS 26 simulator in CI while the
        // other suites render alongside: 1.7 to 4 frames a second, where reading the whole 6 s
        // film took up to 50 s or more. Only the frames checked below are read.
        let read = await Self.readCrossfade(built, tracks: tracks)
        print("rendering crossfade: built in \(builtAfter), \(read.report)")
        #expect(!read.stalled, "no frame came for 20 s: \(read.report)")
        let alone = read.alone
        let blended = read.blended
        #expect(read.status == .completed)
        #expect(alone.count == 2)
        #expect(blended.count >= 25)
        let darkest = try #require(alone.min())
        for frame in blended {
            // With an empty lane one side of the blend was black: half dark at the cut.
            #expect(frame.brightness > 0.85 * darkest, "frame at \(frame.time) s: \(frame.brightness) vs \(darkest)")
        }
    }

    struct CrossfadeFrames {
        var status: AVAssetReader.Status
        var alone: [Double] = []
        var blended: [(time: Double, brightness: Double)] = []
        var stalled = false
        var report = ""
    }

    /// The crossfade film's frames where each clip shows alone (at 1 and 5 s) and those of the
    /// crossfade (2.5 to 3.5 s), each stretch read on its own. Copying a frame blocks until it is
    /// rendered, so this runs on a thread of its own rather than on one of those Swift's
    /// concurrency shares with the tests running alongside. A watchdog cancels a reader when no
    /// frame has come for 20 s, or once 100 s have gone in all, so a stalled read ends instead of
    /// hanging the test process.
    static func readCrossfade(_ built: BuiltComposition, tracks: [AVAssetTrack]) async -> CrossfadeFrames {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.readCrossfadeBlocking(built, tracks: tracks))
            }
        }
    }

    private static func readCrossfadeBlocking(_ built: BuiltComposition, tracks: [AVAssetTrack]) -> CrossfadeFrames {
        let started = ContinuousClock().now
        var frames = CrossfadeFrames(status: .completed)
        var reports: [String] = []
        for (from, to) in [(0.9, 1.1), (2.45, 3.55), (4.9, 5.1)] {
            guard let reader = try? AVAssetReader(asset: built.composition) else {
                frames.status = .failed
                break
            }
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600)
            )
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.videoComposition = built.videoComposition
            reader.add(output)
            let progress = ReadProgress()
            let spent: Double = (ContinuousClock().now - started) / .seconds(1)
            progress.watch(reader, stall: 20, limit: max(1, 100 - spent))
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                progress.read(time)
                let inTransition = time > 2.5 && time < 3.5
                let isAlone = abs(time - 1) < 0.01 || abs(time - 5) < 0.01
                guard inTransition || isAlone, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let brightness = TestMedia.brightness(CIImage(cvPixelBuffer: buffer))
                if inTransition { frames.blended.append((time, brightness)) } else { frames.alone.append(brightness) }
            }
            progress.finish()
            reports.append("\(from)–\(to) s: \(progress.report)")
            if reader.status != .completed || progress.stoppedByWatchdog {
                frames.status = reader.status
                frames.stalled = progress.stoppedByWatchdog
                break
            }
        }
        frames.report = reports.joined(separator: "; ")
        return frames
    }

    @Test func slowedVideoKeepsItsSoundInStepWithThePicture() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "tone.mov")
        try await TestMedia.writeVideo(
            to: url, duration: 3, width: 320, height: 180, color: TestMedia.RGB.palette[1], date: nil, toneLevel: 0.5
        )
        let item = MediaItem(id: "tone", kind: .video, duration: 3, pixelWidth: 320, pixelHeight: 180, hasAudio: true)
        let stillURL = folder.appending(path: "still.png")
        try TestMedia.solidImage(to: stillURL, color: TestMedia.RGB.palette[0], width: 320, height: 180)
        let stillItem = MediaItem(id: "still", kind: .photo, pixelWidth: 320, pixelHeight: 180)
        // 2.88 s of footage fill 3 s; slowed this little, the clip keeps its sound.
        let clip = EDLClip(
            id: "tone", mediaID: "tone", kind: .video, sourceStart: 0, sourceDuration: 2.88,
            timelineStart: 0, duration: 3, beats: 4, audioVolume: 1
        )
        // The film runs on after the video, so cutting the sound at the film's end cannot hide
        // a sound stretched too far.
        let still = EDLClip(
            id: "still", mediaID: "still", kind: .photo, sourceStart: 0, sourceDuration: 1,
            timelineStart: 3, duration: 1, beats: 1
        )
        let edl = EditDecisionList(targetDuration: 4, duration: 4, style: .calm, seed: 1, clips: [clip, still])
        let inputs = RenderInputs(
            edl: edl,
            media: ["tone": ImportedMedia(item: item, url: url), "still": ImportedMedia(item: stillItem, url: stillURL)],
            musicURL: nil, settings: RenderSettings(format: .landscape, previewShortSide: 180)
        )
        let built = try await CompositionBuilder.build(inputs)
        let sound: AVAssetTrack = try #require(try await built.composition.loadTracks(withMediaType: .audio).first)
        let range = try await sound.load(.timeRange)
        #expect(abs(range.end.seconds - 3) < 0.02, "the sound ends at \(range.end.seconds) s, the picture at 3 s")
        // The 2.88 s of sound are stretched once, by the picture's ratio, from the clip's start.
        let segments = try await sound.load(.segments)
        let segment = try #require(segments.first { !$0.isEmpty })
        let mapping = segment.timeMapping
        #expect(abs(mapping.source.duration.seconds - 2.88) < 0.02, "source \(mapping.source.duration.seconds) s")
        #expect(abs(mapping.target.duration.seconds - 3) < 0.02, "target \(mapping.target.duration.seconds) s")
        #expect(abs(mapping.target.start.seconds) < 0.02, "the sound starts at \(mapping.target.start.seconds) s")
    }
}

@Suite("Bundled music")
struct MusicCatalogTests {
    @Test func defaultSongIsBundledWithItsBeatGrid() async throws {
        let track = try #require(MusicCatalog.defaultTrack)
        let url = try #require(track.url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - track.duration) < 0.2)
        #expect(track.info.beats.count == track.beatCount)
        #expect(track.license == "CC0-1.0")
        let layout = MusicLayout.make(track: track.info, filmDuration: 600)
        #expect(abs(layout.segments.reduce(0) { $0 + $1.duration } - 600) < 1e-6)
    }

    /// Every song in tracks.json is in the app, as long as listed, with a whole beat grid, a loop
    /// inside the song, at least one style and the CC0 licence.
    @Test func everyBundledSongIsThereWithItsBeatGrid() async throws {
        let tracks = MusicCatalog.tracks
        #expect(tracks.count >= 24, "\(tracks.count) songs")
        #expect(Set(tracks.map(\.id)).count == tracks.count, "no song twice")
        for style in StyleID.allCases {
            #expect(tracks.filter { $0.suits(style) }.count >= 4, "songs for \(style)")
        }
        for track in tracks {
            let url = try #require(track.url, "\(track.id) is missing")
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            #expect(abs(duration - track.duration) < 0.2, "\(track.id): \(duration) s, listed \(track.duration) s")
            #expect(track.info.beats.count == track.beatCount, "\(track.id)")
            #expect(track.loopStart < track.loopEnd && track.loopEnd <= track.duration, "\(track.id)")
            #expect(!track.styles.isEmpty, "\(track.id)")
            #expect(track.license == "CC0-1.0", "\(track.id)")
        }
    }
}

/// How far reading a film got, for a test to report when reading stalls; a watchdog cancels the
/// reader once no frame has come for a while, so a stalled read ends instead of hanging the test.
private final class ReadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var frames = 0
    private var lastTime: Double?
    private var lastFrameAt: ContinuousClock.Instant
    private var firstFrameAfter: Double?
    private var done = false
    private var stopped = false
    private var status = ""

    init() {
        started = clock.now
        lastFrameAt = started
    }

    private enum Next { case stop, wait, end }

    /// Cancels the reader once no frame has come for `stall` seconds, or after `limit` seconds.
    func watch(_ reader: AVAssetReader, stall: Double, limit: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            let next: Next = lock.withLock {
                guard !done else { return .end }
                let now = clock.now
                let quiet: Double = (now - lastFrameAt) / .seconds(1)
                let total: Double = (now - started) / .seconds(1)
                guard quiet >= stall || total >= limit else { return .wait }
                stopped = true
                status = "stopped after \(Self.format(total)) s, \(Self.format(quiet)) s without a frame: "
                    + "reader status \(reader.status.rawValue), error \(String(describing: reader.error))"
                return .stop
            }
            switch next {
            case .stop: reader.cancelReading()
            case .wait: watch(reader, stall: stall, limit: limit)
            case .end: break
            }
        }
    }

    func read(_ time: Double) {
        lock.withLock {
            frames += 1
            lastTime = time
            lastFrameAt = clock.now
            if firstFrameAfter == nil { firstFrameAfter = (lastFrameAt - started) / .seconds(1) }
        }
    }

    func finish() {
        lock.withLock {
            if !done && !stopped { status = "done after \(Self.format((clock.now - started) / .seconds(1))) s" }
            done = true
        }
    }

    var stoppedByWatchdog: Bool { lock.withLock { stopped } }

    var report: String {
        lock.withLock {
            "\(frames) frames read, the first after \(firstFrameAfter.map { "\(Self.format($0)) s" } ?? "-"), "
                + "the last at \(lastTime.map { "\($0) s" } ?? "-") in the film, \(status)"
        }
    }

    private static func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }
}
