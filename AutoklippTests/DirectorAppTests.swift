import ClipCore
import Foundation
import FoundationModels
import Testing

@testable import Autoklipp

/// Phase 5 acceptance: "The instruction 'only pictures with the children' gives a film where most
/// clips contain children; the app works fully without AI."
@Suite("Phase 5 – AI director and fallback", .serialized)
@MainActor
struct DirectorAppTests {
    /// Thirty photos; every third one shows children (as Vision would label them).
    static func material() -> ([ImportedMedia], [String: MediaAnalysis]) {
        var media: [ImportedMedia] = []
        var analyses: [String: MediaAnalysis] = [:]
        for index in 0..<30 {
            let item = MediaItem(
                id: "p\(index)", kind: .photo, creationDate: TestMedia.baseDate.addingTimeInterval(Double(index) * 300)
            )
            media.append(ImportedMedia(item: item, url: URL(filePath: "/dev/null")))
            let child = index % 3 == 0
            analyses[item.id] = MediaAnalysis(
                mediaID: item.id,
                still: FrameMetrics(faceCount: child ? 2 : 0, faceQuality: 0.6),
                labels: child ? ["child", "people", "grass"] : ["sky", "tree", "lake"]
            )
        }
        return (media, analyses)
    }

    static func childShare(_ edl: EditDecisionList, _ analyses: [String: MediaAnalysis]) -> Double {
        let children = edl.clips.filter { analyses[$0.mediaID]?.labels.contains("child") == true }.count
        return Double(children) / Double(max(1, edl.clips.count))
    }

    @Test func withoutAppleIntelligenceTheDescriptionIsIgnoredAndTheFilmIsMade() async throws {
        guard !FilmDirector.isAvailable else { return }
        let model = AppModel(inMemory: true)
        #expect(!model.directorAvailable, "the text field must stay hidden")
        let (media, analyses) = Self.material()
        model.draft.media = media
        model.draft.analyses = analyses
        model.draft.instruction = "bara bilder med barnen"
        #expect(model.draft.instructionInEffect.isEmpty)
        let input = GenerationInput(draft: model.draft)
        #expect(input.instruction.isEmpty)
        let edl = FilmGenerator.plan(input)
        #expect(abs(edl.duration - model.draft.targetDuration) <= Timing.lengthTolerance)
        #expect(!edl.clips.isEmpty)
        #expect(GenerationStep.steps(directed: false) == [.analysing, .selecting, .rendering])
    }

    @Test func aDirectorPlanIsFollowedForSelectionStyleAndTitle() {
        let (media, analyses) = Self.material()
        let descriptions = DirectorBriefing.describe(media.map(\.item), analyses: analyses)
        let childIDs = descriptions.filter { $0.line.contains("child") }.map(\.shortID)
        let plan = DirectorBriefing.plan(
            from: [DirectorAnswer(clipIDs: childIDs, style: "calm", title: "Barnen i sommar")], descriptions: descriptions
        )
        var input = GenerationInput(
            media: media, analyses: analyses, targetDuration: 20, style: .travel,
            song: MusicCatalog.track(id: "morgondimma")?.choice, seed: 2, format: .portrait
        )
        input.directorPlan = plan
        let edl = FilmGenerator.plan(input)
        #expect(Self.childShare(edl, analyses) > 0.8)
        #expect(abs(edl.duration - 20) <= Timing.lengthTolerance)
        #expect(plan?.suggestedStyle == .calm)
        #expect(plan?.title == "Barnen i sommar")
    }

    /// A style the director suggests brings its song while the user has picked none, so the film
    /// is timed to the song the project then has (and exports with).
    @Test(.timeLimit(.minutes(5)))
    func aSuggestedStyleBringsItsSong() async throws {
        let (media, analyses) = Self.material()
        let draft = ProjectDraft()
        draft.media = media
        draft.analyses = analyses
        draft.lengthChoice = .preset(20)
        draft.directorPlan = DirectorPlan(mediaIDs: media.map(\.id), suggestedStyle: .calm, title: "Barnen i sommar")
        let calmSong = try #require(MusicCatalog.suggestion(for: .calm))
        #expect(calmSong.id != draft.musicTrackID)

        let input = GenerationInput(draft: draft)
        let output = try await FilmGenerator.generate(input, settings: .preview(.portrait)) { _, _ in }
        draft.adopt(output, from: input)
        #expect(output.style == .calm)
        #expect(output.edl.music?.trackID == calmSong.id)
        #expect(draft.musicTrackID == calmSong.id)
        #expect(draft.song(for: output.edl)?.id == draft.song?.id)
        #expect(draft.title == "Barnen i sommar")

        // A song or a title the user chose stays; a removed title does not come back.
        var chosen = GenerationInput(draft: draft)
        chosen.style = .travel
        chosen.song = MusicCatalog.track(id: "hoppborg")?.choice
        chosen.songFollowsStyle = false
        chosen.titleFollowsDirector = false
        chosen.title = ""
        chosen.follow(draft.directorPlan)
        #expect(chosen.style == .calm)
        #expect(chosen.song?.id == "hoppborg")
        #expect(chosen.title.isEmpty)
    }

    /// New material makes the director look again (6d: the plan is reused only for the same
    /// description and material).
    @Test func aDirectorPlanIsForgottenWhenMaterialIsAdded() {
        let (media, _) = Self.material()
        let draft = ProjectDraft()
        draft.media = Array(media.prefix(20))
        draft.directorPlan = DirectorPlan(mediaIDs: ["p0", "p3"])
        draft.directorInstruction = draft.instructionInEffect
        draft.materialIDs = Set(draft.media.map(\.id))
        draft.forgetDirectorPlanIfStale()
        #expect(draft.directorPlan != nil)
        draft.media = media
        draft.forgetDirectorPlanIfStale()
        #expect(draft.directorPlan == nil)
    }

    /// With a description the film is always made: without the model, when it fails, or with
    /// its plan.
    @Test(.timeLimit(.minutes(5)))
    func aDescriptionNeverStopsTheFilm() async throws {
        let (media, analyses) = Self.material()
        var input = GenerationInput(
            media: media, analyses: analyses, targetDuration: 20, style: .travel,
            song: MusicCatalog.track(id: "morgondimma")?.choice, seed: 2, format: .portrait
        )
        input.instruction = "bara bilder med barnen"
        let output = try await FilmGenerator.generate(input, settings: .preview(.portrait)) { _, _ in }
        print("director plan: \(output.directorPlan != nil), failed: \(output.directorFailed)")
        #expect(abs(output.edl.duration - 20) <= Timing.lengthTolerance)
        #expect(!output.edl.clips.isEmpty)
        #expect(output.directorFailed == (output.directorPlan == nil))
    }

    /// Runs only where Apple Intelligence is available (a device or a Mac that has it).
    @Test(.timeLimit(.minutes(5)))
    func theModelPicksChildrenWhenAskedTo() async throws {
        guard FilmDirector.isAvailable else {
            print("Skipping: Apple Intelligence is not available here.")
            return
        }
        let (media, analyses) = Self.material()
        let answer: DirectorPlan?
        do {
            answer = try await FilmDirector.plan(instruction: "only pictures with the children", media: media.map(\.item), analyses: analyses)
        } catch {
            #if targetEnvironment(simulator)
            // The simulator can report the model as available without having its files.
            print("Skipping: the model could not run in the simulator: \(error)")
            return
            #else
            throw error
            #endif
        }
        let plan = try #require(answer)
        var input = GenerationInput(media: media, analyses: analyses, targetDuration: 20, style: .travel, song: nil, seed: 2, format: .portrait)
        input.directorPlan = plan
        let edl = FilmGenerator.plan(input)
        print("child share with the model's plan: \(Self.childShare(edl, analyses))")
        #expect(Self.childShare(edl, analyses) > 0.5)
    }
}
