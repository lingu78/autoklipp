import Foundation

/// A part of a song with its relative energy (0 = quiet verse, 1 = loud chorus).
public struct MusicSection: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var energy: Double

    public init(start: Double, end: Double, energy: Double) {
        self.start = start
        self.end = end
        self.energy = energy
    }
}

/// Timing facts about one song, from the bundled catalogue or from beat detection.
public struct TrackInfo: Codable, Sendable, Hashable {
    public var id: String
    public var duration: Double
    public var bpm: Double
    /// Beat positions in track time, ascending.
    public var beats: [Double]
    /// Region that loops seamlessly when the film is longer than the song.
    /// When nil, the song loops from its first beat to its last whole bar.
    public var loopStart: Double?
    public var loopEnd: Double?
    public var sections: [MusicSection]

    public init(
        id: String,
        duration: Double,
        bpm: Double,
        beats: [Double],
        loopStart: Double? = nil,
        loopEnd: Double? = nil,
        sections: [MusicSection] = []
    ) {
        self.id = id
        self.duration = duration
        self.bpm = bpm
        self.beats = beats
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.sections = sections
    }

    /// A metronome track with evenly spaced beats, for tests and for films without music.
    public static func metronome(id: String = "metronome", bpm: Double, duration: Double, offset: Double = 0)
        -> TrackInfo
    {
        let period = 60 / bpm
        let count = Int(((duration - offset) / period).rounded(.down))
        let beats = (0...max(0, count)).map { offset + Double($0) * period }.filter { $0 < duration }
        return TrackInfo(id: id, duration: duration, bpm: bpm, beats: beats)
    }
}

/// One piece of the song placed on the film timeline.
public struct MusicSegment: Codable, Sendable, Hashable {
    public var filmStart: Double
    public var trackStart: Double
    public var duration: Double

    public init(filmStart: Double, trackStart: Double, duration: Double) {
        self.filmStart = filmStart
        self.trackStart = trackStart
        self.duration = duration
    }
}

/// How a song is laid under a film of a given length, and where its beats fall in film time.
///
/// The film starts on the song's first beat. If the film outlasts the song, the loop region is
/// repeated; loop points sit on beats, so the beat spacing stays regular across the seam.
/// The renderer inserts exactly `segments`, which is why the beats here are the beats you hear.
public struct MusicLayout: Sendable, Hashable {
    public var segments: [MusicSegment]
    /// Beats in film time, ascending, starting at 0 and covering the whole film.
    public var beats: [Double]
    /// Song sections in film time.
    public var sections: [MusicSection]
    public var filmDuration: Double

    /// Median beat spacing in seconds.
    public var beatPeriod: Double {
        guard beats.count > 1 else { return 0.5 }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        return gaps[gaps.count / 2]
    }

    public init(segments: [MusicSegment], beats: [Double], sections: [MusicSection], filmDuration: Double) {
        self.segments = segments
        self.beats = beats
        self.sections = sections
        self.filmDuration = filmDuration
    }

    public static func make(track: TrackInfo, filmDuration: Double) -> MusicLayout {
        let beats = track.beats.filter { $0 >= 0 && $0 < track.duration }.sorted()
        guard beats.count >= 4, filmDuration > 0 else {
            return metronome(bpm: track.bpm > 0 ? track.bpm : 100, filmDuration: filmDuration)
        }
        let firstBeat = beats[0]
        let (loopStart, loopEnd) = loopRegion(track: track, beats: beats)

        var segments: [MusicSegment] = []
        var filmBeats: [Double] = []
        var filmSections: [MusicSection] = []

        func place(trackFrom: Double, trackTo: Double, at filmStart: Double) -> Double {
            let length = min(trackTo - trackFrom, filmDuration - filmStart)
            guard length > 0 else { return filmStart }
            segments.append(MusicSegment(filmStart: filmStart, trackStart: trackFrom, duration: length))
            for beat in beats where beat >= trackFrom - 1e-9 && beat < trackFrom + length - 1e-9 {
                filmBeats.append(filmStart + beat - trackFrom)
            }
            for section in track.sections where section.end > trackFrom && section.start < trackFrom + length {
                let start = filmStart + max(section.start, trackFrom) - trackFrom
                let end = filmStart + min(section.end, trackFrom + length) - trackFrom
                filmSections.append(MusicSection(start: start, end: end, energy: section.energy))
            }
            return filmStart + length
        }

        // The first pass plays from the first beat to the end of the loop region; every later
        // pass repeats the loop region.
        var filmTime = place(trackFrom: firstBeat, trackTo: loopEnd, at: 0)
        var guardCount = 0
        while filmTime < filmDuration - 1e-9, loopEnd - loopStart > 0.5, guardCount < 10_000 {
            filmTime = place(trackFrom: loopStart, trackTo: loopEnd, at: filmTime)
            guardCount += 1
        }
        if filmTime < filmDuration - 1e-9 {
            // A degenerate loop; continue with an even grid so the planner still has beats.
            let period = filmBeats.count > 1 ? (filmBeats[filmBeats.count - 1] - filmBeats[0]) / Double(filmBeats.count - 1) : 0.5
            var t = (filmBeats.last ?? 0) + period
            while t < filmDuration + period {
                filmBeats.append(t)
                t += period
            }
        }

        // Keep one beat at or past the end so the last slot can be measured.
        let period = beatPeriodOf(filmBeats)
        while let last = filmBeats.last, last < filmDuration {
            filmBeats.append(last + period)
        }
        return MusicLayout(segments: segments, beats: filmBeats, sections: filmSections, filmDuration: filmDuration)
    }

    /// Evenly spaced beats with no song underneath.
    public static func metronome(bpm: Double, filmDuration: Double) -> MusicLayout {
        let period = 60 / max(30, bpm)
        var beats: [Double] = []
        var t = 0.0
        while t < filmDuration + period {
            beats.append(t)
            t += period
        }
        return MusicLayout(segments: [], beats: beats, sections: [], filmDuration: filmDuration)
    }

    /// Energy 0...1 of the music at film time `time`, nil when the song has no section data.
    public func energy(at time: Double) -> Double? {
        sections.first { time >= $0.start && time < $0.end }?.energy
    }

    static func loopRegion(track: TrackInfo, beats: [Double]) -> (Double, Double) {
        if let start = track.loopStart, let end = track.loopEnd, end - start > 1, start >= 0, end <= track.duration + 1e-6 {
            return (start, end)
        }
        // Loop whole bars (4 beats) from the first beat; the loop end is the beat that would follow.
        let barCount = (beats.count - 1) / 4
        guard barCount >= 1 else { return (beats[0], beats[beats.count - 1]) }
        return (beats[0], beats[barCount * 4])
    }

    static func beatPeriodOf(_ beats: [Double]) -> Double {
        guard beats.count > 1 else { return 0.5 }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        return max(0.1, gaps[gaps.count / 2])
    }
}
