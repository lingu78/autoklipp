import ClipCore
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

// Work that outlives the screen that started it. The model owns these, so that folding or
// unfolding iPhone Duo, which replaces one layout's views with the other's, neither stops nor
// forgets them.

/// Making a film: the step it is on, and what went wrong.
@MainActor
@Observable
final class GenerationJob {
    let steps: [GenerationStep]
    var step: GenerationStep = .analysing
    var fraction = 0.0
    var errorMessage: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(steps: [GenerationStep]) {
        self.steps = steps
    }
}

/// What to put back if a new version is cancelled or fails.
struct Regeneration {
    let session: ObjectIdentifier
    let choices: StyleAndMusic
    let seed: UInt64
}

/// The title and end credit while their sheet is open.
struct TextsDraft: Equatable {
    var title: String
    var endCredit: String
}

/// An export at full quality, then saving to Photos or sharing.
@MainActor
@Observable
final class ExportJob {
    enum Phase: Equatable {
        case choosing
        case exporting
        case finished(URL)
    }

    let draft: ProjectDraft
    var format: AspectFormat
    var resolution: Resolution = .hd1080
    private(set) var phase: Phase = .choosing
    private(set) var progress = 0.0
    private(set) var saving = false
    private(set) var saved = false
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(draft: ProjectDraft) {
        self.draft = draft
        format = draft.format
    }

    var isExporting: Bool { phase == .exporting }

    func start(_ edl: EditDecisionList) {
        guard phase != .exporting else { return }
        phase = .exporting
        progress = 0
        message = nil
        saved = false
        let media = draft.media
        // The song the clips were timed to, as in the preview, even if another was picked since.
        let song = draft.song(for: edl)
        let settings = RenderSettings(format: format, resolution: resolution)
        let folder = draft.storage.exportDirectory
        task = Task {
            // The screen locking itself would send the app away and cut a long export short.
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            await FinishNotifier.requestPermissionIfNeeded()
            // Only the newest export is kept; earlier ones have been saved or shared by now.
            try? FileManager.default.removeItem(at: folder)
            let url = folder.appending(path: "Autoklipp-\(Int(Date().timeIntervalSince1970)).mp4")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await FinishNotifier.runAllowingBackground("Export") {
                    let built = try await FilmGenerator.build(edl, media: media, song: song, settings: settings)
                    try await VideoExporter.export(built, resolution: settings.resolution, to: url) { value in
                        Task { @MainActor in self.progress = value }
                    }
                    // Posted while the background time lasts, so it is not lost when the app is suspended.
                    await FinishNotifier.notifyIfInBackground(
                        title: String(localized: "Your film is ready"),
                        body: String(localized: "Open Autoklipp to save or share it.")
                    )
                }
                try Task.checkCancellation()
                phase = .finished(url)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                phase = .choosing
            } catch {
                try? FileManager.default.removeItem(at: url)
                phase = .choosing
                if !Task.isCancelled {
                    // The technical reason means nothing to the user.
                    message = (error as? BackgroundTimeExpired)?.errorDescription
                        ?? String(localized: "The film could not be exported. Try again.")
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func saveToPhotos(_ url: URL) async {
        saving = true
        defer { saving = false }
        do {
            try await PhotoLibrarySaver.save(videoAt: url)
            saved = true
            message = nil
        } catch {
            // Photos' own errors are technical codes.
            message = (error as? PhotoLibrarySaver.SaveError)?.errorDescription
                ?? String(localized: "The film could not be saved to Photos. Try again.")
        }
    }
}

/// The Photos selection of a project and its import into the project's folder.
@MainActor
@Observable
final class MediaImportSession {
    let draft: ProjectDraft
    private(set) var selection: [PhotosPickerItem] = []
    /// Progress of the import running now; each run has its own.
    private(set) var progress = ImportProgress()
    /// A changed selection is waiting to be imported or being imported.
    private(set) var isBusy = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    /// Picker identifiers of items already imported, mapped to media ids.
    @ObservationIgnored private var importedIdentifiers: [String: String] = [:]
    /// Picker identifiers of selected items that could not be imported.
    @ObservationIgnored private var failedIdentifiers: Set<String> = []
    /// Deselected items by picker identifier, so picking one again reuses its copy and analysis.
    @ObservationIgnored private var setAside: [String: ImportedMedia] = [:]

    init(draft: ProjectDraft) {
        self.draft = draft
    }

    /// Takes a new selection from the picker. The embedded picker reports every tap, so the
    /// import waits a moment for the next one instead of starting over for each.
    func select(_ items: [PhotosPickerItem]) {
        guard items != selection else { return }
        selection = items
        let previous = task
        previous?.cancel()
        run += 1
        let current = run
        isBusy = true
        task = Task {
            defer { if self.run == current { self.isBusy = false } }
            // One import at a time: the one replaced stops before this one starts, so an item is
            // never loaded twice at once, which quick taps in the picker used to do.
            await previous?.value
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self.sync(with: items)
        }
    }

    /// Stops copying, e.g. into a project the user left.
    func cancel() {
        task?.cancel()
        task = nil
        run += 1
        isBusy = false
    }

    /// Imports newly picked items and drops deselected ones, keeping the picker's order.
    private func sync(with items: [PhotosPickerItem]) async {
        let wanted = items.map { $0.itemIdentifier ?? UUID().uuidString }
        let keep = Set(wanted)
        // The copied file stays: a saved version of the project may still use it. AppModel
        // removes files no project uses when the project is saved or left.
        for (identifier, mediaID) in importedIdentifiers where !keep.contains(identifier) {
            setAside[identifier] = draft.media.first { $0.id == mediaID }
            draft.media.removeAll { $0.id == mediaID }
            importedIdentifiers[identifier] = nil
        }
        // An item picked again gets its earlier copy back, unless that has been cleaned up since.
        for identifier in wanted where importedIdentifiers[identifier] == nil {
            guard let media = setAside.removeValue(forKey: identifier),
                  FileManager.default.fileExists(atPath: media.url.path(percentEncoded: false))
            else { continue }
            importedIdentifiers[identifier] = media.id
            if !draft.media.contains(where: { $0.id == media.id }) { draft.media.append(media) }
        }
        // Each selected item that failed counts once, and a deselected one no longer counts.
        failedIdentifiers.formIntersection(keep)
        draft.skippedCount = failedIdentifiers.count

        let fresh = zip(items, wanted).filter { importedIdentifiers[$0.1] == nil }
        guard !fresh.isEmpty else {
            reorder(by: wanted)
            return
        }
        let progress = ImportProgress()
        self.progress = progress
        let result = await MediaImporter.importItems(fresh.map(\.0), storage: draft.storage, progress: progress)
        guard !Task.isCancelled else { return }
        for ((_, identifier), media) in zip(fresh, result.items) {
            guard let media else {
                failedIdentifiers.insert(identifier)
                continue
            }
            failedIdentifiers.remove(identifier)
            importedIdentifiers[identifier] = media.id
            if !draft.media.contains(where: { $0.id == media.id }) { draft.media.append(media) }
        }
        draft.skippedCount = failedIdentifiers.count
        reorder(by: wanted)
    }

    private func reorder(by identifiers: [String]) {
        let position = Dictionary(identifiers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let mediaPosition = Dictionary(importedIdentifiers.map { ($1, position[$0] ?? Int.max) }, uniquingKeysWith: { first, _ in first })
        draft.media.sort { (mediaPosition[$0.id] ?? Int.max) < (mediaPosition[$1.id] ?? Int.max) }
    }
}
