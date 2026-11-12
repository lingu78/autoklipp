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
    /// for. The film in a plain player layer, in AVKit's player and in SwiftUI's VideoPlayer is
    /// logged only: the iPhone Duo simulator with iOS 27.1 cannot show a video composition in
    /// any of them (-11800/-12784, while it shows a plain video). What must play is the app's own
    /// preview, which falls back to drawing frames it reads itself where showing fails.
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

        // The app's own preview, as both layouts show it.
        let session = PreviewSession(edl: output.edl, built: built)
        model.preview = session
        window.rootViewController = UIHostingController(
            rootView: ScrollView { FilmPlayerSection(session: session) }.environment(model)
        )
        try await Task.sleep(for: .milliseconds(500))
        session.play()
        var advanced = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(200))
            if session.player.currentTime().seconds > 1 {
                advanced = true
                break
            }
        }
        let drawn = Self.views(of: PulledFrameView.self, in: window).reduce(0) { $0 + $1.framesDrawn }
        print("playback on screen the app's preview: \(advanced ? "plays" : "fails"), draws frames itself: \(session.drawsFramesItself), \(drawn) frames drawn – \(FoldTransitionTests.describe(session.player))")
        session.pause()
        model.preview = nil
        print("playback on screen report: \(report)")

        if showsVideo {
            #expect(advanced, "the app's preview plays on screen")
            if session.drawsFramesItself {
                #expect(drawn > 10, "and its frames are drawn")
            } else {
                #expect(report["in VideoPlayer"] == true, "the system's player shows it where the app does not draw it")
            }
        } else {
            withKnownIssue("This simulator shows no video on screen, not even a plain file", isIntermittent: true) {
                #expect(advanced, "the app's preview plays on screen")
            }
        }
    }

    /// The frames the preview draws itself where the player cannot show the film: read through
    /// the compositor as the export reads them, in step with the time asked for, also after a
    /// jump back or ahead. Works on every simulator, unlike showing the film there.
    @Test(.timeLimit(.minutes(5)))
    func theAppReadsTheFilmsFramesItself() async throws {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        defer { model.draft.storage.removeAll() }
        model.draft.media = try await TestMedia.mixedSet(count: 8, in: model.draft.storage.mediaDirectory)
        model.draft.lengthChoice = .preset(15)
        let output = try await FilmGenerator.generate(GenerationInput(draft: model.draft), settings: .preview(.portrait)) { _, _ in }
        let frames = ComposedFrames(built: output.built)
        let size = output.built.videoComposition.renderSize

        func image(at time: Double) async throws -> CGImage? {
            for _ in 0..<150 {
                if let image = frames.newImage(at: time) { return image }
                try await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let first = try #require(try await image(at: 0), "the first frame is read")
        #expect(first.width == Int(size.width) && first.height == Int(size.height))
        #expect(frames.lastImage != nil)

        // Playing for three seconds: a new frame for most of the film's 30 a second.
        let clock = ContinuousClock()
        let started = clock.now
        var time = 0.0
        var drawn = 0
        while time < 3 {
            try await Task.sleep(for: .milliseconds(30))
            time = (clock.now - started) / .seconds(1)
            if frames.newImage(at: time) != nil { drawn += 1 }
        }
        print("playback read frames: \(drawn) new frames in 3 s")
        #expect(drawn > 30, "\(drawn) frames in 3 s")

        // Back in the film, and far ahead, as the clip strip and edits move the player.
        #expect(try await image(at: 0.5) != nil)
        #expect(try await image(at: 10) != nil)
    }

    static func views<V: UIView>(of type: V.Type, in view: UIView) -> [V] {
        view.subviews.flatMap { subview in
            (subview as? V).map { [$0] } ?? views(of: type, in: subview)
        }
    }

    /// Which kind of film a player layer shows: the tracks alone, with the system's compositor,
    /// or with the app's. Logs only; thePreviewPlaysOnScreen decides. (On the iPhone Duo
    /// simulator with iOS 27.1 only the tracks alone show; a video output instead of a layer
    /// fails the same way. A compositor that names no pixel format for its render context makes
    /// AVFoundation stop the process, so none is tried.)
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

        // The colour properties, the compositor's buffers and colour handling and the carrier
        // track were each ruled out on the iPhone Duo simulator (see DECISIONS.md, §8b).
        let variants: [(String, AVAsset, AVVideoComposition?)] = [
            ("tracks only", built.composition, nil),
            ("system compositor", built.composition, try await AVMutableVideoComposition.videoComposition(withPropertiesOf: built.composition)),
            ("as built", built.composition, built.videoComposition),
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
/// layer. Where not even that shows, the on-screen checks are known issues of the simulator, not
/// of the app. (The iPhone Duo simulator with iOS 27.1 shows it; there only the app's compositor
/// cannot be shown in a player layer.)
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
