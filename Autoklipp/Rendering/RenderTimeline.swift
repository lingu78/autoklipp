import ClipCore
import CoreMedia
import Foundation
import ImageIO

/// What the compositor draws, derived from the clip list. Immutable and safe to share.
struct RenderTimeline: Sendable {
    struct Layer: Sendable {
        enum Content: Sendable {
            /// Frames come from a composition track; `orientation` turns them upright.
            case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
            case still(url: URL, pixelWidth: Int, pixelHeight: Int)
        }

        var content: Content
        var mediaID: String
        var start: Double
        var end: Double
        var transitionIn: ClipTransition
        var filter: FilterKind
        var kenBurns: KenBurns?
    }

    var renderSize: CGSize
    var duration: Double
    var layers: [Layer]
    /// Text over the first and last seconds (F14).
    var title: TextCard?
    var endCredit: TextCard?

    /// Index of the layer that owns `time` (the latest layer starting at or before it).
    func layerIndex(at time: Double) -> Int? {
        guard !layers.isEmpty else { return nil }
        var low = 0
        var high = layers.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if layers[middle].start <= time + 1e-9 { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

extension CGImagePropertyOrientation {
    /// The EXIF orientation matching a video track's preferred transform.
    init(videoTransform transform: CGAffineTransform) {
        let quarterTurns = Int((atan2(Double(transform.b), Double(transform.a)) / (Double.pi / 2)).rounded())
        switch (quarterTurns + 4) % 4 {
        case 1: self = .right
        case 2: self = .down
        case 3: self = .left
        default: self = .up
        }
    }
}
