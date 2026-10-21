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
        let input = GenerationInput(draft: model.draft)
        let output = try await FilmGenerator.generate(input, settings: .preview(.portrait)) { _, _ in }
        model.draft.adopt(output, from: input)
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
        #expect(model.draft.edl == session.edl)
        #expect(!model.isEditing)

        // Another song keeps the user's order; the clips are only re-timed to it (F11).
        await model.apply(.setLocked(clipID: moved.id, true))
        let arranged = session.edl.clips.map(\.id)
        let song = try #require(MusicCatalog.track(id: "horisont"))
        model.draft.select(songID: song.id)
        let resung = FilmGenerator.plan(GenerationInput(draft: model.draft))
        #expect(resung.music?.trackID == song.id)
        #expect(resung.clips.contains { $0.id == moved.id })
        let kept = resung.clips.map(\.id).filter(Set(arranged).contains)
        #expect(kept == arranged.filter(Set(kept).contains))
        // A new style draws the film again.
        model.draft.choose(style: .cinematic)
        #expect(model.draft.userArrangement == nil)

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

    /// Export and preview use the song the clip list was timed to, not one picked since.
    @Test func aFilmIsBuiltWithTheSongItWasTimedTo() throws {
        let draft = ProjectDraft()
        let timed = try #require(draft.song)
        let film = EditDecisionList(
            targetDuration: 15, duration: 15, style: .travel, seed: 1, music: MusicCue(trackID: timed.id, segments: []), clips: []
        )
        draft.select(songID: "morgondimma")
        #expect(draft.song?.id == "morgondimma")
        #expect(draft.song(for: film)?.id == timed.id)

        let info = TrackInfo(id: "custom-1", duration: 30, bpm: 100, beats: [0, 0.6])
        draft.customSong = SongChoice(id: "custom-1", title: "Own", url: URL(filePath: "/dev/null"), info: info, isCustom: true)
        var own = film
        own.music = MusicCue(trackID: "custom-1", segments: [])
        #expect(draft.song(for: own)?.id == "custom-1")
        own.music = nil
        #expect(draft.song(for: own) == nil, "a film planned without music stays without music")
    }

    /// Cancelling a Change sheet leaves the draft as it was.
    @Test func aCancelledChangeIsUndone() {
        let draft = ProjectDraft()
        let before = draft.styleAndMusic
        draft.choose(style: .energetic)
        draft.select(songID: "hoppborg")
        draft.originalAudio = true
        #expect(draft.styleAndMusic != before)
        draft.restore(before)
        #expect(draft.styleAndMusic == before)
        #expect(draft.style == .travel && !draft.styleChosenByUser && !draft.musicChosenByUser)
    }

    /// Copies nobody uses are deleted; files a saved film uses are kept.
    @Test func unusedCopiesAreRemoved() async throws {
        let model = AppModel(inMemory: true)

        // A film that was never saved loses its folder when the user starts another one.
        let abandoned = model.draft.storage
        try abandoned.prepare()
        try Data([1]).write(to: abandoned.mediaDirectory.appending(path: "a.jpg"))
        model.newProject()
        try await waitUntil { !exists(abandoned.directory) }

        // Saving drops what the film no longer uses.
        let draft = model.draft
        let storage = draft.storage
        defer { storage.removeAll() }
        try storage.prepare()
        let used = storage.mediaDirectory.appending(path: "used.jpg")
        let unused = storage.mediaDirectory.appending(path: "unused.jpg")
        for url in [used, unused] { try Data([1]).write(to: url) }
        draft.media = [ImportedMedia(item: MediaItem(id: "used", kind: .photo), url: used)]
        draft.edl = EditDecisionList(targetDuration: 15, duration: 15, style: .travel, seed: 1, clips: [])
        #expect(AppModel.unusedFiles(in: storage, keeping: draft.fileNames).map(\.lastPathComponent) == ["unused.jpg"])
        model.save()
        try await waitUntil { !exists(unused) }

        // Leaving a saved film keeps the files it uses, but not ones added and never saved.
        let extra = storage.mediaDirectory.appending(path: "extra.jpg")
        try Data([1]).write(to: extra)
        model.newProject()
        try await waitUntil { !exists(extra) }
        #expect(exists(used))
    }

    /// An edit that finishes after its film was deleted does not bring the film back.
    @Test func aDeletedFilmStaysDeleted() throws {
        let model = AppModel(inMemory: true)
        let draft = model.draft
        draft.edl = EditDecisionList(targetDuration: 15, duration: 15, style: .travel, seed: 1, clips: [])
        model.save()
        let saved = try #require(model.savedProject(id: draft.id))
        model.delete(saved)
        model.save(draft)
        #expect(model.savedProject(id: draft.id) == nil)

        // An edit that finishes after the user left a film that is still saved updates it.
        let other = model.draft
        other.edl = EditDecisionList(targetDuration: 15, duration: 15, style: .travel, seed: 1, clips: [])
        model.save()
        model.newProject()
        other.title = "Midsommar"
        model.save(other)
        #expect(model.savedProject(id: other.id)?.title == "Midsommar")

        // Once the film is opened again, that copy owns it; a late edit of the earlier one is not saved.
        let reopened = try #require(model.savedProject(id: other.id))
        model.open(reopened)
        other.title = "Sankthans"
        model.save(other)
        #expect(model.savedProject(id: other.id)?.title == "Midsommar")
    }

    /// A film from the list that cannot be made is reported, unless the user left it first.
    @Test func aFailedPreviewIsReportedUnlessTheUserLeft() async {
        let model = AppModel(inMemory: true)
        // A film without clips cannot be made.
        model.draft.edl = EditDecisionList(targetDuration: 15, duration: 15, style: .travel, seed: 1, clips: [])
        await model.preparePreview()
        #expect(model.message == AppModel.buildFailedMessage)

        // Going back cancels the preview's task.
        model.message = nil
        let opening = Task { await model.preparePreview() }
        opening.cancel()
        await opening.value
        #expect(model.message == nil)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var attempts = 0
        while !condition(), attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(condition())
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

    /// An edit whose film cannot be made is reported while the film is shown, not after the user left it.
    @Test(.timeLimit(.minutes(10)))
    func aFailedEditIsReportedOnlyForTheShownFilm() async throws {
        let model = try await preparedModel()
        let id = model.draft.id
        let storage = model.draft.storage
        defer { storage.removeAll() }
        // The film's last video is gone, so the film can no longer be made.
        let session = try #require(model.preview)
        let lastVideo = try #require(session.edl.clips.last { $0.kind == .video })
        let missing = try #require(model.draft.media.first { $0.id == lastVideo.mediaID })
        try FileManager.default.removeItem(at: missing.url)
        await model.setTexts(title: "Midsommar", endCredit: "")
        #expect(model.message == AppModel.buildFailedMessage)

        // The user starts a new film while the next change is being made.
        model.message = nil
        let edit = Task { await model.setTexts(title: "Sankthans", endCredit: "") }
        await Task.yield()
        #expect(model.isEditing)
        model.newProject()
        await edit.value
        #expect(model.message == nil)
        // The film the user left still keeps the change.
        #expect(model.savedProject(id: id)?.title == "Sankthans")
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
            title: TextCard(text: "MMMMMMMM"), endCredit: TextCard(text: "Sommaren 2026 · Familjen Berg")
        ))
        let none: (CMPersistentTrackID) -> CVPixelBuffer? = { _ in nil }
        func gain(at time: Double) -> Double {
            let base = TestMedia.brightness(plain.image(at: time, sourceFrame: none))
            let text = TestMedia.brightness(titled.image(at: time, sourceFrame: none))
            print("text at \(time) s: brightness \(base) → \(text)")
            #expect(base > 0.02, "the dark still itself is drawn")
            return text - base
        }
        #expect(gain(at: 1.5) > 0.005)
        #expect(abs(gain(at: 5)) < 0.002)
        #expect(gain(at: 8.5) > 0.001)
        #expect(abs(FrameRenderer.fade(0.45, from: 0.2, to: 3.2) - 0.5) < 1e-9)
    }
}
