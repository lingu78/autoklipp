import ClipCore
import Foundation
import Observation

/// Steps shown while a film is generated.
enum GenerationStep: Int, CaseIterable, Sendable {
    case analysing
    case selecting
    case rendering

    var title: LocalizedStringResource {
        switch self {
        case .analysing: "Analysing clips…"
        case .selecting: "Choosing the best moments…"
        case .rendering: "Rendering…"
        }
    }
}

/// Everything the planner needs from a project, captured so it can run off the main actor.
struct GenerationInput: Sendable {
    var media: [ImportedMedia]
    var targetDuration: Double
    var style: StyleID
    var track: MusicTrack?
    var seed: UInt64
    var format: AspectFormat
    var lockedClips: [EDLClip] = []
    var exclusions: [Exclusion] = []
}

extension GenerationInput {
    @MainActor
    init(draft: ProjectDraft) {
        self.init(
            media: draft.media,
            targetDuration: draft.targetDuration,
            style: draft.style,
            track: draft.musicTrack,
            seed: draft.seed,
            format: draft.format
        )
    }
}

struct GenerationOutput: Sendable {
    var edl: EditDecisionList
    var built: BuiltComposition
}

/// Runs analysis, planning and composition building, reporting each step.
enum FilmGenerator {
    static func plan(_ input: GenerationInput) -> EditDecisionList {
        let items = input.media.map(\.item)
        let target = input.targetDuration
        let music: MusicLayout
        if let track = input.track {
            music = MusicLayout.make(track: track.info, filmDuration: target)
        } else {
            music = MusicLayout.metronome(bpm: 100, filmDuration: target)
        }
        let request = PlanningRequest(
            media: items,
            targetDuration: target,
            style: .preset(input.style),
            music: music,
            musicTrackID: input.track?.id,
            seed: input.seed,
            lockedClips: input.lockedClips,
            exclusions: input.exclusions
        )
        return Planner.plan(request)
    }

    static func generate(
        _ input: GenerationInput,
        settings: RenderSettings,
        onStep: @escaping @Sendable (GenerationStep) async -> Void
    ) async throws -> GenerationOutput {
        await onStep(.analysing)
        try Task.checkCancellation()
        // Phase 2 adds Vision analysis here; metadata was read during import.

        await onStep(.selecting)
        try Task.checkCancellation()
        let edl = plan(input)
        guard !edl.clips.isEmpty else { throw GenerationError.nothingUsable }

        await onStep(.rendering)
        try Task.checkCancellation()
        let built = try await build(edl, media: input.media, track: input.track, settings: settings)
        return GenerationOutput(edl: edl, built: built)
    }

    static func build(_ edl: EditDecisionList, media: [ImportedMedia], track: MusicTrack?, settings: RenderSettings) async throws
        -> BuiltComposition
    {
        let inputs = RenderInputs(
            edl: edl,
            media: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) }),
            musicURL: track?.url,
            settings: settings
        )
        return try await CompositionBuilder.build(inputs)
    }

    enum GenerationError: LocalizedError {
        case nothingUsable

        var errorDescription: String? {
            String(localized: "None of the chosen photos or videos could be used.")
        }
    }
}
