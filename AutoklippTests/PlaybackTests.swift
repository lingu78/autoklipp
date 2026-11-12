import AVFoundation
import AVKit
import ClipCore
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// The preview must play, not only build: a film whose player item fails shows only a
/// crossed-out play symbol. When it fails, the log shows which part of the film the player
/// refuses, and whether plain files play on this system at all.
@Suite("Preview playback", .serialized)
@MainActor
struct PlaybackTests {
    @Test(.timeLimit(.minutes(10)))
    func thePreviewPlays() async throws {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        defer { model.draft.storage.removeAll() }
        let media = try await TestMedia.mixedSet(count: 8, in: model.draft.storage.mediaDirectory)
        model.draft.media = media
        model.draft.lengthChoice = .preset(15)
        let input = GenerationInput(draft: model.draft)
        let output = try await FilmGenerator.generate(input, settings: .preview(.portrait)) { _, _ in }
        let built = output.built

        // What plays on this system, part by part.
        var report: [String: Bool] = [:]
        func attempt(_ name: String, _ item: AVPlayerItem) async {
            let played = await Self.plays(item)
            report[name] = played.ok
            print("playback \(name): \(played.ok ? "plays" : "fails") – \(played.detail)")
        }
        if let song = MusicCatalog.tracks.first?.url {
            await attempt("plain song", AVPlayerItem(url: song))
        }
        if let video = media.first(where: { $0.item.kind == .video }) {
            await attempt("plain video", AVPlayerItem(url: video.url))
        }
        await attempt("composition only", AVPlayerItem(asset: built.composition))
        let withVideo = AVPlayerItem(asset: built.composition)
        withVideo.videoComposition = built.videoComposition
        await attempt("with the compositor", withVideo)
        let withAudio = AVPlayerItem(asset: built.composition)
        withAudio.audioMix = built.audioMix
        withAudio.audioTimePitchAlgorithm = .spectral
        await attempt("with the audio mix", withAudio)
        await attempt("the preview's item", built.makePlayerItem())

        #expect(report["the preview's item"] == true, "the preview plays: \(report)")
    }

    /// On screen the compositor draws for display, which a player without a view never asks
    /// for: the preview in a plain player layer, in AVKit's player and in SwiftUI's VideoPlayer
    /// (the app's own view).
    @Test(.timeLimit(.minutes(10)))
    func thePreviewPlaysOnScreen() async throws {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        defer { model.draft.storage.removeAll() }
        model.draft.media = try await TestMedia.mixedSet(count: 8, in: model.draft.storage.mediaDirectory)
        model.draft.lengthChoice = .preset(15)
        let output = try await FilmGenerator.generate(GenerationInput(draft: model.draft), settings: .preview(.portrait)) { _, _ in }
        let built = output.built
        ClipCompositor.trace = { print("compositor: \($0)") }
        defer { ClipCompositor.trace = nil }

        let showsVideo = try await DisplayCheck.videoShowsOnScreen()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var report: [String: Bool] = [:]

        // A plain layer, no AVKit.
        let layerPlayer = AVPlayer(playerItem: built.makePlayerItem())
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let layer = AVPlayerLayer(player: layerPlayer)
        layer.frame = host.view.bounds
        host.view.layer.addSublayer(layer)
        report["in a player layer"] = await Self.playsOnScreen(layerPlayer, "in a player layer")

        // AVKit's player view.
        let kitPlayer = AVPlayer(playerItem: built.makePlayerItem())
        let controller = AVPlayerViewController()
        controller.player = kitPlayer
        window.rootViewController = controller
        report["in AVPlayerViewController"] = await Self.playsOnScreen(kitPlayer, "in AVPlayerViewController")

        // SwiftUI's VideoPlayer, as the preview shows the film.
        let swiftUIPlayer = AVPlayer(playerItem: built.makePlayerItem())
        window.rootViewController = UIHostingController(rootView: VideoPlayer(player: swiftUIPlayer))
        report["in VideoPlayer"] = await Self.playsOnScreen(swiftUIPlayer, "in VideoPlayer")

        if showsVideo {
            #expect(report["in VideoPlayer"] == true, "the preview plays on screen: \(report)")
        } else {
            withKnownIssue("This simulator shows no video on screen, not even a plain file", isIntermittent: true) {
                #expect(report["in VideoPlayer"] == true, "the preview plays on screen: \(report)")
            }
        }
    }

    /// Which part of the film a player showing it on screen refuses: the tracks alone, the
    /// video composition's colour properties, the compositor's buffers or colour handling, or the
    /// black carrier track stretched under the film. Logs only; thePreviewPlaysOnScreen decides.
    @Test(.timeLimit(.minutes(10)))
    func variantsOfTheFilmOnScreen() async throws {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        defer { model.draft.storage.removeAll() }
        model.draft.media = try await TestMedia.mixedSet(count: 8, in: model.draft.storage.mediaDirectory)
        model.draft.lengthChoice = .preset(15)
        let output = try await FilmGenerator.generate(GenerationInput(draft: model.draft), settings: .preview(.portrait)) { _, _ in }
        let built = output.built
        ClipCompositor.trace = { print("compositor: \($0)") }
        defer { ClipCompositor.trace = nil }

        func composition(_ change: (AVMutableVideoComposition) -> Void) -> AVVideoComposition {
            let copy = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
            change(copy)
            return copy
        }
        let original = try #require(built.videoComposition.instructions.first as? ClipInstruction)
        let trackIDs = (original.requiredSourceTrackIDs ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let withoutCarrier = try #require(built.composition.mutableCopy() as? AVMutableComposition)
        if let carrierID = trackIDs.first, let carrier = withoutCarrier.track(withTrackID: carrierID) {
            withoutCarrier.removeTrack(carrier)
        }
        let variants: [(String, AVAsset, AVVideoComposition?)] = [
            ("tracks only", built.composition, nil),
            ("as built", built.composition, built.videoComposition),
            ("without colour properties", built.composition, composition {
                $0.colorPrimaries = nil
                $0.colorTransferFunction = nil
                $0.colorYCbCrMatrix = nil
            }),
            ("wide-colour compositor", built.composition, composition { $0.customVideoCompositorClass = WideColourCompositor.self }),
            ("plain-buffer compositor", built.composition, composition { $0.customVideoCompositorClass = PlainBufferCompositor.self }),
            ("without the carrier track", withoutCarrier, composition {
                $0.instructions = [ClipInstruction(timeRange: original.timeRange, trackIDs: Array(trackIDs.dropFirst()), renderer: original.renderer)]
            }),
            ("any render format", built.composition, composition { $0.customVideoCompositorClass = AnyFormatCompositor.self }),
            ("no buffer requirements", built.composition, composition { $0.customVideoCompositorClass = NoRequirementsCompositor.self }),
            ("HDR compositor", built.composition, composition { $0.customVideoCompositorClass = HDRCompositor.self }),
            ("system compositor", built.composition, try await AVMutableVideoComposition.videoComposition(withPropertiesOf: built.composition)),
        ]

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for (name, asset, videoComposition) in variants {
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = videoComposition
            let player = AVPlayer(playerItem: item)
            let layer = AVPlayerLayer(player: player)
            layer.frame = host.view.bounds
            host.view.layer.addSublayer(layer)
            _ = await Self.playsOnScreen(player, "variant \(name)")
            layer.removeFromSuperlayer()
        }

        // Frames pulled from the player instead of shown by a player layer.
        let item = built.makePlayerItem()
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(videoOutput)
        let player = AVPlayer(playerItem: item)
        await PreviewSession.waitUntilReady(item)
        player.play()
        var frames = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            let time = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if videoOutput.hasNewPixelBuffer(forItemTime: time),
               videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                frames += 1
            }
        }
        let pulled = item.status == .readyToPlay && frames > 5
        print("playback on screen variant video output: \(pulled ? "plays" : "fails") – \(frames) frames, \(FoldTransitionTests.describe(player))")
        player.pause()
    }

    static func playsOnScreen(_ player: AVPlayer, _ name: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(500))
        if let item = player.currentItem { await PreviewSession.waitUntilReady(item) }
        player.play()
        try? await Task.sleep(for: .seconds(2))
        let time = player.currentTime().seconds
        let ok = player.currentItem?.status == .readyToPlay && time > 0.5
        print("playback on screen \(name): \(ok ? "plays" : "fails") – \(FoldTransitionTests.describe(player))")
        player.pause()
        return ok
    }

    /// Plays an item for a moment and says whether its time moved.
    static func plays(_ item: AVPlayerItem) async -> (ok: Bool, detail: String) {
        let player = AVPlayer(playerItem: item)
        await PreviewSession.waitUntilReady(item)
        player.play()
        try? await Task.sleep(for: .seconds(1.5))
        let time = player.currentTime().seconds
        player.pause()
        let ok = item.status == .readyToPlay && time > 0.2
        return (ok, FoldTransitionTests.describe(player))
    }
}

/// Whether this simulator can show video on screen at all: a plain test video in a plain player
/// layer. The iPhone Duo simulator on the Xcode 27.1 runner fails this (AVFoundation -12784)
/// while it plays the same video without a view, so the preview's own on-screen checks there
/// are known issues of the simulator, not of the app.
@MainActor
enum DisplayCheck {
    private static var result: Bool?

    static func videoShowsOnScreen() async throws -> Bool {
        if let result { return result }
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "plain.mov")
        try await TestMedia.writeVideo(to: url, duration: 4, width: 640, height: 360, color: TestMedia.RGB.palette[0], date: nil)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let player = AVPlayer(url: url)
        let layer = AVPlayerLayer(player: player)
        layer.frame = host.view.bounds
        host.view.layer.addSublayer(layer)
        let shows = await PlaybackTests.playsOnScreen(player, "plain video")
        window.isHidden = true
        window.rootViewController = nil
        result = shows
        return shows
    }
}

/// Compositor variants for variantsOfTheFilmOnScreen.
final class WideColourCompositor: ClipCompositor {
    @objc var supportsWideColorSourceFrames: Bool { true }
    @objc var canConformColorOfSourceFrames: Bool { true }
}

final class PlainBufferCompositor: ClipCompositor {
    override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
}

final class AnyFormatCompositor: ClipCompositor {
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
}

final class NoRequirementsCompositor: ClipCompositor {
    override var sourcePixelBufferAttributes: [String: any Sendable]? { nil }
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [:] }
}

final class HDRCompositor: ClipCompositor {
    @objc var supportsHDRSourceFrames: Bool { true }
    @objc var supportsWideColorSourceFrames: Bool { true }
    @objc var canConformColorOfSourceFrames: Bool { true }
}

