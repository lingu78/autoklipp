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

    @Test(.timeLimit(.minutes(2)))
    func crossfadeHoldsTheEdgeFramesOfVideosWithoutSpareFootage() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = try await twoWholeVideos(in: folder)

        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = built.videoComposition
        reader.add(output)
        reader.startReading()
        var alone: [Double] = []
        var blended: [(time: Double, brightness: Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // The crossfade runs from 2.5 to 3.5 s; each clip shows alone at 1 and 5 s.
            let inTransition = time > 2.5 && time < 3.5
            let isAlone = abs(time - 1) < 0.01 || abs(time - 5) < 0.01
            guard inTransition || isAlone, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let brightness = TestMedia.brightness(CIImage(cvPixelBuffer: buffer))
            if inTransition { blended.append((time, brightness)) } else { alone.append(brightness) }
        }
        #expect(reader.status == .completed)
        #expect(alone.count == 2)
        #expect(blended.count >= 25)
        let darkest = try #require(alone.min())
        for frame in blended {
            // With an empty lane one side of the blend was black: half dark at the cut.
            #expect(frame.brightness > 0.85 * darkest, "frame at \(frame.time) s: \(frame.brightness) vs \(darkest)")
        }
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
}
