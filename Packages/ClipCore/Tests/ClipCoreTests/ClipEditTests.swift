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

    @Test func aMovedLastClipKeepsItsSpeedAndSound() {
        // The last clip was cut to 0.5 s at the end of its video, and a clip needs two beats
        // (0.97 s) at 124 BPM. Moved into the film it starts a little earlier in its video
        // instead of playing slowed down and muted, and so it does when a clip is moved behind it.
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: [60, 60, 60, 60])
        var request = Fixtures.request(media: media, target: 45, style: .energetic, bpm: 124)
        request.originalAudio = true
        let edl = Planner.plan(request)
        #expect(edl.clips.last!.duration < 0.9)
        let edits: [ClipEdit] = [.move(clipID: edl.clips.last!.id, toIndex: 0), .move(clipID: edl.clips[0].id, toIndex: edl.clips.count)]
        for edit in edits {
            let (result, _) = Planner.apply(edit, to: edl, request: request)
            expectWellFormed(result, media: media)
            #expect(Set(result.clips.map(\.id)) == Set(edl.clips.map(\.id)), "\(edit)")
            #expect(abs(result.duration - 45) <= Timing.lengthTolerance)
            for clip in result.clips {
                #expect(clip.playbackRate > 0.95, "\(edit): \(clip.id) plays at \(clip.playbackRate)")
                #expect(clip.audioVolume > 0, "\(edit): \(clip.id) is muted")
            }
        }
    }

    @Test func movingKeepsTheSameClipsWhenNothingCanGive() {
        // Tight cases: the last clip had fewer beats of footage left than it spanned, or every clip
        // is at its shortest. A move still keeps every clip, with no new ones; at most the film
        // ends a little after the target so that the last clip is not cut to a flash.
        let setups: [(media: [MediaItem], target: Double, bpm: Double)] = [
            (Fixtures.mixedMedia(photos: 0, videoDurations: [60, 60, 60, 60]), 38, 104),
            (Fixtures.mixedMedia(photos: 0, videoDurations: [25.5, 28.6]), 27, 104),
            (Self.media, 27, 90),
            (Self.media, 45, 86),
        ]
        for setup in setups {
            let request = Fixtures.request(media: setup.media, target: setup.target, style: .energetic, bpm: setup.bpm)
            let edl = Planner.plan(request)
            for (index, moved) in edl.clips.enumerated() {
                for destination in [0, edl.clips.count] where destination != index {
                    let (result, _) = Planner.apply(.move(clipID: moved.id, toIndex: destination), to: edl, request: request)
                    var expected = edl.clips.map(\.id)
                    expected.remove(at: index)
                    expected.insert(moved.id, at: min(destination, expected.count))
                    let context = "\(setup.bpm) BPM \(setup.target) s, moving \(moved.id) to \(destination)"
                    expectWellFormed(result, media: setup.media)
                    #expect(result.clips.map(\.id) == expected, "\(context)")
                    #expect(abs(result.duration - setup.target) <= Timing.lengthTolerance, "\(context): \(result.duration)")
                    #expect(result.notices.isEmpty, "\(context)")
                    let last = result.clips.last!
                    let shortest = last.kind.isStill ? Timing.stillRange.lowerBound : Timing.minVideoClip
                    #expect(last.duration >= shortest - 1e-6, "\(context): last clip \(last.duration) s")
                }
            }
        }
    }

    @Test func theLastClipKeepsItsMinimumAfterARemoval() {
        // Both videos are used almost to their ends, so after a removal the last clip can have
        // less footage than the beats it spans. It is still never cut below half a second.
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: [25.5, 28.6])
        for (target, bpm) in [(27.0, 104.0), (15, 132)] {
            let request = Fixtures.request(media: media, target: target, style: .energetic, bpm: bpm)
            let edl = Planner.plan(request)
            for removed in edl.clips {
                let (result, _) = Planner.apply(.remove(clipID: removed.id), to: edl, request: request)
                let context = "\(bpm) BPM \(target) s, removing \(removed.id)"
                expectWellFormed(result, media: media)
                #expect(abs(result.duration - target) <= Timing.lengthTolerance, "\(context): \(result.duration)")
                #expect(result.clips.last!.duration >= Timing.minVideoClip - 1e-6, "\(context): last clip \(result.clips.last!.duration) s")
            }
        }
    }

    @Test func newClipsKeepTheUsersOrder() {
        // Calm clips cannot grow enough to make up for a removed one, so new moments come in.
        // The user moved the last clip to the front; new moments join a clip next to them in
        // time instead of pushing it from its place.
        let request = Fixtures.request(media: Self.media, target: 30, style: .calm, bpm: 112, seed: 3)
        let edl = Planner.plan(request)
        let (moved, _) = Planner.apply(.move(clipID: edl.clips.last!.id, toIndex: 0), to: edl, request: request)
        var added = 0
        for removed in moved.clips.dropFirst() {
            let (result, _) = Planner.apply(.remove(clipID: removed.id), to: moved, request: request)
            let kept = moved.clips.map(\.id).filter { $0 != removed.id }
            let ids = result.clips.map(\.id)
            expectWellFormed(result, media: Self.media)
            #expect(abs(result.duration - 30) <= Timing.lengthTolerance)
            #expect(ids.filter(Set(kept).contains) == kept, "removing \(removed.id): \(ids)")
            #expect(ids.first == kept.first, "removing \(removed.id): \(ids)")
            added += ids.filter { !kept.contains($0) }.count
        }
        #expect(added > 0)
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
