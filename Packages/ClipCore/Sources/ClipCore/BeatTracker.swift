import Foundation

/// Tempo and beat positions from an onset-strength envelope.
///
/// The envelope (how much new sound starts in each short frame, e.g. spectral flux) is computed
/// by the app with Accelerate; this part is plain Swift so it can be tested anywhere.
///
/// Tempo comes from the autocorrelation of the envelope, weighted gently towards ~110 BPM and
/// rewarding periods whose multiples also repeat. Beats are then placed by dynamic programming
/// (Ellis 2007): every beat should sit on a strong onset, one period after the previous beat.
public enum BeatTracker {
    public struct Result: Sendable, Hashable {
        public var bpm: Double
        /// Beat times in seconds, ascending.
        public var beats: [Double]
    }

    /// - Parameters:
    ///   - envelope: Onset strength per frame.
    ///   - frameRate: Frames per second.
    ///   - timeOffset: Time of frame 0, seconds.
    ///   - tempoRange: Tempi considered, BPM.
    ///   - tightness: How strongly beats keep an even spacing (higher is stricter).
    public static func track(
        envelope: [Double],
        frameRate: Double,
        timeOffset: Double = 0,
        tempoRange: ClosedRange<Double> = 60...190,
        tightness: Double = 100
    ) -> Result? {
        guard frameRate > 0, envelope.count > Int(frameRate * 4) else { return nil }
        let onset = normalised(envelope, frameRate: frameRate)
        guard let period = estimatePeriod(onset, frameRate: frameRate, tempoRange: tempoRange) else { return nil }
        let frames = trackBeats(onset, period: period, tightness: tightness)
        guard frames.count >= 4 else { return nil }
        let beats = frames.map { timeOffset + $0 / frameRate }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        return Result(bpm: 60 / median, beats: beats)
    }

    /// Removes the slowly varying level (one-second moving average), keeps the rises, and
    /// scales to unit standard deviation.
    static func normalised(_ envelope: [Double], frameRate: Double) -> [Double] {
        let window = max(1, Int(frameRate))
        var prefix = [Double](repeating: 0, count: envelope.count + 1)
        for (index, value) in envelope.enumerated() { prefix[index + 1] = prefix[index] + value }
        var result = [Double](repeating: 0, count: envelope.count)
        for index in envelope.indices {
            let lower = max(0, index - window / 2)
            let upper = min(envelope.count, index + window / 2 + 1)
            let mean = (prefix[upper] - prefix[lower]) / Double(upper - lower)
            result[index] = max(0, envelope[index] - mean)
        }
        let mean = result.reduce(0, +) / Double(result.count)
        let variance = result.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(result.count)
        let deviation = variance.squareRoot()
        guard deviation > 1e-12 else { return result }
        return result.map { $0 / deviation }
    }

    /// Beat period in frames (fractional).
    static func estimatePeriod(_ onset: [Double], frameRate: Double, tempoRange: ClosedRange<Double>) -> Double? {
        let minLag = max(2, Int((60 * frameRate / tempoRange.upperBound).rounded(.down)))
        let maxLag = Int((60 * frameRate / tempoRange.lowerBound).rounded(.up))
        guard maxLag * 3 < onset.count else { return nil }

        func autocorrelation(_ lag: Int) -> Double {
            guard lag > 0, lag < onset.count else { return 0 }
            var sum = 0.0
            for index in 0..<(onset.count - lag) { sum += onset[index] * onset[index + lag] }
            return sum / Double(onset.count - lag)
        }
        var cache: [Int: Double] = [:]
        func ac(_ lag: Int) -> Double {
            if let value = cache[lag] { return value }
            let value = autocorrelation(lag)
            cache[lag] = value
            return value
        }

        var scores: [(lag: Int, score: Double)] = []
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let octaves = log2(bpm / 110) / 1.3
            let prior = exp(-0.5 * octaves * octaves)
            let periodic = ac(lag) + 0.5 * ac(2 * lag) + 0.25 * ac(3 * lag)
            scores.append((lag, prior * periodic))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        // Parabolic refinement around the best whole lag.
        let previous = ac(best.lag - 1)
        let current = ac(best.lag)
        let next = ac(best.lag + 1)
        let denominator = previous - 2 * current + next
        var shift = 0.0
        if abs(denominator) > 1e-12 { shift = 0.5 * (previous - next) / denominator }
        return Double(best.lag) + min(0.5, max(-0.5, shift))
    }

    /// Frame positions of beats, by dynamic programming over the onset envelope.
    static func trackBeats(_ onset: [Double], period: Double, tightness: Double) -> [Double] {
        let count = onset.count
        var score = [Double](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        let earliest = Int((2 * period).rounded())
        let latest = max(1, Int((period / 2).rounded()))
        for frame in 0..<count {
            var bestScore = -Double.infinity
            var bestPrevious = -1
            let lower = max(0, frame - earliest)
            let upper = frame - latest
            if upper >= lower {
                for previous in lower...upper {
                    let ratio = Double(frame - previous) / period
                    let penalty = tightness * pow(log(ratio), 2)
                    let candidate = score[previous] - penalty
                    if candidate > bestScore {
                        bestScore = candidate
                        bestPrevious = previous
                    }
                }
            }
            if bestPrevious >= 0, bestScore > 0 {
                score[frame] = onset[frame] + bestScore
                backlink[frame] = bestPrevious
            } else {
                score[frame] = onset[frame]
            }
        }

        // Start from the best-scoring frame within the last period, then follow the links back.
        let tailStart = max(0, count - Int(period.rounded(.up)))
        guard let end = (tailStart..<count).max(by: { score[$0] < score[$1] }) else { return [] }
        var frames: [Int] = []
        var cursor = end
        while cursor >= 0 {
            frames.append(cursor)
            cursor = backlink[cursor]
        }
        frames.reverse()

        // Refine each beat to the strongest onset within a couple of frames.
        return frames.map { frame in
            let lower = max(0, frame - 2)
            let upper = min(count - 1, frame + 2)
            let peak = (lower...upper).max { onset[$0] < onset[$1] } ?? frame
            guard peak > 0, peak < count - 1 else { return Double(peak) }
            let previous = onset[peak - 1]
            let current = onset[peak]
            let next = onset[peak + 1]
            let denominator = previous - 2 * current + next
            guard abs(denominator) > 1e-12 else { return Double(peak) }
            return Double(peak) + min(0.5, max(-0.5, 0.5 * (previous - next) / denominator))
        }
    }

    /// Song sections from loudness: bars are grouped in eights and each group gets its relative
    /// energy, so long films can cut faster in loud parts.
    public static func sections(loudness: [Double], loudnessRate: Double, beats: [Double], barsPerSection: Int = 8)
        -> [MusicSection]
    {
        guard beats.count > 4, loudnessRate > 0, !loudness.isEmpty else { return [] }
        let step = 4 * barsPerSection
        var sections: [MusicSection] = []
        var index = 0
        while index < beats.count - 1 {
            let start = beats[index]
            let endIndex = min(beats.count - 1, index + step)
            let end = beats[endIndex]
            let lower = max(0, Int(start * loudnessRate))
            let upper = min(loudness.count, max(lower + 1, Int(end * loudnessRate)))
            let slice = loudness[lower..<upper]
            let mean = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
            sections.append(MusicSection(start: start, end: end, energy: mean))
            index = endIndex
        }
        let energies = sections.map(\.energy)
        guard let low = energies.min(), let high = energies.max(), high - low > 1e-9 else {
            return sections.map { MusicSection(start: $0.start, end: $0.end, energy: 0.5) }
        }
        return sections.map { MusicSection(start: $0.start, end: $0.end, energy: ($0.energy - low) / (high - low)) }
    }
}
