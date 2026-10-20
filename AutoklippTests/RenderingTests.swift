import AVFoundation
import ClipCore
import CoreImage
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
        let track = try #require(MusicCatalog.defaultTrack)
        // Asking for far more than the material allows gives a shorter film with a notice.
        let input = GenerationInput(media: media, targetDuration: 120, style: .calm, track: track, seed: 1, format: .square)
        let edl = FilmGenerator.plan(input)
        #expect(edl.duration < 100)
        #expect(!edl.notices.isEmpty)
        let built = try await FilmGenerator.build(edl, media: media, track: track, settings: .preview(.square))
        let duration = try await built.composition.load(.duration).seconds
        #expect(abs(duration - edl.duration) < 0.05, "composition \(duration) vs list \(edl.duration)")
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
