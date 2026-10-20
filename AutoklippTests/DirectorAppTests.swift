import ClipCore
import Foundation
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

    /// Runs only where Apple Intelligence is available (a device or a Mac that has it).
    @Test(.timeLimit(.minutes(5)))
    func theModelPicksChildrenWhenAskedTo() async throws {
        guard FilmDirector.isAvailable else {
            print("Skipping: Apple Intelligence is not available here.")
            return
        }
        let (media, analyses) = Self.material()
        let plan = try #require(
            try await FilmDirector.plan(instruction: "only pictures with the children", media: media.map(\.item), analyses: analyses)
        )
        var input = GenerationInput(media: media, analyses: analyses, targetDuration: 20, style: .travel, song: nil, seed: 2, format: .portrait)
        input.directorPlan = plan
        let edl = FilmGenerator.plan(input)
        print("child share with the model's plan: \(Self.childShare(edl, analyses))")
        #expect(Self.childShare(edl, analyses) > 0.5)
    }
}
