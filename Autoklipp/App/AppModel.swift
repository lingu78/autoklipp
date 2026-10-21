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
    /// Clip-strip and text edits whose new preview is not ready yet.
    private(set) var editsInProgress = 0
    var message: String?
    /// Apple Intelligence can direct films on this device (checked at start and on return).
    private(set) var directorAvailable = FilmDirector.isAvailable

    var isEditing: Bool { editsInProgress > 0 }

    func refreshDirectorAvailability() {
        directorAvailable = FilmDirector.isAvailable
    }

    init(inMemory: Bool = false) {
        draft = ProjectDraft()
        // The store lives in Application Support, which does not exist on a fresh install.
        if !inMemory {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let persistent: Bool
        if let container = try? ModelContainer(for: SavedProject.self, configurations: configuration) {
            self.container = container
            persistent = !inMemory
        } else {
            // A broken store must not stop the app; projects are then kept for this session only.
            self.container = try! ModelContainer(for: SavedProject.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            persistent = false
        }
        // Only the real store knows every saved project; with the fallback all would look abandoned.
        if persistent { removeAbandonedProjects() }
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Projects

    func newProject() {
        closePreview()
        leave(draft)
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
        if draft.id != project.id { leave(draft) }
        draft = ProjectDraft(id: project.id, restoring: snapshot)
        // Copies from an earlier visit that was never saved.
        removeUnusedFiles(in: draft.storage, keeping: snapshot.fileNames)
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
        save(draft)
    }

    /// Writes a project to the store; an edit that finishes after the user left its film still counts.
    private func save(_ draft: ProjectDraft) {
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
        // The thumbnail follows the film's first clip.
        if let first = draft.edl?.clips.first, project.thumbnail == nil || draft.thumbnailMediaID != first.mediaID,
            let media = draft.media.first(where: { $0.id == first.mediaID })
        {
            draft.thumbnailMediaID = media.id
            Task {
                let image = await Thumbnailer.image(for: media, maxPixelSize: 300)
                // A later save may have asked for another clip meanwhile.
                guard draft.thumbnailMediaID == media.id else { return }
                project.thumbnail = image?.jpegData(compressionQuality: 0.8)
                try? context.save()
            }
        }
        // Files the project stopped using, e.g. deselected media or a replaced song.
        if draft === self.draft { removeUnusedFiles(in: draft.storage, keeping: draft.fileNames) }
    }

    // MARK: Copied files

    /// Cleans up after the user leaves a project: a draft that was never saved loses its whole
    /// folder, a saved one keeps exactly the files its saved copy uses.
    private func leave(_ draft: ProjectDraft) {
        let id = draft.id
        let descriptor = FetchDescriptor<SavedProject>(predicate: #Predicate { $0.id == id })
        // When the store cannot answer, nothing is deleted.
        guard let found = try? context.fetch(descriptor) else { return }
        guard let saved = found.first else {
            let storage = draft.storage
            Task.detached { storage.removeAll() }
            return
        }
        guard let snapshot = saved.snapshot else { return }
        removeUnusedFiles(in: draft.storage, keeping: snapshot.fileNames)
    }

    /// Deletes copied media and songs in a project folder that are not among `keep`. The files are
    /// listed now, so a file copied in afterwards is never touched.
    private func removeUnusedFiles(in storage: ProjectStorage, keeping keep: Set<String>) {
        let unused = Self.unusedFiles(in: storage, keeping: keep)
        guard !unused.isEmpty else { return }
        Task.detached {
            for url in unused { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The files in a project's media and music folders whose names are not among `keep`.
    static func unusedFiles(in storage: ProjectStorage, keeping keep: Set<String>) -> [URL] {
        [storage.mediaDirectory, storage.musicDirectory]
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { !keep.contains($0.lastPathComponent) }
    }

    /// Removes the folders of projects that were never saved, e.g. when the app was closed
    /// before a film was made.
    private func removeAbandonedProjects() {
        var descriptor = FetchDescriptor<SavedProject>()
        descriptor.propertiesToFetch = [\.id]
        guard let saved = try? context.fetch(descriptor) else { return }
        let keep = Set(saved.map(\.id)).union([draft.id])
        let folders = (try? FileManager.default.contentsOfDirectory(at: ProjectStorage.root, includingPropertiesForKeys: nil)) ?? []
        let abandoned = folders.compactMap { UUID(uuidString: $0.lastPathComponent) }.filter { !keep.contains($0) }
        guard !abandoned.isEmpty else { return }
        Task.detached {
            for id in abandoned { ProjectStorage(projectID: id).removeAll() }
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
            let built = try await FilmGenerator.build(edl, media: draft.media, song: draft.song(for: edl), settings: .preview(draft.format))
            guard draft.edl == edl else { return }
            preview = PreviewSession(edl: edl, built: built)
        } catch {
            message = Self.buildFailedMessage
        }
    }

    /// Applies a clip-strip edit: re-times the film and rebuilds the preview.
    func apply(_ edit: ClipEdit) async {
        guard let session = preview else { return }
        let draft = self.draft
        editsInProgress += 1
        defer { editsInProgress -= 1 }
        let clock = ContinuousClock()
        let started = clock.now
        // An edit builds on the one before it, even while that one's preview is being made.
        let base = draft.edl ?? session.edl
        let focus = focusClipID(for: edit, in: base)
        var input = GenerationInput(draft: draft)
        // Only the clips change; the film keeps the song and style it was made with.
        input.song = draft.song(for: base)
        input.style = base.style
        let (edl, exclusions) = Planner.apply(edit, to: base, request: FilmGenerator.planningRequest(input))
        draft.exclusions = exclusions
        draft.edl = edl
        if case .move = edit { draft.arrangedByUser = true }
        if case .setLocked = edit, base == session.edl {
            // Locking changes no timing; the film stays as it is.
            session.update(edl: edl)
        } else {
            await rebuild(session, of: draft, edl: edl, focus: focus)
        }
        lastEditDuration = clock.now - started
        save(draft)
    }

    /// Sets the title and end credit (F14) without changing the edit.
    func setTexts(title: String, endCredit: String) async {
        let draft = self.draft
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // From now on the director's title no longer replaces it, even when it was removed.
        if title != draft.title { draft.titleChosenByUser = true }
        draft.title = title
        draft.endCredit = endCredit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = preview else { return }
        editsInProgress += 1
        defer { editsInProgress -= 1 }
        var edl = draft.edl ?? session.edl
        edl.title = draft.title.isEmpty ? nil : TextCard(text: draft.title)
        edl.endCredit = draft.endCredit.isEmpty ? nil : TextCard(text: draft.endCredit)
        draft.edl = edl
        await rebuild(session, of: draft, edl: edl, focus: nil)
        save(draft)
    }

    private func rebuild(_ session: PreviewSession, of draft: ProjectDraft, edl: EditDecisionList, focus: String?) async {
        do {
            let built = try await FilmGenerator.build(edl, media: draft.media, song: draft.song(for: edl), settings: .preview(draft.format))
            // A later edit replaced this one, or the user left the film; only the newest is shown.
            guard draft.edl == edl, preview === session else { return }
            let seekTime = focus.flatMap { id in edl.clips.first { $0.id == id }?.timelineStart }
            await session.replace(edl: edl, built: built, seekTo: seekTime)
            // The user went back while it was being made: the film must not play unseen.
            if path.last != .preview { session.player.pause() }
        } catch {
            if draft.edl == edl { message = Self.buildFailedMessage }
        }
    }

    /// Shown when a film cannot be put together; the technical reason means nothing to the user.
    static var buildFailedMessage: String {
        String(localized: "The film could not be made. A photo or video may be missing.")
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

/// The style and music choices a Change sheet edits, kept so that a cancelled change can be undone.
struct StyleAndMusic: Equatable, Sendable {
    var style: StyleID
    var styleChosenByUser: Bool
    var musicTrackID: String
    var musicChosenByUser: Bool
    var customSong: SongChoice?
    var originalAudio: Bool
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
    /// The user wrote or removed the title, so the director's title is not applied.
    var titleChosenByUser = false
    /// The user's description for the AI director (F16).
    var instruction = ""
    /// The director's plan for `directorInstruction`, reused for new versions.
    var directorPlan: DirectorPlan?
    var directorInstruction = ""
    /// The media the current film, and the director's plan, were made from.
    var materialIDs: Set<String> = []
    /// The user picked the style themselves, so the director's suggestion is not applied.
    var styleChosenByUser = false
    /// The last description could not be followed.
    var directorFailed = false
    /// The user reordered the clips of the current film.
    var arrangedByUser = false
    var edl: EditDecisionList?
    /// The media the saved thumbnail shows; nil until one is made in this session.
    var thumbnailMediaID: String?

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
        // Older projects did not record where the title came from; a title is then kept as it is.
        titleChosenByUser = snapshot.titleChosenByUser ?? !snapshot.title.isEmpty
        instruction = snapshot.instruction ?? ""
        directorPlan = snapshot.directorPlan
        directorInstruction = snapshot.directorInstruction ?? ""
        // Unknown in older projects, so their plan is made again once.
        materialIDs = Set(snapshot.materialIDs ?? [])
        styleChosenByUser = snapshot.styleChosenByUser ?? false
        arrangedByUser = snapshot.arrangedByUser ?? false
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
            styleChosenByUser: styleChosenByUser,
            titleChosenByUser: titleChosenByUser,
            materialIDs: materialIDs.sorted(),
            arrangedByUser: arrangedByUser
        )
    }

    /// The files in the project's folder this draft uses.
    var fileNames: Set<String> {
        var names = Set(media.map { $0.url.lastPathComponent })
        if let customSong { names.insert(customSong.url.lastPathComponent) }
        return names
    }

    /// Takes a newly generated film and what the run decided.
    func adopt(_ output: GenerationOutput, from input: GenerationInput) {
        analyses.merge(output.analyses) { _, new in new }
        directorPlan = output.directorPlan
        directorInstruction = input.instruction
        materialIDs = Set(input.media.map(\.id))
        directorFailed = output.directorFailed
        // The film's song already follows a style the director chose, so the draft stays in step.
        if output.style != style { select(style: output.style) }
        if !titleChosenByUser { title = output.edl.title?.text ?? "" }
        arrangedByUser = output.keptArrangement
        edl = output.edl
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
        if directorInstruction != instructionInEffect || materialIDs != Set(media.map(\.id)) { directorPlan = nil }
    }

    /// The user's clip order, kept when only the music or the sound changes (F11): same style,
    /// version, length and material as the current film.
    var userArrangement: [EDLClip]? {
        guard arrangedByUser, let edl, edl.style == style, edl.seed == seed, edl.targetDuration == targetDuration,
            materialIDs == Set(media.map(\.id))
        else { return nil }
        return edl.clips
    }

    var styleAndMusic: StyleAndMusic {
        StyleAndMusic(
            style: style, styleChosenByUser: styleChosenByUser, musicTrackID: musicTrackID,
            musicChosenByUser: musicChosenByUser, customSong: customSong, originalAudio: originalAudio
        )
    }

    func restore(_ choices: StyleAndMusic) {
        style = choices.style
        styleChosenByUser = choices.styleChosenByUser
        musicTrackID = choices.musicTrackID
        musicChosenByUser = choices.musicChosenByUser
        customSong = choices.customSong
        originalAudio = choices.originalAudio
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

    /// The song chosen for the next film.
    var song: SongChoice? {
        if let customSong, customSong.id == musicTrackID { return customSong }
        return (MusicCatalog.track(id: musicTrackID) ?? MusicCatalog.defaultTrack)?.choice
    }

    /// The song a clip list was timed to, which its film is built with: the cuts sit on that
    /// song's beats even when another one has been chosen since. Nil for a film without music.
    func song(for edl: EditDecisionList) -> SongChoice? {
        guard let id = edl.music?.trackID else { return nil }
        if let customSong, customSong.id == id { return customSong }
        return MusicCatalog.track(id: id)?.choice
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
