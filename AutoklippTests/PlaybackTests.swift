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

