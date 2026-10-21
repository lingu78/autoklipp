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

    /// Songs whose beats are not a whole number of frames, and one style that cuts fast.
    static let editSetups: [(media: [MediaItem], target: Double, style: StyleID, bpm: Double)] = [
        (media, 45, .travel, 104),
        (media, 60, .energetic, 128),
        (Fixtures.mixedMedia(photos: 0, videoDurations: [60, 60, 60, 60]), 60, .travel, 104),
        (Fixtures.mixedMedia(photos: 10, videoDurations: [3, 4, 5, 6, 7, 8, 9, 10, 12, 15]), 60, .travel, 104),
        (Fixtures.mixedMedia(photos: 10, videoDurations: [3, 4, 5, 6, 7, 8, 9, 10, 12, 15]), 60, .energetic, 96),
    ]

    @Test func removingAClipKeepsAllOthersAndLengthensThem() {
        for setup in Self.editSetups {
            let request = Fixtures.request(media: setup.media, target: setup.target, style: setup.style, bpm: setup.bpm, seed: 5)
            let edl = Planner.plan(request)
            for removed in edl.clips {
                let (result, _) = Planner.apply(.remove(clipID: removed.id), to: edl, request: request)
                let context = "\(setup.style) \(setup.bpm) BPM, removing \(removed.id)"
                expectWellFormed(result, media: setup.media)
                // Neighbours from the same video stay, and nothing new is needed while they can grow.
                #expect(result.clips.map(\.id) == edl.clips.map(\.id).filter { $0 != removed.id }, "\(context)")
                #expect(result.clips.reduce(0) { $0 + $1.beats } >= edl.clips.reduce(0) { $0 + $1.beats } - removed.beats, "\(context)")
                #expect(abs(result.duration - setup.target) <= Timing.lengthTolerance, "\(context): \(result.duration)")
                for clip in result.clips where clip.kind == .video && clip.mediaID == removed.mediaID {
                    #expect(clip.sourceEnd <= removed.sourceStart + 1e-6 || clip.sourceStart >= removed.sourceEnd - 1e-6,
                            "\(context): \(clip.id) plays removed footage")
                }
            }
        }
    }

    @Test func movingKeepsTheSameClips() {
        for setup in Self.editSetups {
            let request = Fixtures.request(media: setup.media, target: setup.target, style: setup.style, bpm: setup.bpm, seed: 5)
            let edl = Planner.plan(request)
            for (index, moved) in edl.clips.enumerated() {
                let destination = (index + 2) % edl.clips.count
                let (result, _) = Planner.apply(.move(clipID: moved.id, toIndex: destination), to: edl, request: request)
                var expected = edl.clips.map(\.id)
                expected.remove(at: index)
                expected.insert(moved.id, at: min(destination, expected.count))
                expectWellFormed(result, media: setup.media)
                #expect(result.clips.map(\.id) == expected, "\(setup.style) \(setup.bpm) BPM, moving \(moved.id) to \(destination)")
                #expect(abs(result.duration - setup.target) <= Timing.lengthTolerance)
                // Only lengths change, and never into slow motion.
                #expect(result.clips.allSatisfy { $0.playbackRate > 0.95 })
            }
        }
    }

    @Test func anotherSongReTimesTheArrangement() {
        let request = Fixtures.request(media: Self.media, target: 45, style: .travel, bpm: 104, seed: 5)
        let edl = Planner.plan(request)
        let (moved, _) = Planner.apply(.move(clipID: edl.clips[0].id, toIndex: 5), to: edl, request: request)
        var resung = Fixtures.request(media: Self.media, target: 45, style: .travel, bpm: 128, seed: 5)
        resung.arrangement = moved.clips
        let result = Planner.plan(resung)
        expectWellFormed(result, media: Self.media)
        #expect(abs(result.duration - 45) <= Timing.lengthTolerance)
        let kept = result.clips.map(\.id).filter(Set(moved.clips.map(\.id)).contains)
        #expect(kept == moved.clips.map(\.id).filter(Set(kept).contains))
        #expect(kept.count >= moved.clips.count - 2)
        // The clips follow the new song's beat and the style's lengths for it.
        let period = 60.0 / 128
        for clip in result.clips {
            let beats = clip.timelineStart / period
            #expect(abs(beats - beats.rounded()) * period <= 0.5 / 30 + 1e-6)
        }
        #expect(result.clips.dropLast().allSatisfy { $0.duration >= ($0.kind.isStill ? 1.5 : 0.9) })
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
