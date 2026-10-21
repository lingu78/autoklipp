import Foundation

/// A point in normalised image coordinates (0...1, origin top left).
public struct NormalizedPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

/// Slow zoom and pan over a still. Scales are relative to the aspect-fill framing (1 = no zoom);
/// centres are the point of the image kept in the middle of the frame.
public struct KenBurns: Codable, Sendable, Hashable {
    public var startScale: Double
    public var endScale: Double
    public var startCenter: NormalizedPoint
    public var endCenter: NormalizedPoint

    public init(startScale: Double, endScale: Double, startCenter: NormalizedPoint, endCenter: NormalizedPoint) {
        self.startScale = startScale
        self.endScale = endScale
        self.startCenter = startCenter
        self.endCenter = endCenter
    }

    public static let none = KenBurns(startScale: 1, endScale: 1, startCenter: .center, endCenter: .center)
}

/// How a clip enters: the transition is centred on the cut, half before and half after it.
public struct ClipTransition: Codable, Sendable, Hashable {
    public var kind: TransitionKind
    public var duration: Double

    public init(kind: TransitionKind, duration: Double) {
        self.kind = kind
        self.duration = kind == .cut ? 0 : max(0, duration)
    }

    public static let cut = ClipTransition(kind: .cut, duration: 0)
}

/// One entry in the edit: which piece of which media plays where.
public struct EDLClip: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var mediaID: String
    public var kind: MediaKind
    /// In-point in the source, seconds (0 for stills).
    public var sourceStart: Double
    /// Length of source consumed; differs from `duration` only when a short video is slowed down.
    public var sourceDuration: Double
    /// Start on the film timeline.
    public var timelineStart: Double
    /// Length on the film timeline.
    public var duration: Double
    /// Beats the slot spans (before the final trim).
    public var beats: Int
    public var transitionIn: ClipTransition
    public var filter: FilterKind
    public var kenBurns: KenBurns?
    public var isLocked: Bool
    public var score: Double
    /// Original sound level 0...1 for videos.
    public var audioVolume: Double

    public init(
        id: String,
        mediaID: String,
        kind: MediaKind,
        sourceStart: Double,
        sourceDuration: Double,
        timelineStart: Double,
        duration: Double,
        beats: Int,
        transitionIn: ClipTransition = .cut,
        filter: FilterKind = .none,
        kenBurns: KenBurns? = nil,
        isLocked: Bool = false,
        score: Double = 0.5,
        audioVolume: Double = 0
    ) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.timelineStart = timelineStart
        self.duration = duration
        self.beats = beats
        self.transitionIn = transitionIn
        self.filter = filter
        self.kenBurns = kenBurns
        self.isLocked = isLocked
        self.score = score
        self.audioVolume = audioVolume
    }

    public var timelineEnd: Double { timelineStart + duration }
    public var sourceEnd: Double { sourceStart + sourceDuration }
    /// Playback speed (1 = real time, below 1 = slow motion).
    public var playbackRate: Double { duration > 0 ? sourceDuration / duration : 1 }

    /// Identity of a moment, stable across regenerations as long as the in-point is unchanged.
    public static func makeID(mediaID: String, sourceStart: Double) -> String {
        "\(mediaID)@\(Int((sourceStart * 1000).rounded()))"
    }
}

/// A line of text over the start or the end of the film.
public struct TextCard: Codable, Sendable, Hashable {
    public var text: String
    public var duration: Double

    public init(text: String, duration: Double = 3) {
        self.text = text
        self.duration = duration
    }
}

/// Something the user should be told about the result.
public enum PlanNotice: Codable, Sendable, Hashable {
    /// There was not enough material for the requested length; the film is `available` long.
    case materialShorterThanTarget(available: Double, target: Double)
}

/// The song under the film and how it is laid out.
public struct MusicCue: Codable, Sendable, Hashable {
    public var trackID: String
    public var segments: [MusicSegment]
    /// Fade at the end of the film, seconds.
    public var fadeOut: Double
    public var volume: Double

    public init(trackID: String, segments: [MusicSegment], fadeOut: Double = 2, volume: Double = 1) {
        self.trackID = trackID
        self.segments = segments
        self.fadeOut = fadeOut
        self.volume = volume
    }
}

/// The clip list. Everything the renderer needs, and nothing it has to decide itself.
public struct EditDecisionList: Codable, Sendable, Hashable {
    public static let formatVersion = 1

    public var version: Int
    public var targetDuration: Double
    /// Actual length; equals the target unless the material ran out, or the locked clips need
    /// more than the target (they always keep their place). It can also be a fraction of a second
    /// off when the last clip could not otherwise be shown within its limits.
    public var duration: Double
    public var style: StyleID
    public var seed: UInt64
    public var frameRate: Int
    public var music: MusicCue?
    public var title: TextCard?
    public var endCredit: TextCard?
    public var clips: [EDLClip]
    public var notices: [PlanNotice]

    public init(
        targetDuration: Double,
        duration: Double,
        style: StyleID,
        seed: UInt64,
        frameRate: Int = 30,
        music: MusicCue? = nil,
        title: TextCard? = nil,
        endCredit: TextCard? = nil,
        clips: [EDLClip],
        notices: [PlanNotice] = []
    ) {
        self.version = Self.formatVersion
        self.targetDuration = targetDuration
        self.duration = duration
        self.style = style
        self.seed = seed
        self.frameRate = frameRate
        self.music = music
        self.title = title
        self.endCredit = endCredit
        self.clips = clips
        self.notices = notices
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> EditDecisionList {
        try JSONDecoder().decode(EditDecisionList.self, from: data)
    }

    /// Media referenced by the clips, in first-use order.
    public var mediaIDs: [String] {
        var seen = Set<String>()
        return clips.compactMap { seen.insert($0.mediaID).inserted ? $0.mediaID : nil }
    }
}
