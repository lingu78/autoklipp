import ClipCore
import Foundation
import Observation

/// Steps shown while a film is generated.
enum GenerationStep: Int, CaseIterable, Sendable {
    case analysing
    case directing
    case selecting
    case rendering

    var title: LocalizedStringResource {
        switch self {
        case .analysing: "Analysing clips…"
        case .directing: "Following your description…"
        case .selecting: "Choosing the best moments…"
        case .rendering: "Rendering…"
        }
    }

    /// The steps shown for a run, with or without a description to follow.
    static func steps(directed: Bool) -> [GenerationStep] {
        directed ? allCases : allCases.filter { $0 != .directing }
    }
}

/// Everything the planner needs from a project, captured so it can run off the main actor.
struct GenerationInput: Sendable {
    var media: [ImportedMedia]
    var analyses: [String: MediaAnalysis] = [:]
    var targetDuration: Double
    var style: StyleID
    var song: SongChoice?
    var seed: UInt64
    var format: AspectFormat
    var originalAudio = false
    var lockedClips: [EDLClip] = []
    var exclusions: [Exclusion] = []
    var title = ""
    var endCredit = ""
    /// The user's description of the film (F16); empty when none.
    var instruction = ""
    /// A plan from an earlier run for the same description and material.
    var directorPlan: DirectorPlan?
    /// Let the director's suggested style replace the current one.
    var styleFollowsDirector = false
    /// The user has not picked a song, so a new style brings its own.
    var songFollowsStyle = false
    /// The user has not written or removed a title, so the director's title is used.
    var titleFollowsDirector = false
    /// The user's clip order, kept as it is and only re-timed to the music.
    var arrangement: [EDLClip]?
}

extension GenerationInput {
    @MainActor
    init(draft: ProjectDraft) {
        self.init(
            media: draft.media,
            analyses: draft.analyses,
            targetDuration: draft.targetDuration,
            style: draft.style,
            song: draft.song,
            seed: draft.seed,
            format: draft.format,
            originalAudio: draft.originalAudio,
            lockedClips: draft.lockedClips,
            exclusions: draft.exclusions,
            title: draft.title,
            endCredit: draft.endCredit,
            instruction: draft.instructionInEffect,
            directorPlan: draft.directorPlan,
            styleFollowsDirector: !draft.styleChosenByUser,
            songFollowsStyle: !draft.musicChosenByUser,
            titleFollowsDirector: !draft.titleChosenByUser,
            arrangement: draft.userArrangement
        )
    }

    /// Takes the director's suggestions the user has left open: the style, with its song until
    /// the user picks one (as `ProjectDraft.select(style:)` does), and the title.
    mutating func follow(_ plan: DirectorPlan?) {
        if styleFollowsDirector, let suggested = plan?.suggestedStyle, suggested != style {
            style = suggested
            if songFollowsStyle, let suggestion = MusicCatalog.suggestion(for: suggested)?.choice { song = suggestion }
            // The clips carry the old style's transitions.
            arrangement = nil
        }
        if titleFollowsDirector { title = plan?.title ?? "" }
    }
}

struct GenerationOutput: Sendable {
    var edl: EditDecisionList
    var built: BuiltComposition
    /// Analyses including the ones computed in this run, for the project to keep.
    var analyses: [String: MediaAnalysis]
    /// The director's plan, when a description was followed.
    var directorPlan: DirectorPlan?
    /// Style used, which the director may have chosen.
    var style: StyleID
    /// The description could not be followed; the film was made without it.
    var directorFailed = false
    /// The user's clip order was kept.
    var keptArrangement = false
}

/// Runs analysis, planning and composition building, reporting each step.
enum FilmGenerator {
    static func plan(_ input: GenerationInput) -> EditDecisionList {
        Planner.plan(planningRequest(input))
    }

    /// The planner's view of a project; also the base for clip-strip edits.
    static func planningRequest(_ input: GenerationInput) -> PlanningRequest {
        let target = input.targetDuration
        let music: MusicLayout
        if let song = input.song {
            music = MusicLayout.make(track: song.info, filmDuration: target)
        } else {
            music = MusicLayout.metronome(bpm: 100, filmDuration: target)
        }
        return PlanningRequest(
            media: input.media.map(\.item),
            analyses: input.analyses,
            targetDuration: target,
            style: .preset(input.style),
            music: music,
            musicTrackID: input.song?.id,
            seed: input.seed,
            lockedClips: input.lockedClips,
            arrangement: input.arrangement,
            exclusions: input.exclusions,
            director: input.directorPlan,
            title: input.title,
            endCredit: input.endCredit,
            originalAudio: input.originalAudio
        )
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

        var directorFailed = false
        if !input.instruction.isEmpty, input.directorPlan == nil {
            await onProgress(.directing, 0)
            // A new description chooses the clips again.
            input.arrangement = nil
            do {
                input.directorPlan = try await FilmDirector.plan(
                    instruction: input.instruction, media: input.media.map(\.item), analyses: input.analyses
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The model is a bonus: without its plan the film is made the usual way.
                directorFailed = true
            }
            if input.directorPlan == nil { directorFailed = true }
        }
        // Before planning, so the clips are timed to the song the film will have.
        input.follow(input.directorPlan)

        await onProgress(.selecting, 0)
        try Task.checkCancellation()
        let edl = plan(input)
        guard !edl.clips.isEmpty else { throw GenerationError.nothingUsable }

        await onProgress(.rendering, 0)
        try Task.checkCancellation()
        let built = try await build(edl, media: input.media, song: input.song, settings: settings)
        return GenerationOutput(
            edl: edl, built: built, analyses: input.analyses, directorPlan: input.directorPlan,
            style: input.style, directorFailed: directorFailed, keptArrangement: input.arrangement != nil
        )
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

    static func build(_ edl: EditDecisionList, media: [ImportedMedia], song: SongChoice?, settings: RenderSettings) async throws
        -> BuiltComposition
    {
        let inputs = RenderInputs(
            edl: edl,
            media: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) }),
            musicURL: song?.url,
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
