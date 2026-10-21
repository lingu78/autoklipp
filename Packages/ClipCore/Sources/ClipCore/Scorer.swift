import Foundation

/// Turns raw frame metrics into a single 0...1 quality score.
///
/// Weighted average of sharpness, faces, motion ("some is good, a lot is bad"), steadiness,
/// exposure and loudness, followed by hard penalties for blur, shake and very dark or blown-out
/// frames so that such segments lose against almost anything else.
public enum Scorer {
    public struct Weights: Sendable, Hashable {
        public var sharpness: Double
        public var faces: Double
        public var motion: Double
        public var steadiness: Double
        public var exposure: Double
        public var audio: Double
        public var aesthetics: Double

        public init(
            sharpness: Double, faces: Double, motion: Double, steadiness: Double,
            exposure: Double, audio: Double, aesthetics: Double
        ) {
            self.sharpness = sharpness
            self.faces = faces
            self.motion = motion
            self.steadiness = steadiness
            self.exposure = exposure
            self.audio = audio
            self.aesthetics = aesthetics
        }

        public static let video = Weights(
            sharpness: 0.28, faces: 0.24, motion: 0.14, steadiness: 0.16,
            exposure: 0.10, audio: 0.08, aesthetics: 0
        )
        public static let still = Weights(
            sharpness: 0.30, faces: 0.30, motion: 0, steadiness: 0,
            exposure: 0.15, audio: 0, aesthetics: 0.25
        )
    }

    /// Sharpness below this counts as blurry.
    public static let blurThreshold = 0.25
    /// Shake above this counts as shaky.
    public static let shakeThreshold = 0.6

    public static func score(_ metrics: FrameMetrics, weights: Weights = .video) -> Double {
        let sharp = clamp01(metrics.sharpness)
        let faces = metrics.faceCount > 0 ? 0.6 + 0.4 * clamp01(metrics.faceQuality) : 0
        let motion = motionTerm(clamp01(metrics.motion))
        let steady = 1 - clamp01(metrics.shake)
        let exposure = 1 - min(1, abs(clamp01(metrics.exposure) - 0.5) * 2)
        let audio = metrics.audioLevel.map(clamp01) ?? 0.5
        let aesthetics = metrics.aesthetics.map(clamp01) ?? 0.5

        var total = 0.0
        var weightSum = 0.0
        func add(_ value: Double, _ weight: Double) {
            total += value * weight
            weightSum += weight
        }
        add(sharp, weights.sharpness)
        add(faces, weights.faces)
        add(motion, weights.motion)
        add(steady, weights.steadiness)
        add(exposure, weights.exposure)
        add(audio, weights.audio)
        add(aesthetics, weights.aesthetics)
        guard weightSum > 0 else { return 0 }

        var score = total / weightSum
        if sharp < blurThreshold { score *= 0.35 }
        if clamp01(metrics.shake) > shakeThreshold { score *= 0.35 }
        if metrics.exposure < 0.06 || metrics.exposure > 0.96 { score *= 0.5 }
        return clamp01(score)
    }

    /// Score for a still photo or Live Photo.
    public static func stillScore(_ metrics: FrameMetrics) -> Double {
        score(metrics, weights: .still)
    }

    /// Static scenes are fine, lively ones are better, frantic ones are worse.
    static func motionTerm(_ motion: Double) -> Double {
        if motion <= 0.3 { return 0.55 + 0.45 * (motion / 0.3) }
        return max(0.2, 1 - (motion - 0.3) * (0.8 / 0.7))
    }

    static func clamp01(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
