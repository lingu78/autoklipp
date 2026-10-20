import Foundation

/// Fixed rules of the edit, shared by the planner, the app and the tests.
public enum Timing {
    /// Videos are analysed and scored in slices of this length.
    public static let segmentLength = 0.5
    /// Stills are shown for this long (spec F6).
    public static let stillRange: ClosedRange<Double> = 1.5...4
    /// Shortest video clip in the film.
    public static let minVideoClip = 0.5
    /// Videos shorter than this are skipped.
    public static let minSourceVideo = 0.5
    /// Films longer than this alternate between denser and sparser passages.
    public static let longFilm = 180.0
    /// The last clip may end this much before its beat or start this close to the end.
    public static let tailTolerance = 0.4
    /// Colour-layout distance below which two shots count as near identical.
    public static let duplicateDistance = 0.05
    /// Allowed deviation of the film length from the target (spec F2).
    public static let lengthTolerance = 1.0
}

/// Part of the material the user removed from the edit.
public struct Exclusion: Codable, Sendable, Hashable {
    public var mediaID: String
    /// Removed source range; nil removes the whole item.
    public var start: Double?
    public var end: Double?

    public init(mediaID: String, start: Double? = nil, end: Double? = nil) {
        self.mediaID = mediaID
        self.start = start
        self.end = end
    }
}

/// A chapter suggested by the AI director.
public struct DirectorChapter: Codable, Sendable, Hashable {
    public var title: String
    public var mediaIDs: [String]

    public init(title: String, mediaIDs: [String]) {
        self.title = title
        self.mediaIDs = mediaIDs
    }
}

/// What the optional AI director decides: which media, in which order. Never timing.
public struct DirectorPlan: Codable, Sendable, Hashable {
    public var mediaIDs: [String]
    public var chapters: [DirectorChapter]
    public var suggestedStyle: StyleID?
    public var title: String?

    public init(mediaIDs: [String], chapters: [DirectorChapter] = [], suggestedStyle: StyleID? = nil, title: String? = nil) {
        self.mediaIDs = mediaIDs
        self.chapters = chapters
        self.suggestedStyle = suggestedStyle
        self.title = title
    }
}

/// Everything the planner needs to build a clip list.
public struct PlanningRequest: Sendable {
    public var media: [MediaItem]
    public var analyses: [String: MediaAnalysis]
    /// Requested film length in seconds.
    public var targetDuration: Double
    public var style: StyleParameters
    public var music: MusicLayout
    public var musicTrackID: String?
    public var seed: UInt64
    /// Clips the user locked; they are always part of the result.
    public var lockedClips: [EDLClip]
    public var exclusions: [Exclusion]
    public var director: DirectorPlan?
    public var frameRate: Int
    public var title: String?
    public var endCredit: String?
    /// Keep the videos' own sound under the music.
    public var originalAudio: Bool

    public init(
        media: [MediaItem],
        analyses: [String: MediaAnalysis] = [:],
        targetDuration: Double,
        style: StyleParameters,
        music: MusicLayout,
        musicTrackID: String? = nil,
        seed: UInt64 = 0,
        lockedClips: [EDLClip] = [],
        exclusions: [Exclusion] = [],
        director: DirectorPlan? = nil,
        frameRate: Int = 30,
        title: String? = nil,
        endCredit: String? = nil,
        originalAudio: Bool = false
    ) {
        self.media = media
        self.analyses = analyses
        self.targetDuration = targetDuration
        self.style = style
        self.music = music
        self.musicTrackID = musicTrackID
        self.seed = seed
        self.lockedClips = lockedClips
        self.exclusions = exclusions
        self.director = director
        self.frameRate = frameRate
        self.title = title
        self.endCredit = endCredit
        self.originalAudio = originalAudio
    }
}

/// Builds a clip list of fixed length from media, analysis and a beat grid.
///
/// 1. Every video is scored in 0.5 s segments, every still as a whole.
/// 2. A duration budget decides how many moments are needed; when there are more sources than
///    room, the material is split into equal chronological groups and the best source of each
///    group is used, so the whole event is covered. Otherwise every source contributes once and
///    the rest of the budget goes to extra moments from the best and longest videos, spread
///    evenly over each video.
/// 3. Moments are ordered chronologically (or in the director's order) and near-identical
///    neighbours are dropped.
/// 4. Each moment gets a whole number of beats; lengths are nudged one beat at a time, and
///    moments are added or removed, until the last clip ends on the target length.
/// 5. Transitions, filter and Ken Burns moves are chosen with a seeded generator.
public enum Planner {
    public static func plan(_ request: PlanningRequest) -> EditDecisionList {
        var engine = PlanningEngine(request: request)
        return engine.run()
    }

    /// Longest film the material allows without repeating anything.
    public static func maximumDuration(of media: [MediaItem]) -> Double {
        media.reduce(0) { total, item in
            if item.kind.isStill { return total + Timing.stillRange.upperBound }
            return total + (item.duration >= Timing.minSourceVideo ? item.duration : 0)
        }
    }
}

// MARK: - Engine

struct PlanningEngine {
    struct Source {
        var order: Int
        var item: MediaItem
        /// Per segment; negative marks a range the user removed.
        var segmentScores: [Double]
        var segmentSignatures: [[Float]?]
        /// Analysed loudness per segment, when known.
        var segmentAudio: [Double?]
        var stillScore: Double
        var stillSignature: [Float]?
        var faces: [NormalizedRect]
        var quality: Double
        var usableDuration: Double
        /// Not part of the director's choice; only used when the chosen media run out.
        var isSecondary: Bool

        var isStill: Bool { item.kind.isStill }
    }

    struct Moment {
        var source: Int
        var start: Double
        var length: Double
        var score: Double
        var locked: EDLClip?

        var end: Double { start + length }
        var center: Double { start + length / 2 }
    }

    struct Slot {
        var moment: Moment
        var k: Int
        var pref = 1
        var softMin = 1
        var softMax = 1
        var hardMin = 1
        var hardMax = 1
        var roomStart = 0.0
        var roomEnd = 0.0
    }

    let request: PlanningRequest
    let style: StyleParameters
    let target: Double
    let beats: [Double]
    let beatPeriod: Double
    var rng: SeededGenerator
    var sources: [Source] = []
    var sourceIndexByID: [String: Int] = [:]
    /// Sources dropped as near duplicates; never added back.
    var rejectedSources: Set<Int> = []

    // Beat counts derived from the tempo.
    let stillMinBeats: Int
    let stillMaxBeats: Int
    let stillPrefBeats: Int
    let videoMinBeats: Int
    let videoSoft: ClosedRange<Int>
    let videoPrefBeats: Int

    init(request: PlanningRequest) {
        self.request = request
        style = request.style
        target = max(1, request.targetDuration)
        rng = SeededGenerator(seed: request.seed ^ 0x5EED_C11F)

        var grid = request.music.beats.filter { $0 >= 0 }.sorted()
        if grid.count < 2 || grid[0] > 1e-6 {
            grid = MusicLayout.metronome(bpm: 100, filmDuration: request.targetDuration).beats
        }
        let period = MusicLayout.beatPeriodOf(grid)
        while let last = grid.last, last < request.targetDuration + period {
            grid.append(last + period)
        }
        beats = grid
        beatPeriod = period

        let stillMin = max(1, Int((Timing.stillRange.lowerBound / period - 1e-6).rounded(.up)))
        let stillMax = max(stillMin, Int((Timing.stillRange.upperBound / period + 1e-6).rounded(.down)))
        stillMinBeats = stillMin
        stillMaxBeats = stillMax
        stillPrefBeats = min(stillMax, max(stillMin, Int((request.style.stillDuration / period).rounded())))

        let videoMin = max(1, Int((Timing.minVideoClip / period - 1e-6).rounded(.up)))
        videoMinBeats = videoMin
        let lower = max(videoMin, request.style.beatsPerClip.lowerBound)
        let upper = max(lower, request.style.beatsPerClip.upperBound)
        videoSoft = lower...upper
        videoPrefBeats = min(upper, max(lower, Int((request.style.typicalClipDuration / period).rounded())))
    }

    var expectedStill: Double { Double(stillPrefBeats) * beatPeriod }
    /// Long films swing through the whole range, so their average clip is mid-range.
    var expectedVideo: Double {
        let beats = target > Timing.longFilm
            ? Double(videoSoft.lowerBound + videoSoft.upperBound) / 2 : Double(videoPrefBeats)
        return beats * beatPeriod
    }

    mutating func run() -> EditDecisionList {
        buildSources()
        var moments = initialMoments()
        moments = ordered(moments)
        moments = removingNeighbourDuplicates(moments)
        let (slots, shortage) = fit(moments)
        return makeEDL(slots: slots, shortage: shortage)
    }

    // MARK: Sources

    mutating func buildSources() {
        let lockedIDs = Set(request.lockedClips.map(\.mediaID))
        let wholeExclusions = Set(request.exclusions.filter { $0.start == nil || $0.end == nil }.map(\.mediaID))
        var items = request.media.filter { item in
            if lockedIDs.contains(item.id) { return true }
            if wholeExclusions.contains(item.id) { return false }
            return item.kind.isStill || item.duration >= Timing.minSourceVideo
        }
        items = items.chronological()

        var secondary = Set<String>()
        if let director = request.director, !director.mediaIDs.isEmpty {
            let known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let primary = director.mediaIDs.compactMap { id -> MediaItem? in
                guard seen.insert(id).inserted else { return nil }
                return known[id]
            }
            let rest = items.filter { !seen.contains($0.id) }
            secondary = Set(rest.map(\.id))
            items = primary + rest
        }

        let neutralVideo = Scorer.score(.neutral)
        let neutralStill = Scorer.stillScore(.neutral)
        for (order, item) in items.enumerated() {
            let analysis = request.analyses[item.id]
            var source = Source(
                order: order, item: item, segmentScores: [], segmentSignatures: [], segmentAudio: [],
                stillScore: neutralStill, stillSignature: analysis?.stillSignature,
                faces: analysis?.faceRegions ?? [], quality: 0, usableDuration: 0,
                isSecondary: secondary.contains(item.id)
            )
            let jitter = { (rng: inout SeededGenerator, amount: Double) in amount * (rng.nextUnit() - 0.5) }
            if item.kind.isStill {
                if let metrics = analysis?.still { source.stillScore = Scorer.stillScore(metrics) }
                source.stillScore = min(1, max(0, source.stillScore + jitter(&rng, style.variety)))
                source.quality = source.stillScore
                source.usableDuration = Timing.stillRange.upperBound
            } else {
                let count = max(1, Int((item.duration / Timing.segmentLength - 1e-9).rounded(.up)))
                var byIndex: [Int: SegmentAnalysis] = [:]
                for segment in analysis?.segments ?? [] {
                    byIndex[Int((segment.start / Timing.segmentLength).rounded())] = segment
                }
                let removed = request.exclusions.filter { $0.mediaID == item.id && $0.start != nil && $0.end != nil }
                var scores: [Double] = []
                var signatures: [[Float]?] = []
                var audio: [Double?] = []
                for index in 0..<count {
                    let start = Double(index) * Timing.segmentLength
                    let end = min(item.duration, start + Timing.segmentLength)
                    let segment = byIndex[index]
                    var score = segment.map { Scorer.score($0.metrics) } ?? neutralVideo
                    score = min(1, max(0, score + jitter(&rng, style.variety * 0.6)))
                    if removed.contains(where: { start < ($0.end ?? 0) && end > ($0.start ?? 0) }) { score = -1 }
                    scores.append(score)
                    signatures.append(segment?.signature)
                    audio.append(segment?.metrics.audioLevel)
                }
                source.segmentScores = scores
                source.segmentSignatures = signatures
                source.segmentAudio = audio
                let usable = scores.filter { $0 >= 0 }
                source.usableDuration = min(item.duration, Double(usable.count) * Timing.segmentLength)
                let best = usable.sorted(by: >).prefix(max(1, usable.count / 2))
                source.quality = best.isEmpty ? 0 : best.reduce(0, +) / Double(best.count)
                source.quality = min(1, max(0, source.quality + jitter(&rng, style.variety)))
            }
            sourceIndexByID[item.id] = sources.count
            sources.append(source)
        }
    }

    // MARK: Selection

    mutating func initialMoments() -> [Moment] {
        var moments: [Moment] = []
        for clip in request.lockedClips {
            guard let index = sourceIndexByID[clip.mediaID] else { continue }
            let source = sources[index]
            let length = source.isStill ? expectedStill : min(max(clip.sourceDuration, Timing.minVideoClip), source.item.duration)
            let start = source.isStill ? 0 : min(max(0, clip.sourceStart), max(0, source.item.duration - length))
            moments.append(Moment(source: index, start: start, length: length, score: clip.score, locked: clip))
        }
        let lockedSources = Set(moments.map(\.source))
        let free = sources.indices.filter {
            !lockedSources.contains($0) && !sources[$0].isSecondary && sources[$0].usableDuration > 0
        }
        func firstDuration(_ index: Int) -> Double {
            sources[index].isStill ? expectedStill : min(expectedVideo, sources[index].usableDuration)
        }
        let lockedDuration = moments.reduce(0.0) { total, moment in
            total + (sources[moment.source].isStill ? expectedStill : moment.length)
        }
        let budget = target - lockedDuration
        let freeTotal = free.reduce(0.0) { $0 + firstDuration($1) }

        var counts: [Int: Int] = [:]
        if budget <= 0 || free.isEmpty {
            // Locked clips fill the film on their own.
        } else if freeTotal > budget {
            let average = freeTotal / Double(free.count)
            let groups = min(free.count, max(1, Int((budget / average).rounded())))
            for group in 0..<groups {
                let lower = group * free.count / groups
                let upper = (group + 1) * free.count / groups
                let members = free[lower..<upper]
                if let best = members.max(by: { sources[$0].quality < sources[$1].quality }) {
                    counts[best] = 1
                }
            }
        } else {
            for index in free { counts[index] = 1 }
            var remaining = budget - freeTotal
            while remaining > expectedVideo * 0.5 {
                var choice: Int?
                var bestValue = -Double.infinity
                for index in free where !sources[index].isStill {
                    let count = counts[index, default: 0]
                    let capacity = max(1, Int(sources[index].usableDuration / expectedVideo))
                    guard count < capacity else { continue }
                    let value = sources[index].quality * (1 - Double(count) / Double(capacity)).squareRoot()
                    if value > bestValue {
                        bestValue = value
                        choice = index
                    }
                }
                guard let choice else { break }
                counts[choice, default: 0] += 1
                remaining -= expectedVideo
            }
        }

        for index in counts.keys.sorted() {
            let count = counts[index] ?? 0
            let source = sources[index]
            if source.isStill {
                moments.append(Moment(source: index, start: 0, length: expectedStill, score: source.stillScore))
                continue
            }
            var windows = moments.filter { $0.source == index }.map { ($0.start, $0.end) }
            let spacing = source.item.duration / Double(count + windows.count)
            for _ in 0..<count {
                guard let window = nextWindow(source, length: expectedVideo, existing: windows, spacing: spacing) else { break }
                moments.append(Moment(source: index, start: window.start, length: window.length, score: window.score))
                windows.append((window.start, window.start + window.length))
            }
        }
        return moments
    }

    /// Weight of being far from a video's other moments, relative to segment quality.
    static let spreadWeight = 0.15

    /// Shortest footage worth a moment of its own.
    var shortestMoment: Double { max(Timing.minVideoClip, beatPeriod * Double(videoMinBeats)) }

    /// The best free window of a video: high quality first, then far from the moments it
    /// already has, so footage is spread over the video without settling for weak parts.
    ///
    /// Windows are preferably placed so that the footage left between them is either nothing or
    /// room for another full window, since scattered leftovers are wasted. With `allowShort`, a
    /// leftover shorter than `length` may be used as well.
    func nextWindow(
        _ source: Source, length: Double, existing: [(Double, Double)], spacing: Double, allowShort: Bool = false
    ) -> (start: Double, length: Double, score: Double, value: Double)? {
        let duration = source.item.duration
        let windowLength = min(length, duration)
        guard windowLength >= Timing.minVideoClip - 1e-9 else { return nil }

        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for window in existing.sorted(by: { $0.0 < $1.0 }) {
            if window.0 > cursor + 1e-9 { gaps.append((cursor, window.0)) }
            cursor = max(cursor, window.1)
        }
        if duration > cursor + 1e-9 { gaps.append((cursor, duration)) }

        let reach = max(spacing, windowLength)
        func evaluate(start: Double, length: Double) -> (score: Double, value: Double)? {
            let score = windowScore(source, start: start, length: length)
            guard score >= 0 else { return nil }
            let center = start + length / 2
            let distance = existing.map { abs(($0.0 + $0.1) / 2 - center) }.min() ?? .infinity
            // Ties go to the middle of the video.
            let middle = 0.001 * (1 - abs(center - duration / 2) / max(1, duration))
            return (score, score + Self.spreadWeight * min(1, distance / reach) + middle)
        }

        // Untidy placement costs a little, so it only wins on clearly better footage.
        let untidy = 0.05
        var best: (start: Double, length: Double, score: Double, value: Double)?
        func consider(_ candidate: (start: Double, length: Double, score: Double, value: Double)) {
            if best == nil || candidate.value > best!.value + 1e-12 { best = candidate }
        }
        for gap in gaps {
            let span = gap.1 - gap.0
            if span + 1e-9 >= windowLength {
                var starts: [Double] = []
                var position = gap.0
                while position + windowLength <= gap.1 + 1e-9 {
                    starts.append(position)
                    position += Timing.segmentLength
                }
                if let last = starts.last, gap.1 - windowLength - last > 1e-6 { starts.append(gap.1 - windowLength) }
                for start in starts {
                    guard let rating = evaluate(start: start, length: windowLength) else { continue }
                    let before = start - gap.0
                    let after = gap.1 - start - windowLength
                    let tiles = (before < 1e-6 || before >= windowLength - 1e-6) && (after < 1e-6 || after >= windowLength - 1e-6)
                    consider((start, windowLength, rating.score, rating.value - (tiles ? 0 : untidy)))
                }
            } else if allowShort, span >= shortestMoment - 1e-9, let rating = evaluate(start: gap.0, length: span) {
                consider((gap.0, span, rating.score, rating.value - untidy))
            }
        }
        return best
    }

    /// Mean segment score over a window, or -1 when it touches a removed range.
    func windowScore(_ source: Source, start: Double, length: Double) -> Double {
        let scores = source.segmentScores
        var total = 0.0
        var weight = 0.0
        var index = max(0, Int(start / Timing.segmentLength))
        while index < scores.count {
            let segmentStart = Double(index) * Timing.segmentLength
            if segmentStart >= start + length - 1e-9 { break }
            let overlap = min(segmentStart + Timing.segmentLength, start + length) - max(segmentStart, start)
            if overlap > 1e-9 {
                if scores[index] < 0 { return -1 }
                total += scores[index] * overlap
                weight += overlap
            }
            index += 1
        }
        return weight > 0 ? total / weight : -1
    }

    func signature(of moment: Moment) -> [Float]? {
        let source = sources[moment.source]
        if source.isStill { return source.stillSignature }
        let index = min(source.segmentSignatures.count - 1, max(0, Int(moment.center / Timing.segmentLength)))
        return source.segmentSignatures.isEmpty ? nil : source.segmentSignatures[index]
    }

    func isNearDuplicate(_ lhs: Moment, _ rhs: Moment) -> Bool {
        guard let distance = signatureDistance(signature(of: lhs), signature(of: rhs)) else { return false }
        return distance < Timing.duplicateDistance
    }

    func orderKey(_ moment: Moment) -> (Int, Double) {
        (sources[moment.source].order, moment.start)
    }

    func ordered(_ moments: [Moment]) -> [Moment] {
        moments.sorted { orderKey($0) < orderKey($1) }
    }

    mutating func removingNeighbourDuplicates(_ moments: [Moment]) -> [Moment] {
        var result: [Moment] = []
        for moment in moments {
            guard let previous = result.last, isNearDuplicate(previous, moment) else {
                result.append(moment)
                continue
            }
            if previous.locked != nil && moment.locked != nil {
                result.append(moment)
            } else if moment.locked == nil && (previous.locked != nil || previous.score >= moment.score) {
                rejectIfLast(moment, remaining: result)
            } else {
                result.removeLast()
                rejectIfLast(previous, remaining: result)
                result.append(moment)
            }
        }
        return result
    }

    mutating func rejectIfLast(_ moment: Moment, remaining: [Moment]) {
        if !remaining.contains(where: { $0.source == moment.source }) {
            rejectedSources.insert(moment.source)
        }
    }

    // MARK: Fitting to the beat grid

    func beatTime(_ index: Int) -> Double {
        if index < beats.count { return beats[max(0, index)] }
        return beats[beats.count - 1] + Double(index - beats.count + 1) * beatPeriod
    }

    func density(at time: Double) -> Double? {
        guard target > Timing.longFilm else { return nil }
        if let energy = request.music.energy(at: time) { return min(1, max(0, energy)) }
        return 0.5 + 0.5 * sin(2 * Double.pi * time / 64)
    }

    /// Recomputes rooms, bounds and preferred lengths after the set of moments changed.
    func recomputed(_ slots: [Slot]) -> [Slot] {
        var result = slots
        var bySource: [Int: [Int]] = [:]
        for (index, slot) in result.enumerated() { bySource[slot.moment.source, default: []].append(index) }

        for (sourceIndex, indices) in bySource {
            let source = sources[sourceIndex]
            if source.isStill {
                for index in indices {
                    result[index].hardMin = stillMinBeats
                    result[index].hardMax = stillMaxBeats
                    result[index].softMin = stillMinBeats
                    result[index].softMax = stillMaxBeats
                }
                continue
            }
            let sorted = indices.sorted { result[$0].moment.start < result[$1].moment.start }
            for (position, index) in sorted.enumerated() {
                let moment = result[index].moment
                var roomStart = position == 0 ? 0 : (result[sorted[position - 1]].moment.end + moment.start) / 2
                var roomEnd = position == sorted.count - 1
                    ? source.item.duration : (moment.end + result[sorted[position + 1]].moment.start) / 2
                if moment.locked != nil { roomStart = moment.start }
                roomStart = min(roomStart, moment.start)
                roomEnd = max(roomEnd, moment.end)
                // Do not grow into ranges the user removed.
                let scores = source.segmentScores
                var lowIndex = Int(moment.start / Timing.segmentLength) - 1
                while lowIndex >= 0, Double(lowIndex + 1) * Timing.segmentLength > roomStart {
                    if scores[lowIndex] < 0 { roomStart = max(roomStart, Double(lowIndex + 1) * Timing.segmentLength); break }
                    lowIndex -= 1
                }
                var highIndex = Int((moment.end / Timing.segmentLength).rounded(.up))
                while highIndex < scores.count, Double(highIndex) * Timing.segmentLength < roomEnd {
                    if scores[highIndex] < 0 { roomEnd = min(roomEnd, Double(highIndex) * Timing.segmentLength); break }
                    highIndex += 1
                }
                result[index].roomStart = roomStart
                result[index].roomEnd = roomEnd
                let fit = Int(((roomEnd - roomStart) / beatPeriod + 1e-6).rounded(.down))
                result[index].hardMin = videoMinBeats
                result[index].hardMax = max(videoMinBeats, fit)
                result[index].softMin = min(videoSoft.lowerBound, result[index].hardMax)
                result[index].softMax = min(videoSoft.upperBound, result[index].hardMax)
                result[index].softMin = max(result[index].softMin, result[index].hardMin)
                result[index].softMax = max(result[index].softMax, result[index].softMin)
            }
        }

        // Preferred lengths follow the density of the music at each slot's start.
        var beat = 0
        for index in result.indices {
            let time = beatTime(beat)
            let still = sources[result[index].moment.source].isStill
            var pref: Int
            if let density = density(at: time) {
                if still {
                    pref = Int((Double(stillPrefBeats) * (1.25 - 0.5 * density)).rounded())
                } else {
                    let span = Double(videoSoft.upperBound - videoSoft.lowerBound)
                    pref = videoSoft.upperBound - Int((density * span).rounded())
                }
            } else {
                pref = still ? stillPrefBeats : videoPrefBeats
            }
            pref = min(result[index].softMax, max(result[index].softMin, pref))
            result[index].pref = pref
            beat += result[index].k
        }
        return result
    }

    mutating func fit(_ moments: [Moment]) -> (slots: [Slot], shortage: Bool) {
        var slots = moments.map { Slot(moment: $0, k: 1) }
        slots = recomputed(slots)
        for index in slots.indices { slots[index].k = slots[index].pref }
        slots = recomputed(slots)
        for index in slots.indices { slots[index].k = slots[index].pref }

        let tolerance = Timing.tailTolerance
        var shortage = false
        var iterations = 0
        while iterations < 100_000 {
            iterations += 1
            if slots.isEmpty {
                if let added = addMoment(to: slots) {
                    slots = added
                    continue
                }
                shortage = true
                break
            }
            let total = slots.reduce(0) { $0 + $1.k }
            let end = beatTime(total)
            let lastStart = beatTime(total - slots[slots.count - 1].k)
            // Lengths first move towards their preferred beat counts, then moments are added or
            // removed, and only then do lengths stray from the preference (soft, then hard limits).
            if end < target - tolerance {
                if let index = growCandidate(slots, limit: .preferred) {
                    slots[index].k += 1
                } else if let added = addMoment(to: slots) {
                    slots = added
                } else if let index = growCandidate(slots, limit: .soft) ?? growCandidate(slots, limit: .hard) {
                    slots[index].k += 1
                } else if let added = addMoment(to: slots, allowShort: true) {
                    slots = added
                } else {
                    shortage = true
                    break
                }
            } else if lastStart >= target - tolerance {
                if let index = shrinkCandidate(slots, limit: .preferred) {
                    slots[index].k -= 1
                } else if let index = removalCandidate(slots, total: total) {
                    slots.remove(at: index)
                    slots = recomputed(slots)
                } else if let index = shrinkCandidate(slots, limit: .soft) ?? shrinkCandidate(slots, limit: .hard) {
                    slots[index].k -= 1
                } else {
                    break
                }
            } else {
                break
            }
        }
        // Clips that would start after the end are dropped (only reachable with locked clips).
        while slots.count > 1 {
            let total = slots.reduce(0) { $0 + $1.k }
            guard beatTime(total - slots[slots.count - 1].k) >= target - 1e-6 else { break }
            slots.removeLast()
        }
        return (slots, shortage)
    }

    enum Limit {
        case preferred, soft, hard
    }

    func growCandidate(_ slots: [Slot], limit: Limit) -> Int? {
        var best: (index: Int, value: Double)?
        for (index, slot) in slots.enumerated() {
            let ceiling = switch limit {
            case .preferred: slot.pref
            case .soft: slot.softMax
            case .hard: slot.hardMax
            }
            guard slot.k < ceiling else { continue }
            let value = Double(slot.pref - slot.k) + 0.1 * slot.moment.score
            if best == nil || value > best!.value + 1e-9 { best = (index, value) }
        }
        return best?.index
    }

    func shrinkCandidate(_ slots: [Slot], limit: Limit) -> Int? {
        var best: (index: Int, value: Double)?
        for (index, slot) in slots.enumerated() {
            let floor = switch limit {
            case .preferred: slot.pref
            case .soft: slot.softMin
            case .hard: slot.hardMin
            }
            guard slot.k > floor else { continue }
            let value = Double(slot.k - slot.pref) + 0.1 * (1 - slot.moment.score)
            if best == nil || value > best!.value + 1e-9 { best = (index, value) }
        }
        return best?.index
    }

    func removalCandidate(_ slots: [Slot], total: Int) -> Int? {
        var perSource: [Int: Int] = [:]
        for slot in slots { perSource[slot.moment.source, default: 0] += 1 }
        var best: (index: Int, value: Double)?
        for (index, slot) in slots.enumerated() where slot.moment.locked == nil {
            // Removing must not leave the film short.
            guard beatTime(total - slot.k) >= target - Timing.tailTolerance else { continue }
            let shared = perSource[slot.moment.source, default: 0] > 1
            let value = (shared ? 1 : 0) + (1 - slot.moment.score)
            if best == nil || value > best!.value + 1e-9 { best = (index, value) }
        }
        return best?.index
    }

    /// Adds the most valuable unused moment in its chronological place, or returns nil.
    /// `allowShort` also accepts leftover footage shorter than a typical clip.
    mutating func addMoment(to slots: [Slot], allowShort: Bool = false) -> [Slot]? {
        let used = Set(slots.map(\.moment.source))
        var candidates: [(moment: Moment, value: Double)] = []

        // Unused sources first, so that every source contributes before any is used twice.
        for (index, source) in sources.enumerated()
        where !used.contains(index) && !rejectedSources.contains(index) && source.usableDuration > 0 {
            let coverage = source.isSecondary ? 0.0 : 1.0
            if source.isStill {
                candidates.append((Moment(source: index, start: 0, length: expectedStill, score: source.stillScore), coverage + source.quality))
            } else if let window = nextWindow(source, length: expectedVideo, existing: [], spacing: source.item.duration) {
                candidates.append((Moment(source: index, start: window.start, length: window.length, score: window.score), coverage + window.score))
            }
        }
        // Then another moment from a video that still has unused footage.
        for index in used where !sources[index].isStill {
            let source = sources[index]
            let windows = slots.filter { $0.moment.source == index }.map { ($0.moment.start, $0.moment.end) }
            let spacing = source.item.duration / Double(windows.count + 1)
            if let window = nextWindow(source, length: expectedVideo, existing: windows, spacing: spacing, allowShort: allowShort) {
                let coverage = source.isSecondary ? -1.0 : 0.0
                let value = coverage + window.value * pow(0.92, Double(windows.count))
                candidates.append((Moment(source: index, start: window.start, length: window.length, score: window.score), value))
            }
        }

        for candidate in candidates.sorted(by: { $0.value > $1.value }) {
            var newSlots = slots
            let key = orderKey(candidate.moment)
            let position = newSlots.firstIndex { orderKey($0.moment) > key } ?? newSlots.count
            // Skip a moment that would sit next to a near-identical one.
            if position > 0, isNearDuplicate(newSlots[position - 1].moment, candidate.moment) { continue }
            if position < newSlots.count, isNearDuplicate(newSlots[position].moment, candidate.moment) { continue }
            newSlots.insert(Slot(moment: candidate.moment, k: 1), at: position)
            newSlots = recomputed(newSlots)
            newSlots[position].k = newSlots[position].pref
            return newSlots
        }
        return nil
    }

    // MARK: Output

    func quantized(_ time: Double) -> Double {
        let fps = Double(max(1, request.frameRate))
        return (time * fps).rounded() / fps
    }

    mutating func makeEDL(slots: [Slot], shortage: Bool) -> EditDecisionList {
        let total = slots.reduce(0) { $0 + $1.k }
        let filmEnd = shortage ? quantized(beatTime(total)) : quantized(target)

        var clips: [EDLClip] = []
        var beat = 0
        for (position, slot) in slots.enumerated() {
            let start = quantized(beatTime(beat))
            let isLast = position == slots.count - 1
            let end = isLast ? filmEnd : min(filmEnd, quantized(beatTime(beat + slot.k)))
            beat += slot.k
            let duration = end - start
            guard duration > 1e-6 else { continue }
            let source = sources[slot.moment.source]
            let item = source.item

            var sourceStart = 0.0
            var sourceDuration = duration
            var score = source.stillScore
            if !source.isStill {
                let room = slot.roomEnd - slot.roomStart
                if room <= duration + 1e-6 {
                    // Not enough footage in this room: use all of it, slowed down to fit.
                    sourceStart = slot.roomStart
                    sourceDuration = max(Timing.minVideoClip / 2, room)
                } else if let locked = slot.moment.locked {
                    sourceStart = min(max(locked.sourceStart, slot.roomStart), slot.roomEnd - duration)
                } else {
                    let ideal = slot.moment.center - duration / 2
                    sourceStart = min(max(ideal, slot.roomStart), slot.roomEnd - duration)
                }
                sourceStart = max(0, sourceStart)
                sourceDuration = min(sourceDuration, item.duration - sourceStart)
                score = max(0, windowScore(source, start: sourceStart, length: sourceDuration))
            }

            let id = slot.moment.locked?.id ?? EDLClip.makeID(mediaID: item.id, sourceStart: sourceStart)
            clips.append(
                EDLClip(
                    id: id,
                    mediaID: item.id,
                    kind: item.kind,
                    sourceStart: sourceStart,
                    sourceDuration: sourceDuration,
                    timelineStart: start,
                    duration: duration,
                    beats: slot.k,
                    transitionIn: .cut,
                    filter: style.filter,
                    kenBurns: source.isStill ? kenBurns(for: source) : nil,
                    isLocked: slot.moment.locked != nil,
                    score: score,
                    audioVolume: originalSoundVolume(source, start: sourceStart, length: sourceDuration, duration: duration)
                )
            )
        }

        // Transitions are centred on the cut and never longer than ~45 % of either neighbour.
        for index in clips.indices.dropFirst() {
            let weights = style.transitions.map(\.weight)
            let kind = rng.weightedIndex(weights).map { style.transitions[$0].kind } ?? .cut
            guard kind != .cut else { continue }
            let limit = 0.45 * min(clips[index - 1].duration, clips[index].duration)
            let fps = Double(max(1, request.frameRate))
            let length = (min(style.transitionBeats * beatPeriod, style.maxTransitionDuration, limit) * fps).rounded(.down) / fps
            if length >= 2 / Double(max(1, request.frameRate)) {
                clips[index].transitionIn = ClipTransition(kind: kind, duration: length)
            }
        }

        var notices: [PlanNotice] = []
        if shortage || filmEnd < target - Timing.lengthTolerance {
            notices.append(.materialShorterThanTarget(available: filmEnd, target: target))
        }
        let music = request.musicTrackID.map { MusicCue(trackID: $0, segments: request.music.segments) }
        return EditDecisionList(
            targetDuration: target,
            duration: clips.last?.timelineEnd ?? 0,
            style: style.id,
            seed: request.seed,
            frameRate: request.frameRate,
            music: music,
            title: request.title.flatMap { $0.isEmpty ? nil : TextCard(text: $0) },
            endCredit: request.endCredit.flatMap { $0.isEmpty ? nil : TextCard(text: $0) },
            clips: clips,
            notices: notices
        )
    }

    /// Level of a video clip's own sound: none unless asked for, lower when the footage is
    /// quiet (so it does not duck the music), and muted when slowed down.
    func originalSoundVolume(_ source: Source, start: Double, length: Double, duration: Double) -> Double {
        guard request.originalAudio, source.item.kind == .video, source.item.hasAudio else { return 0 }
        guard duration > 0, length / duration > 0.95 else { return 0 }
        let first = max(0, Int(start / Timing.segmentLength))
        let last = min(source.segmentAudio.count, Int(((start + length) / Timing.segmentLength).rounded(.up)))
        let levels = first < last ? source.segmentAudio[first..<last].compactMap { $0 } : []
        guard !levels.isEmpty else { return AudioMixPlan.loudClipVolume }
        let mean = levels.reduce(0, +) / Double(levels.count)
        return mean >= AudioMixPlan.loudnessForDucking ? AudioMixPlan.loudClipVolume : AudioMixPlan.quietClipVolume
    }

    /// A gentle zoom or pan; aims at faces when the analysis found any.
    mutating func kenBurns(for source: Source) -> KenBurns {
        let zoom = max(0, style.kenBurnsZoom)
        var focus = NormalizedPoint.center
        if !source.faces.isEmpty {
            let x = source.faces.map(\.midX).reduce(0, +) / Double(source.faces.count)
            let y = source.faces.map(\.midY).reduce(0, +) / Double(source.faces.count)
            focus = NormalizedPoint(x: min(0.8, max(0.2, x)), y: min(0.8, max(0.2, y)))
        }
        let drift = zoom * 0.5
        switch rng.weightedIndex([3, 2, 1.5, 1.5]) ?? 0 {
        case 0:  // zoom in towards the focus point
            return KenBurns(startScale: 1, endScale: 1 + zoom, startCenter: .center, endCenter: focus)
        case 1:  // zoom out from the focus point
            return KenBurns(startScale: 1 + zoom, endScale: 1, startCenter: focus, endCenter: .center)
        case 2:  // pan left to right
            return KenBurns(
                startScale: 1 + zoom, endScale: 1 + zoom,
                startCenter: NormalizedPoint(x: focus.x - drift, y: focus.y),
                endCenter: NormalizedPoint(x: focus.x + drift, y: focus.y)
            )
        default:  // pan right to left
            return KenBurns(
                startScale: 1 + zoom, endScale: 1 + zoom,
                startCenter: NormalizedPoint(x: focus.x + drift, y: focus.y),
                endCenter: NormalizedPoint(x: focus.x - drift, y: focus.y)
            )
        }
    }
}
