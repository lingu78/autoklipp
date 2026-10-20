import AVFoundation
import ClipCore
import Foundation
import Observation
import SwiftData
import UIKit

/// Steps of the main flow.
enum Route: Hashable {
    case media
    case length
    case style
    case generate
    case preview
}

/// Root state: saved projects, the project being made and where in the flow the user is.
@MainActor
@Observable
final class AppModel {
    var path: [Route] = []
    private(set) var draft: ProjectDraft
    /// The film currently shown in the preview.
    var preview: PreviewSession?
    let container: ModelContainer
    /// How long the last clip-strip edit took until the new preview was ready.
    private(set) var lastEditDuration: Duration?
    var message: String?
    /// Apple Intelligence can direct films on this device (checked at start and on return).
    private(set) var directorAvailable = FilmDirector.isAvailable

    func refreshDirectorAvailability() {
        directorAvailable = FilmDirector.isAvailable
    }

    init(inMemory: Bool = false) {
        draft = ProjectDraft()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        if let container = try? ModelContainer(for: SavedProject.self, configurations: configuration) {
            self.container = container
        } else {
            // A broken store must not stop the app; projects are then kept for this session only.
            self.container = try! ModelContainer(for: SavedProject.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Projects

    func newProject() {
        closePreview()
        draft = ProjectDraft()
        path = [.media]
    }

    /// Throws away the current project, including its copied media and any saved copy.
    func startOver() {
        let id = draft.id
        let storage = draft.storage
        closePreview()
        if let saved = savedProject(id: id) { context.delete(saved) }
        try? context.save()
        draft = ProjectDraft()
        path = [.media]
        Task.detached { storage.removeAll() }
    }

    func open(_ project: SavedProject) {
        guard let snapshot = project.snapshot else {
            message = String(localized: "This film could not be opened.")
            return
        }
        closePreview()
        draft = ProjectDraft(id: project.id, restoring: snapshot)
        path = draft.edl == nil ? [.media] : [.preview]
    }

    func delete(_ project: SavedProject) {
        let storage = ProjectStorage(projectID: project.id)
        if draft.id == project.id {
            closePreview()
            draft = ProjectDraft()
            path = []
        }
        context.delete(project)
        try? context.save()
        Task.detached { storage.removeAll() }
    }

    func savedProject(id: UUID) -> SavedProject? {
        let descriptor = FetchDescriptor<SavedProject>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Writes the current project to the store.
    func save() {
        guard draft.edl != nil, let payload = try? JSONEncoder().encode(draft.snapshot()) else { return }
        let project: SavedProject
        if let existing = savedProject(id: draft.id) {
            project = existing
            project.payload = payload
        } else {
            project = SavedProject(id: draft.id, title: draft.displayTitle, duration: 0, payload: payload)
            context.insert(project)
        }
        project.title = draft.displayTitle
        project.duration = draft.edl?.duration ?? 0
        project.updatedAt = .now
        try? context.save()
        if project.thumbnail == nil, let first = draft.edl?.clips.first,
            let media = draft.media.first(where: { $0.id == first.mediaID })
        {
            Task {
                let image = await Thumbnailer.image(for: media, maxPixelSize: 300)
                project.thumbnail = image?.jpegData(compressionQuality: 0.8)
                try? context.save()
            }
        }
    }

    // MARK: Preview

    func closePreview() {
        preview?.player.pause()
        preview = nil
    }

    /// Builds the preview for a project opened from the list.
    func preparePreview() async {
        guard preview == nil, let edl = draft.edl else { return }
        do {
            let built = try await FilmGenerator.build(edl, media: draft.media, song: draft.song, settings: .preview(draft.format))
            guard draft.edl == edl else { return }
            preview = PreviewSession(edl: edl, built: built)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Applies a clip-strip edit: re-times the film and rebuilds the preview.
    func apply(_ edit: ClipEdit) async {
        guard let session = preview else { return }
        let clock = ContinuousClock()
        let started = clock.now
        let focus = focusClipID(for: edit, in: session.edl)
        let request = FilmGenerator.planningRequest(GenerationInput(draft: draft))
        let (edl, exclusions) = Planner.apply(edit, to: session.edl, request: request)
        draft.exclusions = exclusions
        draft.edl = edl
        if case .setLocked = edit {
            // Locking changes no timing; the film stays as it is.
            session.update(edl: edl)
        } else {
            await rebuild(session, edl: edl, focus: focus)
        }
        lastEditDuration = clock.now - started
        save()
    }

    /// Sets the title and end credit (F14) without changing the edit.
    func setTexts(title: String, endCredit: String) async {
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.endCredit = endCredit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = preview else { return }
        var edl = session.edl
        edl.title = draft.title.isEmpty ? nil : TextCard(text: draft.title)
        edl.endCredit = draft.endCredit.isEmpty ? nil : TextCard(text: draft.endCredit)
        draft.edl = edl
        await rebuild(session, edl: edl, focus: nil)
        save()
    }

    private func rebuild(_ session: PreviewSession, edl: EditDecisionList, focus: String?) async {
        do {
            let built = try await FilmGenerator.build(edl, media: draft.media, song: draft.song, settings: .preview(draft.format))
            let seekTime = focus.flatMap { id in edl.clips.first { $0.id == id }?.timelineStart }
            await session.replace(edl: edl, built: built, seekTo: seekTime)
        } catch {
            message = error.localizedDescription
        }
    }

    /// The clip to show after an edit: the moved clip, or the one after a removed clip.
    private func focusClipID(for edit: ClipEdit, in edl: EditDecisionList) -> String? {
        switch edit {
        case let .move(clipID, _):
            return clipID
        case let .remove(clipID):
            guard let index = edl.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
            return index + 1 < edl.clips.count ? edl.clips[index + 1].id : (index > 0 ? edl.clips[index - 1].id : nil)
        case .setLocked:
            return nil
        }
    }
}

/// How the user chose the film length.
enum LengthChoice: Hashable, Codable, Sendable {
    case auto
    case preset(Double)
    case custom(Double)
}

/// Everything about the film being made.
@MainActor
@Observable
final class ProjectDraft {
    static let presetLengths: [Double] = [15, 30, 60, 180, 300, 600]

    let id: UUID
    let storage: ProjectStorage
    var media: [ImportedMedia] = []
    /// Vision/Accelerate analysis per media id, computed once and reused for every version.
    var analyses: [String: MediaAnalysis] = [:]
    /// Items that could not be read and were skipped.
    var skippedCount = 0
    var lengthChoice: LengthChoice = .preset(60)
    private(set) var style: StyleID = .travel
    var musicTrackID: String = MusicCatalog.suggestion(for: .travel)?.id ?? ""
    var musicChosenByUser = false
    /// The user's own song, once imported.
    var customSong: SongChoice?
    /// Keep the videos' own sound under the music (F10).
    var originalAudio = false
    var format: AspectFormat = .portrait
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    /// Footage removed in the clip strip; never used again.
    var exclusions: [Exclusion] = []
    /// Title and end credit (F14); empty means none.
    var title = ""
    var endCredit = ""
    /// The user's description for the AI director (F16).
    var instruction = ""
    /// The director's plan for `directorInstruction`, reused for new versions.
    var directorPlan: DirectorPlan?
    var directorInstruction = ""
    /// The user picked the style themselves, so the director's suggestion is not applied.
    var styleChosenByUser = false
    /// The last description could not be followed.
    var directorFailed = false
    var edl: EditDecisionList?

    init(id: UUID = UUID()) {
        self.id = id
        storage = ProjectStorage(projectID: id)
    }

    convenience init(id: UUID, restoring snapshot: ProjectSnapshot) {
        self.init(id: id)
        let mediaFolder = storage.mediaDirectory
        let musicFolder = storage.musicDirectory
        media = snapshot.media.map { ImportedMedia(item: $0.item, url: mediaFolder.appending(path: $0.fileName)) }
        analyses = snapshot.analyses
        skippedCount = snapshot.skippedCount
        lengthChoice = snapshot.lengthChoice
        style = snapshot.style
        musicTrackID = snapshot.musicTrackID
        musicChosenByUser = snapshot.musicChosenByUser
        customSong = snapshot.customSong.map {
            SongChoice(id: $0.id, title: $0.title, url: musicFolder.appending(path: $0.fileName), info: $0.info, isCustom: true)
        }
        originalAudio = snapshot.originalAudio
        format = snapshot.format
        seed = snapshot.seed
        exclusions = snapshot.exclusions
        title = snapshot.title
        endCredit = snapshot.endCredit
        instruction = snapshot.instruction ?? ""
        directorPlan = snapshot.directorPlan
        directorInstruction = snapshot.directorInstruction ?? ""
        styleChosenByUser = snapshot.styleChosenByUser ?? false
        edl = snapshot.edl
    }

    func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            media: media.map { ProjectSnapshot.StoredMedia(item: $0.item, fileName: $0.url.lastPathComponent) },
            analyses: analyses,
            skippedCount: skippedCount,
            lengthChoice: lengthChoice,
            style: style,
            musicTrackID: musicTrackID,
            musicChosenByUser: musicChosenByUser,
            customSong: customSong.map {
                ProjectSnapshot.StoredSong(id: $0.id, title: $0.title, fileName: $0.url.lastPathComponent, info: $0.info)
            },
            originalAudio: originalAudio,
            format: format,
            seed: seed,
            exclusions: exclusions,
            title: title,
            endCredit: endCredit,
            edl: edl,
            instruction: instruction,
            directorPlan: directorPlan,
            directorInstruction: directorInstruction,
            styleChosenByUser: styleChosenByUser
        )
    }

    var mediaItems: [MediaItem] { media.map(\.item) }

    var totalVideoDuration: Double { mediaItems.totalVideoDuration }
    var photoCount: Int { media.filter { $0.item.kind.isStill }.count }
    var videoCount: Int { media.filter { $0.item.kind == .video }.count }

    /// The length the planner aims for.
    var targetDuration: Double {
        switch lengthChoice {
        case .auto: AutoLength.suggest(for: mediaItems)
        case let .preset(seconds), let .custom(seconds): seconds
        }
    }

    /// Clips the user locked in the current film.
    var lockedClips: [EDLClip] { edl?.clips.filter(\.isLocked) ?? [] }

    /// The film's title, or the dates it covers.
    var displayTitle: String {
        if !title.isEmpty { return title }
        let dates = mediaItems.compactMap(\.creationDate).sorted()
        guard let first = dates.first, let last = dates.last else { return String(localized: "Film") }
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(format) }
        return "\(first.formatted(format)) – \(last.formatted(format))"
    }

    /// The description in effect when Apple Intelligence is available, else none.
    var instructionInEffect: String {
        FilmDirector.isAvailable ? instruction.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Keeps a director plan only while the description and material are the same.
    func forgetDirectorPlanIfStale() {
        if directorInstruction != instructionInEffect { directorPlan = nil }
        if let plan = directorPlan, !Set(plan.mediaIDs).isSubset(of: Set(media.map(\.id))) { directorPlan = nil }
    }

    /// The user chooses a style.
    func choose(style newStyle: StyleID) {
        styleChosenByUser = true
        select(style: newStyle)
    }

    /// Changes the style; until the user picks a song, the music follows the style.
    func select(style newStyle: StyleID) {
        style = newStyle
        if !musicChosenByUser, let suggestion = MusicCatalog.suggestion(for: newStyle) {
            musicTrackID = suggestion.id
        }
    }

    func select(songID: String) {
        musicTrackID = songID
        musicChosenByUser = true
    }

    var song: SongChoice? {
        if let customSong, customSong.id == musicTrackID { return customSong }
        return (MusicCatalog.track(id: musicTrackID) ?? MusicCatalog.defaultTrack)?.choice
    }

    var mediaURLs: [String: URL] {
        Dictionary(uniqueKeysWithValues: media.map { ($0.item.id, $0.url) })
    }
}

/// A generated film ready to watch; edits replace its content in place.
@MainActor
@Observable
final class PreviewSession {
    private(set) var edl: EditDecisionList
    private(set) var built: BuiltComposition
    let player: AVPlayer

    init(edl: EditDecisionList, built: BuiltComposition) {
        self.edl = edl
        self.built = built
        player = AVPlayer(playerItem: built.makePlayerItem())
    }

    /// Takes a new clip list whose timing is unchanged (e.g. a lock).
    func update(edl: EditDecisionList) {
        self.edl = edl
    }

    /// Swaps in a rebuilt film and waits until it can play.
    func replace(edl: EditDecisionList, built: BuiltComposition, seekTo time: Double?) async {
        let wasPlaying = player.rate > 0
        let position = time ?? player.currentTime().seconds
        self.edl = edl
        self.built = built
        let item = built.makePlayerItem()
        player.replaceCurrentItem(with: item)
        await Self.waitUntilReady(item)
        let target = CMTime(seconds: min(max(0, position.isFinite ? position : 0), max(0, edl.duration - 0.1)), preferredTimescale: 600)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    static func waitUntilReady(_ item: AVPlayerItem) async {
        var attempts = 0
        while item.status == .unknown, attempts < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
    }
}
