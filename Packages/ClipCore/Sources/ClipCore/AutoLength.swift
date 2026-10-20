import Foundation

/// Suggests a film length from the material ("Auto" in the length step).
///
/// Counts about 2.5 s per still and a third of each video (at most 20 s per video), then rounds
/// to a friendly length and keeps it within what the material can fill.
public enum AutoLength {
    public static let range: ClosedRange<Double> = 15...600

    /// Friendly lengths the suggestion snaps to.
    static let steps: [Double] = [15, 20, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300, 360, 420, 480, 540, 600]

    public static func suggest(for media: [MediaItem]) -> Double {
        let stills = Double(media.filter { $0.kind.isStill }.count) * 2.5
        let videos = media.filter { $0.kind == .video }.reduce(0.0) { $0 + min(20, $1.duration / 3) }
        let raw = stills + videos
        let maximum = max(range.lowerBound, Planner.maximumDuration(of: media))
        let snapped = steps.min { abs($0 - raw) < abs($1 - raw) } ?? range.lowerBound
        let fitting = steps.last { $0 <= maximum } ?? range.lowerBound
        return min(snapped, fitting)
    }
}
