import AVFoundation
import ClipCore
import Foundation
import Testing

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
