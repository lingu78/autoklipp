import Foundation

/// Raw measurements for one 0.5 s video segment or one still, produced by the app's
/// Vision/AVFoundation analysis. Every value is normalised so the scorer can stay platform free.
public struct FrameMetrics: Codable, Sendable, Hashable {
    /// Sharpness 0...1 (1 = crisp, below ~0.25 = blurry).
    public var sharpness: Double
    /// Number of detected faces.
    public var faceCount: Int
    /// Best face capture quality 0...1 (0 without faces).
    public var faceQuality: Double
    /// Subject motion 0...1 (0 = static scene).
    public var motion: Double
    /// Camera shake 0...1 (0 = steady).
    public var shake: Double
    /// Mean luminance 0...1.
    public var exposure: Double
    /// Loudness 0...1 (0 = silence); nil for stills and videos without sound.
    public var audioLevel: Double?
    /// Aesthetic quality 0...1, when the platform provides one (stills).
    public var aesthetics: Double?

    public init(
        sharpness: Double = 0.6,
        faceCount: Int = 0,
        faceQuality: Double = 0,
        motion: Double = 0.3,
        shake: Double = 0.1,
        exposure: Double = 0.5,
        audioLevel: Double? = nil,
        aesthetics: Double? = nil
    ) {
        self.sharpness = sharpness
        self.faceCount = faceCount
        self.faceQuality = faceQuality
        self.motion = motion
        self.shake = shake
        self.exposure = exposure
        self.audioLevel = audioLevel
        self.aesthetics = aesthetics
    }

    /// Metrics used when nothing has been analysed: everything average.
    public static let neutral = FrameMetrics()
}

/// One analysed slice of a video.
public struct SegmentAnalysis: Codable, Sendable, Hashable {
    public var start: Double
    public var duration: Double
    public var metrics: FrameMetrics
    /// Small colour-layout vector used to spot near-identical shots.
    public var signature: [Float]?

    public init(start: Double, duration: Double, metrics: FrameMetrics, signature: [Float]? = nil) {
        self.start = start
        self.duration = duration
        self.metrics = metrics
        self.signature = signature
    }
}

/// Everything the planner knows about one media item beyond its metadata.
public struct MediaAnalysis: Codable, Sendable, Hashable {
    public var mediaID: String
    /// Consecutive segments covering the video; empty for stills.
    public var segments: [SegmentAnalysis]
    /// Metrics for a still.
    public var still: FrameMetrics?
    public var stillSignature: [Float]?
    /// Normalised face boxes for a still (origin top left), used to aim Ken Burns.
    public var faceRegions: [NormalizedRect]
    /// Classification labels, most confident first (e.g. "child", "beach").
    public var labels: [String]

    public init(
        mediaID: String,
        segments: [SegmentAnalysis] = [],
        still: FrameMetrics? = nil,
        stillSignature: [Float]? = nil,
        faceRegions: [NormalizedRect] = [],
        labels: [String] = []
    ) {
        self.mediaID = mediaID
        self.segments = segments
        self.still = still
        self.stillSignature = stillSignature
        self.faceRegions = faceRegions
        self.labels = labels
    }
}

/// A rectangle in normalised image coordinates (0...1, origin top left).
public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// Distance between two colour-layout signatures (root mean square difference).
/// Returns nil when either is missing or they have different lengths.
public func signatureDistance(_ lhs: [Float]?, _ rhs: [Float]?) -> Double? {
    guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else { return nil }
    var sum: Double = 0
    for index in lhs.indices {
        let diff = Double(lhs[index] - rhs[index])
        sum += diff * diff
    }
    return (sum / Double(lhs.count)).squareRoot()
}
