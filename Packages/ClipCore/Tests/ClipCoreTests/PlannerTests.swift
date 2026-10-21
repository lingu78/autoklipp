import Foundation
import Testing

@testable import ClipCore

@Suite("Planner – length and budget")
struct PlannerLengthTests {
    /// Phase 1 acceptance in logic form: 20 mixed clips, one minute, ±1 s.
    @Test func twentyMixedClipsMakeOneMinute() {
        let media = Fixtures.mixedMedia(photos: 10, videoDurations: [3, 4, 5, 6, 7, 8, 9, 10, 12, 15])
        let edl = Planner.plan(Fixtures.request(media: media, target: 60))
        expectWellFormed(edl, media: media)
        #expect(abs(edl.duration - 60) <= Timing.lengthTolerance)
        #expect(edl.notices.isEmpty)
        // Every source contributes.
        #expect(Set(edl.clips.map(\.mediaID)) == Set(media.map(\.id)))
    }

    @Test(arguments: [15.0, 30, 60, 180, 300, 600])
    func hitsEveryPresetLength(target: Double) {
        let media = Fixtures.mixedMedia(photos: 60, videoDurations: Array(repeating: 45, count: 25))
        let edl = Planner.plan(Fixtures.request(media: media, target: target))
        expectWellFormed(edl, media: media)
        #expect(abs(edl.duration - target) <= Timing.lengthTolerance, "got \(edl.duration) for \(target)")
    }

    @Test(arguments: StyleID.allCases)
    func everyStyleHitsTheLength(style: StyleID) {
        let media = Fixtures.mixedMedia(photos: 15, videoDurations: [20, 30, 40, 25, 12])
        for bpm in [72.0, 96, 120, 138] {
            let edl = Planner.plan(Fixtures.request(media: media, target: 75, style: style, bpm: bpm))
            expectWellFormed(edl, media: media)
            #expect(abs(edl.duration - 75) <= Timing.lengthTolerance, "\(style) at \(bpm) BPM: \(edl.duration)")
        }
    }

    @Test func oddTargetsAndTemposStillLandWithinASecond() {
        let media = Fixtures.mixedMedia(photos: 12, videoDurations: [33, 18, 41, 9, 27, 60])
        var rng = SeededGenerator(seed: 99)
        // The material allows 236 s; stay clear of that so every run has enough.
        for _ in 0..<40 {
            let target = (rng.nextDouble(in: 15...180) * 10).rounded() / 10
            let bpm = rng.nextDouble(in: 62...174)
            let style = StyleID.allCases[Int(rng.next() % UInt64(StyleID.allCases.count))]
            let edl = Planner.plan(Fixtures.request(media: media, target: target, style: style, bpm: bpm, seed: rng.next()))
            expectWellFormed(edl, media: media)
            #expect(abs(edl.duration - target) <= Timing.lengthTolerance, "target \(target), \(bpm) BPM, \(style): \(edl.duration)")
        }
    }

    @Test func stillsStayBetweenOneAndAHalfAndFourSeconds() {
        let media = Fixtures.mixedMedia(photos: 30, videoDurations: [10, 20])
        for style in StyleID.allCases {
            let edl = Planner.plan(Fixtures.request(media: media, target: 60, style: style))
            // The last clip too, although it is cut to end the film.
            for clip in edl.clips where clip.kind.isStill {
                #expect(Timing.stillRange.contains(clip.duration), "\(style): still shown \(clip.duration) s")
            }
        }
    }

    @Test func theLastClipIsNotCutBelowItsMinimum() {
        // 8 stills of four beats end just short of 15 s; a ninth would be cut to under half a second.
        let photos = Fixtures.mixedMedia(photos: 20, videoDurations: [])
        let edl = Planner.plan(Fixtures.request(media: photos, target: 15, style: .energetic, bpm: 132))
        #expect(abs(edl.duration - 15) <= Timing.lengthTolerance)
        #expect(Timing.stillRange.contains(edl.clips.last!.duration), "last still shown \(edl.clips.last!.duration) s")

        let mixed = Fixtures.mixedMedia(photos: 12, videoDurations: [20, 25, 30, 15, 40])
        for style in StyleID.allCases {
            for bpm in [72.0, 96, 104, 120, 128, 132, 138] {
                for target in [15.0, 30, 45, 60] {
                    for media in [photos, mixed] {
                        let edl = Planner.plan(Fixtures.request(media: media, target: target, style: style, bpm: bpm))
                        expectWellFormed(edl, media: media)
                        #expect(abs(edl.duration - target) <= Timing.lengthTolerance)
                        let last = edl.clips.last!
                        if last.kind.isStill {
                            #expect(Timing.stillRange.contains(last.duration), "\(style) \(bpm) BPM \(target) s: last still \(last.duration) s")
                        } else {
                            #expect(last.duration >= Timing.minVideoClip - 1e-6, "\(style) \(bpm) BPM \(target) s: last video \(last.duration) s")
                        }
                    }
                }
            }
        }

        // Every clip before the last still is at its longest, so the cut before it cannot move
        // later; the film ends when the still has been shown for 4 s instead.
        let tight = Fixtures.mixedMedia(photos: 3, videoDurations: [18])
        let film = Planner.plan(Fixtures.request(media: tight, target: 29, style: .calm, bpm: 92))
        expectWellFormed(film, media: tight)
        #expect(abs(film.duration - 29) <= Timing.lengthTolerance, "\(film.duration)")
        #expect(film.notices.isEmpty)
        #expect(film.clips.last!.kind.isStill)
        #expect(Timing.stillRange.contains(film.clips.last!.duration), "last still shown \(film.clips.last!.duration) s")
    }

    @Test func theLastVideoIsNotStretchedToTheEnd() {
        // The last clip comes from the end of a video and ends a fraction of a beat before the
        // target; filling that fraction would slow it down and mute it. In the last three every
        // clip before it is already at its longest, so the film ends when its footage does.
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: [25.5, 28.6])
        let cases: [(style: StyleID, bpm: Double, target: Double)] = [
            (.energetic, 76, 38), (.energetic, 76, 43), (.energetic, 90, 43), (.energetic, 104, 43),
            (.energetic, 132, 32), (.nostalgic, 90, 43), (.nostalgic, 132, 49),
            (.energetic, 86, 47), (.energetic, 72, 46), (.energetic, 104, 50),
        ]
        for setup in cases {
            var request = Fixtures.request(media: media, target: setup.target, style: setup.style, bpm: setup.bpm)
            request.originalAudio = true
            let edl = Planner.plan(request)
            let context = "\(setup.style) \(setup.bpm) BPM \(setup.target) s"
            expectWellFormed(edl, media: media)
            #expect(abs(edl.duration - setup.target) <= Timing.lengthTolerance, "\(context): \(edl.duration)")
            #expect(edl.notices.isEmpty, "\(context)")
            let last = edl.clips.last!
            #expect(last.duration >= Timing.minVideoClip - 1e-6, "\(context): last video \(last.duration) s")
            #expect(last.playbackRate > 0.95, "\(context): last video plays at \(last.playbackRate)")
            #expect(last.audioVolume > 0, "\(context)")
        }
    }

    @Test func leftoverFootageIsNotTakenFromNeighbours() {
        // Material runs short: the planner must not squeeze extra moments between clips that
        // already play that footage, which would slow them down and mute them.
        let media = Fixtures.mixedMedia(photos: 3, videoDurations: [18])
        for seed in UInt64(0)..<40 {
            var request = Fixtures.request(media: media, target: 30, style: .travel, bpm: 72, seed: seed)
            request.originalAudio = true
            let edl = Planner.plan(request)
            expectWellFormed(edl, media: media)
            for clip in edl.clips where clip.kind == .video {
                #expect(clip.playbackRate > 0.99, "seed \(seed): \(clip.id) plays at \(clip.playbackRate)")
                #expect(clip.audioVolume > 0)
            }
            // The video is still used for the most part.
            let footage = edl.clips.filter { $0.kind == .video }.reduce(0) { $0 + $1.sourceDuration }
            #expect(footage >= 0.8 * 18, "seed \(seed): \(footage) s of the video used")
            #expect(edl.notices.contains { if case .materialShorterThanTarget = $0 { true } else { false } })
        }
    }

    @Test func maximumDurationCountsWholeBeatsPerStill() {
        let photos = Fixtures.mixedMedia(photos: 10, videoDurations: [])
        #expect(Planner.maximumDuration(of: photos) == 40)
        let period = 60.0 / 104
        let maximum = Planner.maximumDuration(of: photos, beatPeriod: period)
        // At 104 BPM a still lasts at most six beats.
        #expect(abs(maximum - 10 * 6 * period) < 1e-9)
        let edl = Planner.plan(Fixtures.request(media: photos, target: maximum.rounded(.down), bpm: 104))
        #expect(abs(edl.duration - maximum.rounded(.down)) <= Timing.lengthTolerance)
    }

    @Test func energeticAt120BPMCutsAboutOncePerSecond() {
        // Spec example: 120 BPM, two beats per clip -> ~1 s clips, ~180 clips for three minutes.
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: Array(repeating: 60, count: 8))
        let edl = Planner.plan(Fixtures.request(media: media, target: 180, style: .energetic, bpm: 120))
        expectWellFormed(edl, media: media)
        #expect((150...210).contains(edl.clips.count), "got \(edl.clips.count) clips")
    }

    @Test func calmUsesFourToEightBeats() {
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: Array(repeating: 60, count: 6))
        let edl = Planner.plan(Fixtures.request(media: media, target: 120, style: .calm, bpm: 90))
        for clip in edl.clips.dropLast() {
            #expect((4...8).contains(clip.beats), "calm clip spans \(clip.beats) beats")
        }
    }

    @Test func shortMaterialGivesShorterFilmAndNoticeWithoutRepeats() {
        let media = Fixtures.mixedMedia(photos: 3, videoDurations: [4])
        let edl = Planner.plan(Fixtures.request(media: media, target: 60))
        expectWellFormed(edl, media: media)
        #expect(edl.duration < 60 - Timing.lengthTolerance)
        #expect(edl.notices.contains { if case .materialShorterThanTarget = $0 { true } else { false } })
        // Stills are stretched to the maximum and the video is used in full, never repeated.
        #expect(edl.clips.filter { $0.kind.isStill }.count == 3)
        #expect(edl.clips.allSatisfy { !$0.kind.isStill || $0.duration <= Timing.stillRange.upperBound + 1e-6 })
        let videoFootage = edl.clips.filter { $0.kind == .video }.reduce(0) { $0 + $1.sourceDuration }
        #expect(videoFootage > 3.5)
        #expect(edl.duration > 3 * 3.5 + 3.5)
    }

    @Test func noMediaGivesEmptyListWithNotice() {
        let edl = Planner.plan(Fixtures.request(media: [], target: 30))
        #expect(edl.clips.isEmpty)
        #expect(edl.duration == 0)
        #expect(!edl.notices.isEmpty)
    }

    @Test func singleLongVideoIsSpreadAcrossItsLength() {
        let media = [MediaItem(id: "long", kind: .video, creationDate: Fixtures.baseDate, duration: 300)]
        let edl = Planner.plan(Fixtures.request(media: media, target: 60, style: .travel))
        expectWellFormed(edl, media: media)
        #expect(abs(edl.duration - 60) <= Timing.lengthTolerance)
        let starts = edl.clips.map(\.sourceStart)
        #expect(starts.min()! < 30)
        #expect(starts.max()! > 250)
    }
}

@Suite("Planner – beats")
struct PlannerBeatTests {
    @Test func cutsLandOnBeats() {
        let media = Fixtures.mixedMedia(photos: 10, videoDurations: [8, 9, 10, 20, 30])
        let edl = Planner.plan(Fixtures.request(media: media, target: 60, bpm: 120))
        // At 120 BPM every cut is on a multiple of 0.5 s.
        for clip in edl.clips {
            let beats = clip.timelineStart / 0.5
            #expect(abs(beats - beats.rounded()) < 1e-6, "cut at \(clip.timelineStart) is off the beat")
        }
    }

    @Test func cutsFollowAnIrregularBeatGridWithinOneFrame() {
        // A drifting tempo: each beat 1 % longer than the previous one.
        var beats: [Double] = [0]
        var period = 0.45
        while beats.last! < 200 {
            beats.append(beats.last! + period)
            period *= 1.002
        }
        let track = TrackInfo(id: "drift", duration: 200, bpm: 120, beats: beats)
        let media = Fixtures.mixedMedia(photos: 8, videoDurations: [20, 25, 30, 35])
        let layout = MusicLayout.make(track: track, filmDuration: 90)
        let request = PlanningRequest(media: media, targetDuration: 90, style: .preset(.travel), music: layout, seed: 3)
        let edl = Planner.plan(request)
        expectWellFormed(edl, media: media)
        for clip in edl.clips.dropFirst() {
            let nearest = layout.beats.min { abs($0 - clip.timelineStart) < abs($1 - clip.timelineStart) }!
            #expect(abs(nearest - clip.timelineStart) <= 0.5 / 30 + 1e-9, "cut \(clip.timelineStart) vs beat \(nearest)")
        }
    }

    @Test func longFilmsAlternateDensity() {
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: Array(repeating: 90, count: 10))
        let edl = Planner.plan(Fixtures.request(media: media, target: 360, style: .cinematic, bpm: 100))
        expectWellFormed(edl, media: media)
        let lengths = Set(edl.clips.dropLast().map(\.beats))
        #expect(lengths.count >= 3, "expected varying clip lengths, got \(lengths.sorted())")
    }

    @Test func densityFollowsSongSections() {
        let track = TrackInfo(
            id: "song", duration: 400, bpm: 120,
            beats: (0..<800).map { Double($0) * 0.5 },
            sections: [
                MusicSection(start: 0, end: 100, energy: 0),
                MusicSection(start: 100, end: 200, energy: 1),
                MusicSection(start: 200, end: 400, energy: 0),
            ]
        )
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: Array(repeating: 120, count: 8))
        let request = PlanningRequest(
            media: media, targetDuration: 300, style: .preset(.cinematic),
            music: MusicLayout.make(track: track, filmDuration: 300), seed: 5
        )
        let edl = Planner.plan(request)
        func averageLength(_ range: Range<Double>) -> Double {
            let clips = edl.clips.filter { range.contains($0.timelineStart) }
            return clips.reduce(0) { $0 + $1.duration } / Double(max(1, clips.count))
        }
        #expect(averageLength(110..<190) < averageLength(10..<90), "chorus should cut faster than verse")
    }
}

@Suite("Planner – order, locks and variation")
struct PlannerOrderTests {
    @Test func chronologicalByDefault() {
        let media = Fixtures.mixedMedia(photos: 10, videoDurations: [5, 6, 7, 8, 9])
        let edl = Planner.plan(Fixtures.request(media: media, target: 45))
        let dates = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.creationDate!) })
        let clipDates = edl.clips.map { dates[$0.mediaID]! }
        #expect(clipDates == clipDates.sorted())
    }

    @Test func undatedMediaGoLastInPickedOrder() {
        let media = [
            MediaItem(id: "b", kind: .photo),
            MediaItem(id: "late", kind: .photo, creationDate: Fixtures.baseDate.addingTimeInterval(100)),
            MediaItem(id: "a", kind: .photo),
            MediaItem(id: "early", kind: .photo, creationDate: Fixtures.baseDate),
        ]
        #expect(media.chronological().map(\.id) == ["early", "late", "b", "a"])
    }

    @Test func sameSeedSameEditDifferentSeedNewVersion() {
        let media = Fixtures.mixedMedia(photos: 40, videoDurations: Array(repeating: 30, count: 10))
        let first = Planner.plan(Fixtures.request(media: media, target: 60, seed: 11))
        let again = Planner.plan(Fixtures.request(media: media, target: 60, seed: 11))
        let other = Planner.plan(Fixtures.request(media: media, target: 60, seed: 12))
        #expect(first == again)
        #expect(first.clips.map(\.id) != other.clips.map(\.id))
        #expect(abs(other.duration - 60) <= Timing.lengthTolerance)
    }

    @Test func manySourcesAreSampledAcrossTheWholeEvent() {
        let media = Fixtures.mixedMedia(photos: 200, videoDurations: [])
        let edl = Planner.plan(Fixtures.request(media: media, target: 30))
        let order = media.chronological().map(\.id)
        let positions = edl.clips.map { order.firstIndex(of: $0.mediaID)! }
        #expect(positions.min()! < 30)
        #expect(positions.max()! > 170)
        #expect(abs(edl.duration - 30) <= Timing.lengthTolerance)
    }

    @Test func lockedClipsAreAlwaysKept() {
        let media = Fixtures.mixedMedia(photos: 100, videoDurations: Array(repeating: 20, count: 10))
        let first = Planner.plan(Fixtures.request(media: media, target: 30, seed: 1))
        var locked = first.clips[first.clips.count / 2]
        locked.isLocked = true
        var request = Fixtures.request(media: media, target: 30, seed: 2)
        request.lockedClips = [locked]
        let second = Planner.plan(request)
        let kept = second.clips.first { $0.id == locked.id }
        #expect(kept != nil)
        #expect(kept?.isLocked == true)
        #expect(abs(second.duration - 30) <= Timing.lengthTolerance)
    }

    @Test func lockedClipsSurviveEvenWhenMaterialIsAbundant() {
        let media = Fixtures.mixedMedia(photos: 200, videoDurations: [])
        let lockedIDs = ["photo-3", "photo-77", "photo-150", "photo-199"]
        var request = Fixtures.request(media: media, target: 15)
        request.lockedClips = lockedIDs.map {
            EDLClip(id: EDLClip.makeID(mediaID: $0, sourceStart: 0), mediaID: $0, kind: .photo, sourceStart: 0,
                    sourceDuration: 2, timelineStart: 0, duration: 2, beats: 4, isLocked: true)
        }
        let edl = Planner.plan(request)
        #expect(Set(lockedIDs).isSubset(of: Set(edl.clips.map(\.mediaID))))
        #expect(abs(edl.duration - 15) <= Timing.lengthTolerance)
    }

    @Test func lockedClipsAreKeptWhenTheyDoNotFitTheLength() {
        let media = Fixtures.mixedMedia(photos: 30, videoDurations: [])
        let first = Planner.plan(Fixtures.request(media: media, target: 60))
        let locked = first.clips.prefix(12).map { clip -> EDLClip in
            var clip = clip
            clip.isLocked = true
            return clip
        }
        // Twelve stills need at least 18 s, more than the 15 s asked for.
        var request = Fixtures.request(media: media, target: 15, seed: 3)
        request.lockedClips = locked
        let edl = Planner.plan(request)
        expectWellFormed(edl, media: media)
        #expect(Set(locked.map(\.id)).isSubset(of: Set(edl.clips.map(\.id))))
        #expect(edl.clips.allSatisfy { Timing.stillRange.contains($0.duration) })
        #expect(edl.duration > 15)
    }

    @Test func excludedMediaAndRangesNeverAppear() {
        let media = Fixtures.mixedMedia(photos: 10, videoDurations: [30, 30])
        var request = Fixtures.request(media: media, target: 40)
        request.exclusions = [Exclusion(mediaID: "photo-2"), Exclusion(mediaID: "video-0", start: 0, end: 20)]
        let edl = Planner.plan(request)
        expectWellFormed(edl, media: media)
        #expect(!edl.clips.contains { $0.mediaID == "photo-2" })
        for clip in edl.clips where clip.mediaID == "video-0" {
            #expect(clip.sourceStart >= 20 - 1e-6, "clip from removed range at \(clip.sourceStart)")
        }
    }

    @Test func directorOrderAndChoiceAreRespected() {
        let media = Fixtures.mixedMedia(photos: 20, videoDurations: [])
        var request = Fixtures.request(media: media, target: 15)
        let chosen = ["photo-9", "photo-2", "photo-15", "photo-4", "photo-11", "photo-0"]
        request.director = DirectorPlan(mediaIDs: chosen)
        let edl = Planner.plan(request)
        let used = edl.clips.map(\.mediaID)
        #expect(used.allSatisfy { chosen.contains($0) })
        #expect(used == chosen.filter { used.contains($0) })
    }

    @Test func directorChoiceIsTopUpWhenTooShort() {
        let media = Fixtures.mixedMedia(photos: 20, videoDurations: [])
        var request = Fixtures.request(media: media, target: 30)
        request.director = DirectorPlan(mediaIDs: ["photo-1", "photo-2"])
        let edl = Planner.plan(request)
        #expect(abs(edl.duration - 30) <= Timing.lengthTolerance)
        #expect(Array(edl.clips.map(\.mediaID).prefix(2)) == ["photo-1", "photo-2"])
    }
}

@Suite("Planner – transitions and Ken Burns")
struct PlannerLookTests {
    @Test func calmCrossfadesAndEnergeticMostlyCuts() {
        let media = Fixtures.mixedMedia(photos: 20, videoDurations: Array(repeating: 30, count: 6))
        let calm = Planner.plan(Fixtures.request(media: media, target: 60, style: .calm, bpm: 80))
        #expect(calm.clips.dropFirst().allSatisfy { $0.transitionIn.kind == .crossfade })
        let energetic = Planner.plan(Fixtures.request(media: media, target: 60, style: .energetic, bpm: 128))
        let cuts = energetic.clips.dropFirst().filter { $0.transitionIn.kind == .cut }.count
        #expect(Double(cuts) / Double(energetic.clips.count - 1) > 0.5)
    }

    @Test func transitionsFitInsideTheirNeighbours() {
        let media = Fixtures.mixedMedia(photos: 20, videoDurations: Array(repeating: 30, count: 6))
        for style in StyleID.allCases {
            let edl = Planner.plan(Fixtures.request(media: media, target: 60, style: style))
            for (previous, clip) in zip(edl.clips, edl.clips.dropFirst()) {
                #expect(clip.transitionIn.duration <= 0.45 * min(previous.duration, clip.duration) + 1e-6)
            }
            #expect(edl.clips.first?.transitionIn == .cut)
        }
    }

    @Test func stillsGetKenBurnsVideosDoNot() {
        let media = Fixtures.mixedMedia(photos: 10, videoDurations: [10, 10])
        let edl = Planner.plan(Fixtures.request(media: media, target: 30))
        for clip in edl.clips {
            #expect((clip.kenBurns != nil) == clip.kind.isStill)
            if let move = clip.kenBurns {
                #expect(move.startScale >= 1 && move.endScale >= 1)
                #expect(move.startScale != move.endScale || move.startCenter != move.endCenter)
            }
        }
    }

    @Test func kenBurnsAimsAtFaces() {
        let photo = MediaItem(id: "face", kind: .photo, creationDate: Fixtures.baseDate)
        let analysis = MediaAnalysis(
            mediaID: "face", still: FrameMetrics(faceCount: 1, faceQuality: 0.8),
            faceRegions: [NormalizedRect(x: 0.65, y: 0.2, width: 0.1, height: 0.1)]
        )
        var request = Fixtures.request(media: [photo], target: 15)
        request.analyses = ["face": analysis]
        let edl = Planner.plan(request)
        let move = edl.clips[0].kenBurns!
        let focus = move.startScale > move.endScale ? move.startCenter : move.endCenter
        #expect(focus.x > 0.55)
        #expect(focus.y < 0.45)
    }
}

@Suite("Clip list format")
struct EditDecisionListTests {
    @Test func jsonRoundTrip() throws {
        let media = Fixtures.mixedMedia(photos: 5, videoDurations: [12])
        var request = Fixtures.request(media: media, target: 20)
        request.title = "Sommar 2026"
        request.endCredit = "Slut"
        let edl = Planner.plan(request)
        let data = try edl.jsonData()
        let decoded = try EditDecisionList.decode(from: data)
        #expect(decoded == edl)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"sourceStart\""))
        #expect(text.contains("\"transitionIn\""))
        #expect(decoded.title?.text == "Sommar 2026")
    }
}
