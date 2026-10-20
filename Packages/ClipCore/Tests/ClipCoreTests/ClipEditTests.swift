import Foundation
import Testing

@testable import ClipCore

@Suite("Clip strip edits")
struct ClipEditTests {
    static let media = Fixtures.mixedMedia(photos: 12, videoDurations: [20, 25, 30, 15, 40])

    func start() -> (EditDecisionList, PlanningRequest) {
        let request = Fixtures.request(media: Self.media, target: 45, style: .travel, seed: 5)
        return (Planner.plan(request), request)
    }

    @Test func movingKeepsTheNewOrderTheLengthAndTheBeat() {
        let (edl, request) = start()
        let moved = edl.clips[1]
        let (result, _) = Planner.apply(.move(clipID: moved.id, toIndex: 6), to: edl, request: request)
        expectWellFormed(result, media: Self.media)
        #expect(result.clips[6].id == moved.id)
        var expected = edl.clips.map(\.id)
        expected.remove(at: 1)
        expected.insert(moved.id, at: 6)
        #expect(Array(result.clips.map(\.id).prefix(expected.count)) == expected)
        #expect(abs(result.duration - 45) <= Timing.lengthTolerance)
        for clip in result.clips {
            let beats = clip.timelineStart / 0.5
            #expect(abs(beats - beats.rounded()) < 1e-6)
        }
    }

    @Test func removingFillsTheGapAndNeverBringsTheClipBack() {
        let (edl, request) = start()
        let removed = edl.clips.first { $0.kind == .video }!
        let (result, exclusions) = Planner.apply(.remove(clipID: removed.id), to: edl, request: request)
        expectWellFormed(result, media: Self.media)
        #expect(!result.clips.contains { $0.id == removed.id })
        #expect(abs(result.duration - 45) <= Timing.lengthTolerance)
        #expect(exclusions.count == 1)

        // A new version with the same exclusions avoids the removed footage.
        var again = request
        again.exclusions = exclusions
        again.seed = 99
        for clip in Planner.plan(again).clips where clip.mediaID == removed.mediaID {
            #expect(clip.sourceEnd <= removed.sourceStart + 1e-6 || clip.sourceStart >= removed.sourceEnd - 1e-6)
        }
    }

    @Test func removingAStillExcludesIt() {
        let (edl, request) = start()
        let removed = edl.clips.first { $0.kind.isStill }!
        let (result, exclusions) = Planner.apply(.remove(clipID: removed.id), to: edl, request: request)
        #expect(!result.clips.contains { $0.mediaID == removed.mediaID })
        #expect(exclusions == [Exclusion(mediaID: removed.mediaID)])
    }

    @Test func otherClipsKeepTheirIdentityAndLook() {
        let (edl, request) = start()
        let (result, _) = Planner.apply(.remove(clipID: edl.clips[3].id), to: edl, request: request)
        let before = Dictionary(uniqueKeysWithValues: edl.clips.map { ($0.id, $0) })
        let kept = result.clips.filter { before[$0.id] != nil }
        #expect(kept.count >= edl.clips.count - 1)
        for clip in kept where clip.kind.isStill {
            #expect(clip.kenBurns == before[clip.id]!.kenBurns)
        }
    }

    @Test func lockedClipsSurviveANewVersion() {
        let (edl, request) = start()
        let target = edl.clips[4]
        let (locked, _) = Planner.apply(.setLocked(clipID: target.id, true), to: edl, request: request)
        #expect(locked.clips[4].isLocked)
        #expect(locked.clips.map(\.timelineStart) == edl.clips.map(\.timelineStart))
        var again = request
        again.seed = 1234
        again.lockedClips = locked.clips.filter(\.isLocked)
        #expect(Planner.plan(again).clips.contains { $0.id == target.id && $0.isLocked })
    }

    @Test func manyEditsInARowStayOnLength() {
        var (edl, request) = start()
        var rng = SeededGenerator(seed: 8)
        for _ in 0..<25 {
            let clip = edl.clips[Int(rng.next() % UInt64(edl.clips.count))]
            let edit: ClipEdit = rng.nextUnit() < 0.5
                ? .move(clipID: clip.id, toIndex: Int(rng.next() % UInt64(edl.clips.count)))
                : .remove(clipID: clip.id)
            let result = Planner.apply(edit, to: edl, request: request)
            edl = result.edl
            request.exclusions = result.exclusions
            expectWellFormed(edl, media: Self.media)
            #expect(abs(edl.duration - 45) <= Timing.lengthTolerance || !edl.notices.isEmpty)
        }
    }
}
