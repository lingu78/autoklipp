import Foundation
import Testing

@testable import ClipCore

@Suite("Beat tracking")
struct BeatTrackerTests {
    /// An onset envelope like a pop song: strong beats, weaker off-beats and 16ths, noise.
    static func envelope(bpm: Double, seconds: Double, frameRate: Double = 86.13, jitter: Double = 0.008,
                         offset: Double = 0.21, offBeat: Double = 0.45, seed: UInt64 = 1)
        -> (envelope: [Double], beats: [Double])
    {
        var rng = SeededGenerator(seed: seed)
        let count = Int(seconds * frameRate)
        var envelope = (0..<count).map { _ in 0.15 * rng.nextUnit() }
        let period = 60 / bpm
        var beats: [Double] = []
        var time = offset
        var beatIndex = 0
        while time < seconds - 0.1 {
            let actual = time + jitter * (rng.nextUnit() * 2 - 1)
            beats.append(actual)
            func hit(_ at: Double, _ strength: Double) {
                let frame = at * frameRate
                let whole = Int(frame)
                guard whole + 1 < count, whole >= 0 else { return }
                let fraction = frame - Double(whole)
                envelope[whole] += strength * (1 - fraction)
                envelope[whole + 1] += strength * fraction
            }
            hit(actual, beatIndex % 4 == 0 ? 1.6 : 1.0)
            hit(actual + period / 2, offBeat)
            hit(actual + period / 4, 0.2)
            hit(actual + 3 * period / 4, 0.2)
            time += period
            beatIndex += 1
        }
        return (envelope, beats)
    }

    @Test(arguments: [72.0, 86, 98, 104, 112, 124, 128, 140])
    func findsTempoAndBeats(bpm: Double) throws {
        let frameRate = 86.13
        let (envelope, truth) = Self.envelope(bpm: bpm, seconds: 60, frameRate: frameRate)
        let result = try #require(BeatTracker.track(envelope: envelope, frameRate: frameRate))
        // A fast song with an accented downbeat may be followed every other beat; every cut
        // still lands on a beat.
        let halved = bpm >= 120 && abs(result.bpm - bpm / 2) < 1
        #expect(abs(result.bpm - bpm) < 1.5 || halved, "found \(result.bpm) BPM for \(bpm)")
        Self.expectOnTheBeat(result, truth: truth, step: (halved ? 2 : 1) * 60 / bpm, until: 57)
    }

    /// Off-beat eighths as strong as hi-hats and bass in dance music must not double the tempo.
    @Test(arguments: [72.0, 84, 128])
    func offBeatEighthsDoNotDoubleTheTempo(bpm: Double) throws {
        let frameRate = 86.13
        let (envelope, truth) = Self.envelope(bpm: bpm, seconds: 60, frameRate: frameRate, offBeat: 0.7, seed: 5)
        let result = try #require(BeatTracker.track(envelope: envelope, frameRate: frameRate))
        let halved = bpm >= 120 && abs(result.bpm - bpm / 2) < 1
        #expect(abs(result.bpm - bpm) < 1.5 || halved, "found \(result.bpm) BPM for \(bpm)")
        Self.expectOnTheBeat(result, truth: truth, step: (halved ? 2 : 1) * 60 / bpm, until: 57)
    }

    /// Every detected beat is within 50 ms of a true beat, and none is skipped.
    static func expectOnTheBeat(_ result: BeatTracker.Result, truth: [Double], step: Double, until end: Double) {
        let detected = result.beats.filter { $0 > 3 && $0 < end }
        let off = detected.filter { beat in !truth.contains { abs($0 - beat) <= 0.05 } }
        #expect(Double(off.count) / Double(max(1, detected.count)) < 0.05, "\(off.count) of \(detected.count) beats off the beat")
        let gaps = zip(detected.dropFirst(), detected).map { $0 - $1 }
        let uneven = gaps.filter { abs($0 - step) > 0.1 * step }
        #expect(uneven.count <= gaps.count / 20, "\(uneven.count) of \(gaps.count) gaps are not one step")
    }

    @Test func followsTheTimeOffset() throws {
        let (envelope, truth) = Self.envelope(bpm: 100, seconds: 30, jitter: 0)
        let result = try #require(BeatTracker.track(envelope: envelope, frameRate: 86.13, timeOffset: 0.5))
        let first = truth.first { $0 > 5 }!
        #expect(result.beats.contains { abs($0 - (first + 0.5)) < 0.03 })
    }

    @Test func silenceGivesNothing() {
        #expect(BeatTracker.track(envelope: Array(repeating: 0, count: 3000), frameRate: 86) == nil)
        #expect(BeatTracker.track(envelope: [1, 2, 3], frameRate: 86) == nil)
    }

    @Test func sectionsFollowLoudness() {
        let beats = (0..<128).map { Double($0) * 0.5 }
        // Quiet first half, loud second half.
        let loudness = (0..<64).map { $0 < 32 ? 0.2 : 0.9 }
        // 128 beats in sections of 4 bars (16 beats) gives 8 sections.
        let sections = BeatTracker.sections(loudness: loudness, loudnessRate: 1, beats: beats, barsPerSection: 4)
        #expect(sections.count == 8)
        #expect(sections.first!.energy < 0.2)
        #expect(sections.last!.energy > 0.8)
        #expect(sections.first!.start == 0)
    }
}
