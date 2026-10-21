import Foundation

/// The visual styles the user can pick. Each controls pace, transitions and colour.
public enum StyleID: String, Codable, Sendable, Hashable, CaseIterable {
    case calm
    case energetic
    case nostalgic
    case travel
    case cinematic
}

public enum TransitionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case cut
    case crossfade
    case dipToBlack
    case dipToWhite
    case zoomIn
    case slideLeft
    case flash
}

public enum FilterKind: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case soft
    case vivid
    case vintage
    case warm
    case cinematic
}

public struct WeightedTransition: Sendable, Hashable {
    public var kind: TransitionKind
    public var weight: Double

    public init(_ kind: TransitionKind, _ weight: Double) {
        self.kind = kind
        self.weight = weight
    }
}

/// Everything a style decides. Durations are in seconds unless the name says beats.
public struct StyleParameters: Sendable, Hashable {
    public var id: StyleID
    /// How many beats a video clip may last.
    public var beatsPerClip: ClosedRange<Int>
    /// The clip length this style aims for when the density is neutral.
    public var typicalClipDuration: Double
    /// Preferred still duration; always kept within `Timing.stillRange`.
    public var stillDuration: Double
    public var transitions: [WeightedTransition]
    /// Transition length in beats, capped by `maxTransitionDuration`.
    public var transitionBeats: Double
    public var maxTransitionDuration: Double
    public var filter: FilterKind
    /// Ken Burns zoom amount over one still (0.1 = 10 %).
    public var kenBurnsZoom: Double
    /// Tempo range that suits the style, used to suggest music.
    public var preferredTempo: ClosedRange<Double>
    /// How strongly a new seed may reshuffle the choice of moments (0...1).
    public var variety: Double

    public init(
        id: StyleID,
        beatsPerClip: ClosedRange<Int>,
        typicalClipDuration: Double,
        stillDuration: Double,
        transitions: [WeightedTransition],
        transitionBeats: Double,
        maxTransitionDuration: Double,
        filter: FilterKind,
        kenBurnsZoom: Double,
        preferredTempo: ClosedRange<Double>,
        variety: Double = 0.15
    ) {
        self.id = id
        self.beatsPerClip = beatsPerClip
        self.typicalClipDuration = typicalClipDuration
        self.stillDuration = stillDuration
        self.transitions = transitions
        self.transitionBeats = transitionBeats
        self.maxTransitionDuration = maxTransitionDuration
        self.filter = filter
        self.kenBurnsZoom = kenBurnsZoom
        self.preferredTempo = preferredTempo
        self.variety = variety
    }

    public static func preset(_ id: StyleID) -> StyleParameters {
        switch id {
        case .calm:
            StyleParameters(
                id: id, beatsPerClip: 4...8, typicalClipDuration: 3.5, stillDuration: 3.5,
                transitions: [WeightedTransition(.crossfade, 1)],
                transitionBeats: 1, maxTransitionDuration: 1.0, filter: .soft, kenBurnsZoom: 0.08,
                preferredTempo: 60...92
            )
        case .energetic:
            StyleParameters(
                id: id, beatsPerClip: 1...2, typicalClipDuration: 1.0, stillDuration: 1.6,
                transitions: [
                    WeightedTransition(.cut, 0.7), WeightedTransition(.zoomIn, 0.2),
                    WeightedTransition(.flash, 0.1),
                ],
                transitionBeats: 0.5, maxTransitionDuration: 0.3, filter: .vivid, kenBurnsZoom: 0.14,
                preferredTempo: 116...140
            )
        case .nostalgic:
            StyleParameters(
                id: id, beatsPerClip: 2...4, typicalClipDuration: 2.5, stillDuration: 3.0,
                transitions: [WeightedTransition(.crossfade, 0.6), WeightedTransition(.dipToWhite, 0.4)],
                transitionBeats: 1, maxTransitionDuration: 0.8, filter: .vintage, kenBurnsZoom: 0.06,
                preferredTempo: 76...100
            )
        case .travel:
            StyleParameters(
                id: id, beatsPerClip: 2...4, typicalClipDuration: 2.0, stillDuration: 2.5,
                transitions: [
                    WeightedTransition(.cut, 0.4), WeightedTransition(.slideLeft, 0.3),
                    WeightedTransition(.crossfade, 0.3),
                ],
                transitionBeats: 0.5, maxTransitionDuration: 0.5, filter: .warm, kenBurnsZoom: 0.10,
                preferredTempo: 94...118
            )
        case .cinematic:
            StyleParameters(
                id: id, beatsPerClip: 2...6, typicalClipDuration: 3.0, stillDuration: 3.0,
                transitions: [WeightedTransition(.crossfade, 0.5), WeightedTransition(.dipToBlack, 0.5)],
                transitionBeats: 1, maxTransitionDuration: 0.9, filter: .cinematic, kenBurnsZoom: 0.07,
                preferredTempo: 68...100
            )
        }
    }
}
