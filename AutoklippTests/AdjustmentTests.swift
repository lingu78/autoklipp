import AVFoundation
import ClipCore
import CoreImage
import Foundation
import SwiftData
import Testing

@testable import Autoklipp

/// Phase 4 acceptance: "A change in the strip gives a new preview in under 3 s."
@Suite("Phase 4 – clip strip, regeneration and projects", .serialized)
@MainActor
struct AdjustmentTests {
    /// A model with a generated 60 s film of 20 mixed clips in its preview. The media lie in the
    /// project's own folder, where the app copies imported media.
    func preparedModel() async throws -> AppModel {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        let media = try await TestMedia.mixedSet(count: 20, in: model.draft.storage.mediaDirectory)
        model.draft.media = media
        model.draft.lengthChoice = .preset(60)
        model.draft.seed = 21
        let output = try await FilmGenerator.generate(GenerationInput(draft: model.draft), settings: .preview(.portrait)) { _, _ in }
        model.draft.analyses = output.analyses
        model.draft.edl = output.edl
        model.preview = PreviewSession(edl: output.edl, built: output.built)
        await PreviewSession.waitUntilReady(model.preview!.player.currentItem!)
        return model
    }

    @Test(.timeLimit(.minutes(10)))
    func stripEditsGiveANewPreviewWithinThreeSeconds() async throws {
        let model = try await preparedModel()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        let session = try #require(model.preview)
        let original = session.edl

        // Move
        let moved = original.clips[2]
        await model.apply(.move(clipID: moved.id, toIndex: 8))
        #expect(session.edl.clips[8].id == moved.id)
        try expectFast(model, "move")

        // Remove
        let removed = session.edl.clips[5]
        await model.apply(.remove(clipID: removed.id))
        #expect(!session.edl.clips.contains { $0.id == removed.id })
        #expect(model.draft.exclusions.count == 1)
        try expectFast(model, "remove")

        // Lock
        let locked = session.edl.clips[3]
        await model.apply(.setLocked(clipID: locked.id, true))
        #expect(session.edl.clips[3].isLocked)
        try expectFast(model, "lock")

        // Every change keeps the length and the new film can play.
        #expect(abs(session.edl.duration - 60) <= Timing.lengthTolerance)
        #expect(session.player.currentItem?.status == .readyToPlay)
        let duration = try await session.built.composition.load(.duration).seconds
        #expect(abs(duration - session.edl.duration) < 0.05)

        // A new version keeps the locked clip and leaves out the removed one (F12).
        model.draft.seed = 777
        let again = FilmGenerator.plan(GenerationInput(draft: model.draft))
        #expect(again.clips.contains { $0.id == locked.id && $0.isLocked })
        if removed.kind.isStill {
            #expect(!again.clips.contains { $0.mediaID == removed.mediaID })
        }
    }

    private func expectFast(_ model: AppModel, _ what: String) throws {
        let elapsed = try #require(model.lastEditDuration)
        print("\(what): new preview after \(elapsed)")
        #expect(elapsed < .seconds(3), "\(what) took \(elapsed)")
    }

    @Test(.timeLimit(.minutes(10)))
    func projectsCanBeReopened() async throws {
        let model = try await preparedModel()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        model.draft.select(style: .nostalgic)
        model.draft.title = "Midsommar"
        model.draft.exclusions = [Exclusion(mediaID: "item-3")]
        model.save()

        let saved = try #require(model.savedProject(id: model.draft.id))
        #expect(saved.title == "Midsommar")
        #expect(abs(saved.duration - 60) <= Timing.lengthTolerance)
        let snapshot = try #require(saved.snapshot)
        let reopened = ProjectDraft(id: saved.id, restoring: snapshot)
        #expect(reopened.media.count == model.draft.media.count)
        #expect(reopened.media.map(\.item) == model.draft.media.map(\.item))
        #expect(reopened.edl == model.draft.edl)
        #expect(reopened.style == .nostalgic)
        #expect(reopened.exclusions == [Exclusion(mediaID: "item-3")])
        #expect(reopened.analyses.count == model.draft.analyses.count)
        #expect(reopened.storage.mediaDirectory == model.draft.storage.mediaDirectory)

        // Opening it from the list leads straight to the preview.
        model.open(saved)
        #expect(model.path == [.preview])
        await model.preparePreview()
        #expect(model.preview?.edl == reopened.edl)

        model.delete(saved)
        #expect(model.savedProject(id: saved.id) == nil)
    }

    @Test func titleAndCreditAreDrawnOverTheFilm() throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "dark.png")
        try TestMedia.solidImage(to: url, color: .init(red: 0.1, green: 0.1, blue: 0.15))
        let layer = RenderTimeline.Layer(
            content: .still(url: url, pixelWidth: 400, pixelHeight: 300), mediaID: "dark", start: 0, end: 10,
            transitionIn: .cut, filter: .none, kenBurns: nil
        )
        let plain = FrameRenderer(timeline: RenderTimeline(renderSize: CGSize(width: 360, height: 640), duration: 10, layers: [layer]))
        let titled = FrameRenderer(timeline: RenderTimeline(
            renderSize: CGSize(width: 360, height: 640), duration: 10, layers: [layer],
            title: TextCard(text: "MMMMMMMM"), endCredit: TextCard(text: "SLUT")
        ))
        let none: (CMPersistentTrackID) -> CVPixelBuffer? = { _ in nil }
        func gain(at time: Double) -> Double {
            let base = TestMedia.brightness(plain.image(at: time, sourceFrame: none))
            let text = TestMedia.brightness(titled.image(at: time, sourceFrame: none))
            print("text at \(time) s: brightness \(base) → \(text)")
            #expect(base > 0.05, "the dark still itself is drawn")
            return text - base
        }
        #expect(gain(at: 1.5) > 0.005)
        #expect(abs(gain(at: 5)) < 0.002)
        #expect(gain(at: 8.5) > 0.002)
        #expect(abs(FrameRenderer.fade(0.45, from: 0.2, to: 3.2) - 0.5) < 1e-9)
    }
}
