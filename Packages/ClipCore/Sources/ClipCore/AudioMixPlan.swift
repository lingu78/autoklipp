import Foundation

/// A point on a volume curve; volume changes linearly between keyframes.
public struct VolumeKeyframe: Codable, Sendable, Hashable {
    public var time: Double
    public var volume: Double

    public init(time: Double, volume: Double) {
        self.time = time
        self.volume = volume
    }
}

/// How music and the videos' own sound are mixed (spec F10).
///
/// The videos' sound follows each clip, fading through transitions. Where a clip's own sound is
/// loud (speech, cheering), the music is lowered ("ducked") and comes back afterwards. The music
/// always fades out over the last seconds.
public enum AudioMixPlan {
    /// Music level while loud original sound plays.
    public static let duckedMusicVolume = 0.3
    /// Time the music takes to go down or back up.
    public static let duckRamp = 0.3
    /// Clips at or above this original-sound level duck the music.
    public static let duckingThreshold = 0.75
    /// Original-sound level for clips whose sound is loud and for quiet ones.
    public static let loudClipVolume = 1.0
    public static let quietClipVolume = 0.6
    /// Analysed loudness (0...1) from which a clip counts as loud.
    public static let loudnessForDucking = 0.35

    /// Music volume over the film: full, ducked under loud clips, faded out at the end.
    public static func musicKeyframes(for edl: EditDecisionList) -> [VolumeKeyframe] {
        let end = edl.duration
        guard end > 0 else { return [] }
        let base = edl.music?.volume ?? 1
        let fade = min(edl.music?.fadeOut ?? 2, end / 2)

        // Loud stretches, merged when the music would barely come back between them.
        var stretches: [(start: Double, end: Double)] = []
        for clip in edl.clips where clip.audioVolume >= duckingThreshold {
            if let last = stretches.last, clip.timelineStart - last.end < 2 * duckRamp {
                stretches[stretches.count - 1].end = max(last.end, clip.timelineEnd)
            } else {
                stretches.append((clip.timelineStart, clip.timelineEnd))
            }
        }

        var keys = [VolumeKeyframe(time: 0, volume: stretches.first.map { $0.start <= 0 ? duckedMusicVolume : base } ?? base)]
        for stretch in stretches {
            let down = max(0, stretch.start - duckRamp)
            if down > keys[keys.count - 1].time {
                keys.append(VolumeKeyframe(time: down, volume: base))
            }
            keys.append(VolumeKeyframe(time: max(down, stretch.start), volume: duckedMusicVolume))
            keys.append(VolumeKeyframe(time: stretch.end, volume: duckedMusicVolume))
            if stretch.end + duckRamp <= end {
                keys.append(VolumeKeyframe(time: stretch.end + duckRamp, volume: base))
            }
        }

        // Fade out: keep the curve up to the fade, then go to silence.
        let fadeStart = end - fade
        let level = volume(at: fadeStart, keys: keys, fallback: base)
        keys = keys.filter { $0.time < fadeStart - 1e-9 }
        keys.append(VolumeKeyframe(time: fadeStart, volume: level))
        keys.append(VolumeKeyframe(time: end, volume: 0))
        return keys
    }

    /// The videos' own sound for one clip: its level, faded in and out over half of each
    /// neighbouring transition (the parts where the clip overlaps its neighbours).
    public static func clipKeyframes(for edl: EditDecisionList, clipIndex index: Int) -> [VolumeKeyframe] {
        let clip = edl.clips[index]
        guard clip.audioVolume > 0 else { return [] }
        let before = clip.transitionIn.duration / 2
        let after = index + 1 < edl.clips.count ? edl.clips[index + 1].transitionIn.duration / 2 : 0
        let start = max(0, clip.timelineStart - before)
        let end = min(edl.duration, clip.timelineEnd + after)
        var keys: [VolumeKeyframe] = []
        keys.append(VolumeKeyframe(time: start, volume: before > 0 ? 0 : clip.audioVolume))
        if before > 0 { keys.append(VolumeKeyframe(time: clip.timelineStart + before, volume: clip.audioVolume)) }
        if after > 0 { keys.append(VolumeKeyframe(time: clip.timelineEnd - after, volume: clip.audioVolume)) }
        keys.append(VolumeKeyframe(time: end, volume: after > 0 ? 0 : clip.audioVolume))
        return keys
    }

    /// Linear interpolation on a keyframe curve.
    public static func volume(at time: Double, keys: [VolumeKeyframe], fallback: Double = 1) -> Double {
        guard let first = keys.first else { return fallback }
        if time <= first.time { return first.volume }
        for (lhs, rhs) in zip(keys, keys.dropFirst()) where time <= rhs.time {
            let span = rhs.time - lhs.time
            guard span > 1e-9 else { return rhs.volume }
            return lhs.volume + (rhs.volume - lhs.volume) * (time - lhs.time) / span
        }
        return keys[keys.count - 1].volume
    }
}
