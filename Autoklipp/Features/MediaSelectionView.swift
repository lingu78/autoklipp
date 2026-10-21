import ClipCore
import PhotosUI
import SwiftUI

/// Step 1: pick photos and videos.
struct MediaSelectionView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: [PhotosPickerItem] = []
    @State private var progress = ImportProgress()
    @State private var importTask: Task<Void, Never>?
    /// Picker identifiers of items already imported, mapped to media ids.
    @State private var importedIdentifiers: [String: String] = [:]
    /// Picker identifiers of selected items that could not be imported.
    @State private var failedIdentifiers: Set<String> = []
    /// Deselected items by picker identifier, so picking one again reuses its copy and analysis.
    @State private var setAside: [String: ImportedMedia] = [:]

    private var draft: ProjectDraft { model.draft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pick photos and videos, choose a length and get a finished film with music.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: 200,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos, .livePhotos]),
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    Label(
                        draft.media.isEmpty ? LocalizedStringKey("Choose photos and videos") : LocalizedStringKey("Change selection"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                // An edit in the clip strip saves the project when it finishes; the media must not
                // change under it.
                .disabled(progress.isRunning || model.isEditing)

                if progress.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fraction)
                        Text("Importing \(progress.finished) of \(progress.total)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if draft.skippedCount > 0 {
                    // Only the icon is orange: orange text on white is too faint to read.
                    Label {
                        Text("\(draft.skippedCount) items could not be read and were skipped.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                }

                if !draft.media.isEmpty {
                    summary
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
                        ForEach(draft.media) { media in
                            MediaThumbnail(media: media)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("New film")
        .safeAreaInset(edge: .bottom) {
            if !draft.media.isEmpty {
                Button {
                    model.path.append(.length)
                } label: {
                    Text("Next")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(progress.isRunning)
                .padding()
                .background(.bar)
            }
        }
        .toolbar {
            if !draft.media.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start over", role: .destructive) {
                        importTask?.cancel()
                        selection = []
                        importedIdentifiers = [:]
                        failedIdentifiers = []
                        setAside = [:]
                        model.startOver()
                    }
                    .disabled(model.isEditing)
                }
            }
        }
        .onChange(of: selection) { _, newSelection in
            importTask?.cancel()
            importTask = Task { await sync(with: newSelection) }
        }
        // Leaving mid-import (Next is disabled meanwhile) stops copying into a draft that may be
        // abandoned and removed.
        .onDisappear { importTask?.cancel() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(draft.media.count) selected")
                .font(.title3.bold())
            Text("Photos: \(draft.photoCount) · Videos: \(draft.videoCount) · Video length: \(Formatting.duration(draft.totalVideoDuration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Imports newly picked items and drops deselected ones, keeping the picker's order.
    private func sync(with items: [PhotosPickerItem]) async {
        let draft = model.draft
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
            draft.media.append(media)
        }
        // Each selected item that failed counts once, and a deselected one no longer counts.
        failedIdentifiers.formIntersection(keep)
        draft.skippedCount = failedIdentifiers.count

        let fresh = zip(items, wanted).filter { importedIdentifiers[$0.1] == nil }
        guard !fresh.isEmpty else {
            reorder(draft, by: wanted)
            return
        }
        let result = await MediaImporter.importItems(fresh.map(\.0), storage: draft.storage, progress: progress)
        guard !Task.isCancelled, draft === model.draft else { return }
        for ((_, identifier), media) in zip(fresh, result.items) {
            guard let media else {
                failedIdentifiers.insert(identifier)
                continue
            }
            failedIdentifiers.remove(identifier)
            importedIdentifiers[identifier] = media.id
            draft.media.append(media)
        }
        draft.skippedCount = failedIdentifiers.count
        reorder(draft, by: wanted)
    }

    private func reorder(_ draft: ProjectDraft, by identifiers: [String]) {
        let position = Dictionary(identifiers.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let mediaPosition = Dictionary(importedIdentifiers.map { ($1, position[$0] ?? Int.max) }, uniquingKeysWith: { first, _ in first })
        draft.media.sort { (mediaPosition[$0.id] ?? Int.max) < (mediaPosition[$1.id] ?? Int.max) }
    }
}
