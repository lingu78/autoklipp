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
    var analyses: [String: MediaAnalysis] = [:]
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
            analyses: draft.analyses,
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
    /// Analyses including the ones computed in this run, for the project to keep.
    var analyses: [String: MediaAnalysis]
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
            analyses: input.analyses,
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
        onProgress: @escaping @Sendable (GenerationStep, Double) async -> Void
    ) async throws -> GenerationOutput {
        var input = input
        await onProgress(.analysing, 0)
        input.analyses = try await analyse(input.media, known: input.analyses) { fraction in
            await onProgress(.analysing, fraction)
        }

        await onProgress(.selecting, 0)
        try Task.checkCancellation()
        let edl = plan(input)
        guard !edl.clips.isEmpty else { throw GenerationError.nothingUsable }

        await onProgress(.rendering, 0)
        try Task.checkCancellation()
        let built = try await build(edl, media: input.media, track: input.track, settings: settings)
        return GenerationOutput(edl: edl, built: built, analyses: input.analyses)
    }

    /// Analyses media not analysed before, a few at a time. A file that cannot be analysed
    /// simply gets neutral scores.
    static func analyse(
        _ media: [ImportedMedia],
        known: [String: MediaAnalysis],
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> [String: MediaAnalysis] {
        var analyses = known
        let pending = media.filter { known[$0.id] == nil }
        guard !pending.isEmpty else { return analyses }
        // Videos dominate the work; weigh progress by duration.
        let weight = { (item: ImportedMedia) in item.item.kind == .video ? max(1, item.item.duration) : 1 }
        let total = pending.reduce(0) { $0 + weight($1) }
        var done = 0.0
        try await withThrowingTaskGroup(of: (ImportedMedia, MediaAnalysis?).self) { group in
            var next = 0
            func enqueue() {
                guard next < pending.count else { return }
                let item = pending[next]
                next += 1
                group.addTask { (item, try? await MediaAnalyzer.analyse(item)) }
            }
            for _ in 0..<3 { enqueue() }
            while let finished = try await group.next() {
                let (item, analysis) = finished
                try Task.checkCancellation()
                if let analysis { analyses[item.id] = analysis }
                done += weight(item)
                await onProgress(min(1, done / total))
                enqueue()
            }
        }
        return analyses
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
