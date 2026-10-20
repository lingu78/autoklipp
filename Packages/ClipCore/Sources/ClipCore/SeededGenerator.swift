/// SplitMix64: a tiny, fast, deterministic random number generator.
///
/// The planner must produce the same edit for the same seed on every device and OS version,
/// so it never uses `SystemRandomNumberGenerator`.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in `0..<1` built from the top 53 bits, identical on every platform.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// A double in `range`, platform independent.
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }

    /// Picks an index with probability proportional to `weights`; returns nil for no positive weight.
    public mutating func weightedIndex(_ weights: [Double]) -> Int? {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        var pick = nextUnit() * total
        for (index, weight) in weights.enumerated() where weight > 0 {
            pick -= weight
            if pick < 0 { return index }
        }
        return weights.lastIndex { $0 > 0 }
    }
}
