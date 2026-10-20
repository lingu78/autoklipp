import Foundation
import Testing

@testable import ClipCore

@Suite("Audio mix")
struct AudioMixTests {
    func edl(volumes: [Double], clipLength: Double = 2, transition: Double = 0) -> EditDecisionList {
        let clips = volumes.enumerated().map { index, volume in
            EDLClip(
                id: "c\(index)", mediaID: "m\(index)", kind: .video, sourceStart: 0, sourceDuration: clipLength,
                timelineStart: Double(index) * clipLength, duration: clipLength, beats: 4,
                transitionIn: index == 0 ? .cut : ClipTransition(kind: .crossfade, duration: transition),
                audioVolume: volume
            )
        }
        let total = Double(volumes.count) * clipLength
        return EditDecisionList(
            targetDuration: total, duration: total, style: .travel, seed: 1,
            music: MusicCue(trackID: "song", segments: [MusicSegment(filmStart: 0, trackStart: 0, duration: total)]),
            clips: clips
        )
    }

    @Test func musicFadesOutOverTheLastTwoSeconds() {
        let keys = AudioMixPlan.musicKeyframes(for: edl(volumes: [0, 0, 0, 0, 0]))
        #expect(keys.first == VolumeKeyframe(time: 0, volume: 1))
        #expect(keys.last == VolumeKeyframe(time: 10, volume: 0))
        #expect(AudioMixPlan.volume(at: 7.9, keys: keys) == 1)
        #expect(abs(AudioMixPlan.volume(at: 9, keys: keys) - 0.5) < 1e-9)
    }

    @Test func loudOriginalSoundDucksTheMusic() {
        let keys = AudioMixPlan.musicKeyframes(for: edl(volumes: [0, 1, 1, 0, 0, 0]))
        #expect(AudioMixPlan.volume(at: 1, keys: keys) == 1)
        #expect(AudioMixPlan.volume(at: 2.5, keys: keys) == AudioMixPlan.duckedMusicVolume)
        #expect(AudioMixPlan.volume(at: 5.5, keys: keys) == AudioMixPlan.duckedMusicVolume)
        #expect(AudioMixPlan.volume(at: 7, keys: keys) == 1)
        // Times never go backwards.
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    @Test func quietOriginalSoundLeavesTheMusicAlone() {
        let keys = AudioMixPlan.musicKeyframes(for: edl(volumes: [0.6, 0.6, 0.6]))
        #expect(AudioMixPlan.volume(at: 3, keys: keys) == 1)
    }

    @Test func clipSoundFadesThroughTransitions() {
        let list = edl(volumes: [1, 1, 1], transition: 0.8)
        let keys = AudioMixPlan.clipKeyframes(for: list, clipIndex: 1)
        #expect(keys.first == VolumeKeyframe(time: 1.6, volume: 0))
        #expect(AudioMixPlan.volume(at: 3, keys: keys) == 1)
        #expect(keys.last == VolumeKeyframe(time: 4.4, volume: 0))
        #expect(AudioMixPlan.clipKeyframes(for: edl(volumes: [0, 0]), clipIndex: 0).isEmpty)
    }

    @Test func plannerSetsOriginalSoundFromLoudness() {
        let loud = MediaItem(id: "loud", kind: .video, creationDate: Fixtures.baseDate, duration: 10, hasAudio: true)
        let quiet = MediaItem(id: "quiet", kind: .video, creationDate: Fixtures.baseDate.addingTimeInterval(60), duration: 10, hasAudio: true)
        let silent = MediaItem(id: "silent", kind: .video, creationDate: Fixtures.baseDate.addingTimeInterval(120), duration: 10, hasAudio: false)
        var request = Fixtures.request(media: [loud, quiet, silent], target: 15)
        request.analyses = [
            "loud": Fixtures.uniformVideo(loud, FrameMetrics(audioLevel: 0.8)),
            "quiet": Fixtures.uniformVideo(quiet, FrameMetrics(audioLevel: 0.1)),
        ]
        #expect(Planner.plan(request).clips.allSatisfy { $0.audioVolume == 0 }, "original sound is off by default")
        request.originalAudio = true
        let edl = Planner.plan(request)
        for clip in edl.clips {
            switch clip.mediaID {
            case "loud": #expect(clip.audioVolume == AudioMixPlan.loudClipVolume)
            case "quiet": #expect(clip.audioVolume == AudioMixPlan.quietClipVolume)
            default: #expect(clip.audioVolume == 0)
            }
        }
    }
}
