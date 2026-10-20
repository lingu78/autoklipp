import Foundation
import Testing

@testable import ClipCore

@Suite("AI director – briefing and plan")
struct DirectorTests {
    /// Forty photos; every fourth shows children.
    static func material() -> ([MediaItem], [String: MediaAnalysis]) {
        var media: [MediaItem] = []
        var analyses: [String: MediaAnalysis] = [:]
        for index in 0..<40 {
            let item = MediaItem(
                id: "p\(index)", kind: index % 5 == 0 ? .video : .photo,
                creationDate: Fixtures.baseDate.addingTimeInterval(Double(index) * 600),
                duration: index % 5 == 0 ? 20 : 0,
                location: GeoPoint(latitude: 59.3293, longitude: 18.0686)
            )
            media.append(item)
            let child = index % 4 == 0
            let labels = child ? ["child", "people", "outdoor"] : ["landscape", "sky", "tree"]
            if item.kind == .video {
                analyses[item.id] = MediaAnalysis(
                    mediaID: item.id,
                    segments: (0..<40).map { SegmentAnalysis(start: Double($0) * 0.5, duration: 0.5, metrics: FrameMetrics(faceCount: child ? 1 : 0)) },
                    labels: labels
                )
            } else {
                analyses[item.id] = MediaAnalysis(mediaID: item.id, still: FrameMetrics(faceCount: child ? 2 : 0), labels: labels)
            }
        }
        return (media, analyses)
    }

    @Test func descriptionsAreCompactTextInChronologicalOrder() {
        let (media, analyses) = Self.material()
        let descriptions = DirectorBriefing.describe(media.reversed(), analyses: analyses, timeZone: TimeZone(identifier: "UTC")!)
        #expect(descriptions.count == 40)
        #expect(descriptions.map(\.mediaID) == media.map(\.id))
        let first = descriptions[0].line
        #expect(first.hasPrefix("c1 | "))
        #expect(first.contains("video 20 s"))
        #expect(first.contains("59.33N 18.07E"))
        #expect(first.contains("faces 1"))
        #expect(first.contains("child, people, outdoor"))
        #expect(descriptions[1].line.contains("photo"))
        #expect(descriptions.allSatisfy { $0.line.count < 160 })
    }

    @Test func batchesFitTheBudgetAndKeepTheOrder() {
        let (media, analyses) = Self.material()
        let descriptions = DirectorBriefing.describe(media, analyses: analyses)
        let budget = 200
        let batches = DirectorBriefing.batches(descriptions, budget: budget, cost: DirectorBriefing.estimatedTokens)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 } == descriptions)
        for batch in batches {
            let cost = batch.reduce(0) { $0 + DirectorBriefing.estimatedTokens($1.line) + 1 }
            #expect(cost <= budget || batch.count == 1)
        }
    }

    @Test func answersAreValidatedAndMerged() {
        let (media, analyses) = Self.material()
        let descriptions = DirectorBriefing.describe(media, analyses: analyses)
        let answers = [
            DirectorAnswer(
                clipIDs: ["c9", "c1", "C5", "c999", "c1"],
                chapters: [DirectorAnswer.Chapter(title: " Morgon ", clipIDs: ["c5", "c13"])],
                style: "calm", title: "  Sommar med barnen  "
            ),
            DirectorAnswer(clipIDs: ["c21", "c17"], style: "Energetic"),
            DirectorAnswer(clipIDs: ["c25"], style: "calm"),
        ]
        let plan = DirectorBriefing.plan(from: answers, descriptions: descriptions)!
        // Chapters first, then the batch's other picks; unknown and repeated ids dropped.
        #expect(plan.mediaIDs == ["p4", "p12", "p8", "p0", "p20", "p16", "p24"])
        #expect(plan.chapters == [DirectorChapter(title: "Morgon", mediaIDs: ["p4", "p12"])])
        #expect(plan.suggestedStyle == .calm)
        #expect(plan.title == "Sommar med barnen")
        #expect(DirectorBriefing.plan(from: [DirectorAnswer(clipIDs: ["x", "c0"])], descriptions: descriptions) == nil)
    }

    /// Phase 5 acceptance in logic form: when the director picks the clips with children, the
    /// film consists mostly of them, at full length, even though most material has no children.
    @Test func aChildrenOnlyPlanGivesAFilmMostlyOfChildren() {
        let (media, analyses) = Self.material()
        let descriptions = DirectorBriefing.describe(media, analyses: analyses)
        let childIDs = descriptions.filter { $0.line.contains("child") }.map(\.shortID)
        let plan = DirectorBriefing.plan(from: [DirectorAnswer(clipIDs: childIDs, style: "calm")], descriptions: descriptions)!
        var request = Fixtures.request(media: media, target: 30, style: .calm)
        request.analyses = analyses
        request.director = plan
        let edl = Planner.plan(request)
        #expect(abs(edl.duration - 30) <= Timing.lengthTolerance)
        let children = Set(plan.mediaIDs)
        let share = Double(edl.clips.filter { children.contains($0.mediaID) }.count) / Double(edl.clips.count)
        #expect(share > 0.8, "share of clips with children: \(share)")
    }

    @Test func directorOrderWinsOverChronology() {
        let (media, analyses) = Self.material()
        let plan = DirectorPlan(mediaIDs: ["p36", "p0", "p12"])
        var request = Fixtures.request(media: media, target: 15, style: .travel)
        request.analyses = analyses
        request.director = plan
        let used = Planner.plan(request).clips.map(\.mediaID)
        let firstUses = used.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        #expect(Array(firstUses.prefix(3)) == ["p36", "p0", "p12"])
    }
}
