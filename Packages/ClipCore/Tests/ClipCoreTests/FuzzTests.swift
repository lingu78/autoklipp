import Foundation
import Testing

@testable import ClipCore

@Suite("Planner – randomised material")
struct PlannerFuzzTests {
    static func randomMaterial(_ rng: inout SeededGenerator) -> [MediaItem] {
        let photos = Int(rng.next() % 60)
        let videos = Int(rng.next() % 25) + (photos == 0 ? 1 : 0)
        let durations = (0..<videos).map { _ in (rng.nextDouble(in: 0.3...180) * 10).rounded() / 10 }
        return Fixtures.mixedMedia(photos: photos, videoDurations: durations, shuffleSeed: rng.next())
    }

    @Test func wellFormedAndOnLengthWhenMaterialSuffices() {
        var rng = SeededGenerator(seed: 2026)
        for round in 0..<60 {
            let media = Self.randomMaterial(&rng)
            let maximum = Planner.maximumDuration(of: media)
            let target = min(600, max(15, (rng.nextDouble(in: 0.05...0.6) * maximum).rounded()))
            let style = StyleID.allCases[Int(rng.next() % UInt64(StyleID.allCases.count))]
            let bpm = rng.nextDouble(in: 60...180)
            let edl = Planner.plan(Fixtures.request(media: media, target: target, style: style, bpm: bpm, seed: rng.next()))
            expectWellFormed(edl, media: media)
            if target <= 0.6 * maximum {
                #expect(abs(edl.duration - target) <= Timing.lengthTolerance,
                        "round \(round): \(style) \(Int(bpm)) BPM, target \(target) of max \(maximum): got \(edl.duration)")
            }
        }
    }

    @Test func usesMostOfTheMaterialBeforeGivingUp() {
        var rng = SeededGenerator(seed: 77)
        for _ in 0..<20 {
            let media = Self.randomMaterial(&rng)
            let maximum = Planner.maximumDuration(of: media)
            guard maximum >= 30 else { continue }
            let style = StyleID.allCases[Int(rng.next() % UInt64(StyleID.allCases.count))]
            let edl = Planner.plan(Fixtures.request(media: media, target: min(600, maximum * 2), style: style, bpm: rng.nextDouble(in: 70...150)))
            expectWellFormed(edl, media: media)
            // Beat rounding of stills and leftovers shorter than a clip cost a little.
            #expect(edl.duration >= 0.8 * min(600, maximum), "\(style): \(edl.duration) of possible \(maximum)")
        }
    }

    @Test func largeProjectPlansQuickly() {
        let media = Fixtures.mixedMedia(photos: 150, videoDurations: Array(repeating: 95, count: 50))
        let clock = ContinuousClock()
        var edl: EditDecisionList?
        let elapsed = clock.measure {
            edl = Planner.plan(Fixtures.request(media: media, target: 600, style: .energetic, bpm: 128))
        }
        #expect(abs(edl!.duration - 600) <= Timing.lengthTolerance)
        // Generous bound for unoptimised debug builds on CI machines.
        #expect(elapsed < .seconds(20), "planning took \(elapsed)")
        print("large project: \(edl!.clips.count) clips in \(elapsed)")
    }
}
