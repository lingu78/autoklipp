import Foundation

/// A change made in the clip strip under the preview.
public enum ClipEdit: Codable, Sendable, Hashable {
    /// Moves a clip so that it ends up at `index` in the list.
    case move(clipID: String, toIndex: Int)
    /// Removes a clip; its footage is not used again.
    case remove(clipID: String)
    /// Locks or unlocks a clip; locked clips survive every regeneration.
    case setLocked(clipID: String, Bool)
}

extension Planner {
    /// Applies an edit to a clip list and re-times the film on the beat.
    ///
    /// The other clips keep their order, in-points and look; only lengths change so the film
    /// still ends on the target. Returns the new list and the exclusions to keep for later
    /// regenerations (`request.exclusions` plus anything removed now).
    public static func apply(_ edit: ClipEdit, to edl: EditDecisionList, request: PlanningRequest)
        -> (edl: EditDecisionList, exclusions: [Exclusion])
    {
        var clips = edl.clips
        var request = request
        switch edit {
        case let .setLocked(clipID, locked):
            var result = edl
            if let index = result.clips.firstIndex(where: { $0.id == clipID }) {
                result.clips[index].isLocked = locked
            }
            return (result, request.exclusions)
        case let .move(clipID, toIndex):
            guard let from = clips.firstIndex(where: { $0.id == clipID }) else { return (edl, request.exclusions) }
            let clip = clips.remove(at: from)
            clips.insert(clip, at: min(max(0, toIndex), clips.count))
        case let .remove(clipID):
            guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return (edl, request.exclusions) }
            let clip = clips.remove(at: index)
            let exclusion = clip.kind.isStill
                ? Exclusion(mediaID: clip.mediaID)
                : Exclusion(mediaID: clip.mediaID, start: clip.sourceStart, end: clip.sourceEnd)
            request.exclusions.append(exclusion)
        }
        request.arrangement = clips
        request.lockedClips = []
        request.seed = edl.seed
        request.title = edl.title?.text
        request.endCredit = edl.endCredit?.text
        return (plan(request), request.exclusions)
    }
}
