import Foundation
import Testing

@testable import ClipCore

@Suite("Scorer")
struct ScorerTests {
    @Test func blurIsPunished() {
        let sharp = Scorer.score(FrameMetrics(sharpness: 0.8))
        let blurry = Scorer.score(FrameMetrics(sharpness: 0.1))
        #expect(blurry < sharp * 0.5)
    }

    @Test func shakeIsPunished() {
        let steady = Scorer.score(FrameMetrics(shake: 0.05))
        let shaky = Scorer.score(FrameMetrics(shake: 0.9))
        #expect(shaky < steady * 0.5)
    }

    @Test func facesArePreferred() {
        let empty = Scorer.score(FrameMetrics())
        let face = Scorer.score(FrameMetrics(faceCount: 1, faceQuality: 0.7))
        #expect(face > empty + 0.1)
        #expect(Scorer.stillScore(FrameMetrics(faceCount: 2, faceQuality: 0.5)) > Scorer.stillScore(FrameMetrics()))
    }

    @Test func someMotionBeatsNoneAndFranticMotion() {
        let still = Scorer.score(FrameMetrics(motion: 0))
        let lively = Scorer.score(FrameMetrics(motion: 0.3))
        let frantic = Scorer.score(FrameMetrics(motion: 1))
        #expect(lively > still)
        #expect(lively > frantic)
    }

    @Test func darkAndBlownOutFramesLose() {
        let good = Scorer.score(FrameMetrics(exposure: 0.5))
        #expect(Scorer.score(FrameMetrics(exposure: 0.02)) < good * 0.6)
        #expect(Scorer.score(FrameMetrics(exposure: 0.99)) < good * 0.6)
    }

    @Test func scoresStayInRangeForGarbage() {
        let weird = FrameMetrics(
            sharpness: .nan, faceCount: 50, faceQuality: 7, motion: -3, shake: .infinity, exposure: 2, audioLevel: -1
        )
        let score = Scorer.score(weird)
        #expect((0...1).contains(score))
    }
}

@Suite("Planner – smart selection")
struct SmartSelectionTests {
    /// Phase 2 acceptance in logic form: blurry and shaky moments are skipped, faces preferred.
    @Test func blurryAndShakySegmentsAreAvoided() {
        let video = MediaItem(id: "v", kind: .video, creationDate: Fixtures.baseDate, duration: 60)
        var segments: [SegmentAnalysis] = []
        for index in 0..<120 {
            let start = Double(index) * 0.5
            let metrics: FrameMetrics
            switch start {
            case 0..<20: metrics = FrameMetrics(sharpness: 0.1)  // blurry
            case 20..<40: metrics = FrameMetrics(shake: 0.9)  // shaky
            default: metrics = FrameMetrics(sharpness: 0.8, shake: 0.05)
            }
            segments.append(SegmentAnalysis(start: start, duration: 0.5, metrics: metrics))
        }
        var request = Fixtures.request(media: [video], target: 15, style: .travel)
        request.analyses = ["v": MediaAnalysis(mediaID: "v", segments: segments)]
        let edl = Planner.plan(request)
        #expect(abs(edl.duration - 15) <= Timing.lengthTolerance)
        for clip in edl.clips {
            #expect(clip.sourceStart >= 40 - 1e-6, "picked weak footage at \(clip.sourceStart)")
        }
    }

    @Test func facesWinWhenThereIsTooMuchMaterial() {
        var media: [MediaItem] = []
        var analyses: [String: MediaAnalysis] = [:]
        for index in 0..<40 {
            let item = MediaItem(id: "p\(index)", kind: .photo, creationDate: Fixtures.baseDate.addingTimeInterval(Double(index)))
            media.append(item)
            let hasFace = index % 4 == 0
            analyses[item.id] = MediaAnalysis(
                mediaID: item.id,
                still: hasFace ? FrameMetrics(faceCount: 1, faceQuality: 0.8) : FrameMetrics()
            )
        }
        var request = Fixtures.request(media: media, target: 25)
        request.analyses = analyses
        let edl = Planner.plan(request)
        let withFaces = edl.clips.filter { Int($0.mediaID.dropFirst())! % 4 == 0 }.count
        #expect(Double(withFaces) / Double(edl.clips.count) > 0.6, "\(withFaces) of \(edl.clips.count) clips have faces")
    }

    @Test func nearIdenticalNeighboursAreDropped() {
        // A burst: photos 0-4 look the same, 5-9 are all different.
        var media: [MediaItem] = []
        var analyses: [String: MediaAnalysis] = [:]
        for index in 0..<10 {
            let item = MediaItem(id: "p\(index)", kind: .photo, creationDate: Fixtures.baseDate.addingTimeInterval(Double(index)))
            media.append(item)
            let signature: [Float] = index < 5
                ? Array(repeating: 0.5, count: 48)
                : (0..<48).map { Float(($0 * (index + 3)) % 11) / 10 }
            analyses[item.id] = MediaAnalysis(mediaID: item.id, still: FrameMetrics(), stillSignature: signature)
        }
        var request = Fixtures.request(media: media, target: 15)
        request.analyses = analyses
        let edl = Planner.plan(request)
        let burst = edl.clips.filter { Int($0.mediaID.dropFirst())! < 5 }
        #expect(burst.count == 1, "burst shots in the film: \(burst.map(\.mediaID))")
    }
}

@Suite("Music layout")
struct MusicLayoutTests {
    @Test func shortFilmUsesOneSegmentFromTheFirstBeat() {
        let track = TrackInfo.metronome(bpm: 120, duration: 120, offset: 0.3)
        let layout = MusicLayout.make(track: track, filmDuration: 30)
        #expect(layout.segments.count == 1)
        #expect(abs(layout.segments[0].trackStart - 0.3) < 1e-9)
        #expect(abs(layout.segments[0].duration - 30) < 1e-9)
        #expect(layout.beats.first == 0)
        #expect(layout.beats.last! >= 30)
    }

    @Test func longFilmLoopsAndKeepsTheBeatSpacing() {
        let track = TrackInfo.metronome(bpm: 100, duration: 50)
        let layout = MusicLayout.make(track: track, filmDuration: 600)
        let covered = layout.segments.reduce(0) { $0 + $1.duration }
        #expect(abs(covered - 600) < 1e-6)
        for (lhs, rhs) in zip(layout.segments, layout.segments.dropFirst()) {
            #expect(abs(lhs.filmStart + lhs.duration - rhs.filmStart) < 1e-9)
        }
        let gaps = zip(layout.beats.dropFirst(), layout.beats).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 0.6) < 1e-6 })
    }

    @Test func explicitLoopRegionIsRespected() {
        var track = TrackInfo.metronome(bpm: 120, duration: 100)
        track.loopStart = 20
        track.loopEnd = 80
        let layout = MusicLayout.make(track: track, filmDuration: 200)
        #expect(layout.segments.map(\.trackStart) == [0, 20, 20])
        #expect(abs(layout.segments[0].duration - 80) < 1e-9)
    }

    @Test func sectionsAreMappedToFilmTime() {
        var track = TrackInfo.metronome(bpm: 120, duration: 60)
        track.sections = [MusicSection(start: 0, end: 30, energy: 0.2), MusicSection(start: 30, end: 60, energy: 0.9)]
        let layout = MusicLayout.make(track: track, filmDuration: 100)
        #expect(layout.energy(at: 10) == 0.2)
        #expect(layout.energy(at: 40) == 0.9)
        #expect(layout.energy(at: 70) == 0.2)
    }

    @Test func silentTrackFallsBackToAMetronome() {
        let track = TrackInfo(id: "silence", duration: 60, bpm: 0, beats: [])
        let layout = MusicLayout.make(track: track, filmDuration: 20)
        #expect(layout.beats.count > 20)
        #expect(abs(layout.beatPeriod - 0.6) < 1e-9)
    }
}

@Suite("Auto length and helpers")
struct AutoLengthTests {
    @Test func suggestsSomethingSensible() {
        #expect(AutoLength.suggest(for: Fixtures.mixedMedia(photos: 6, videoDurations: [])) == 15)
        #expect(AutoLength.suggest(for: Fixtures.mixedMedia(photos: 20, videoDurations: [30, 30])) == 75)
        let lots = Fixtures.mixedMedia(photos: 200, videoDurations: Array(repeating: 120, count: 50))
        #expect(AutoLength.suggest(for: lots) == 600)
    }

    @Test func neverSuggestsMoreThanTheMaterialAllows() {
        let media = Fixtures.mixedMedia(photos: 0, videoDurations: [40, 40, 40, 40])
        let suggestion = AutoLength.suggest(for: media)
        #expect(suggestion <= Planner.maximumDuration(of: media))
    }

    @Test func generatorIsDeterministic() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        #expect((0..<10).map { _ in a.next() } == (0..<10).map { _ in b.next() })
        var c = SeededGenerator(seed: 1)
        let values = (0..<1000).map { _ in c.nextUnit() }
        #expect(values.allSatisfy { (0..<1).contains($0) })
        #expect(c.weightedIndex([0, 0]) == nil)
        #expect(c.weightedIndex([0, 1, 0]) == 1)
    }

    @Test func signatureDistanceBasics() {
        #expect(signatureDistance([0, 0], [0, 0]) == 0)
        #expect(signatureDistance([0, 0], nil) == nil)
        #expect(signatureDistance([0, 1], [0]) == nil)
        #expect(abs(signatureDistance([0, 0], [1, 1])! - 1) < 1e-9)
    }
}
