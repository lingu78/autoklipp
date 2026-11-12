import ClipCore
import PhotosUI
import SwiftUI

/// Step 1: pick photos and videos, straight in the photo library, which fills the screen.
struct MediaSelectionView: View {
    @Environment(AppModel.self) private var model

    private var draft: ProjectDraft { model.draft }

    var body: some View {
        MediaLibraryPicker()
            .safeAreaInset(edge: .top, spacing: 0) {
                SelectionHeader()
            }
            .navigationTitle("New film")
            .navigationBarTitleDisplayMode(.inline)
            .flowActions(actions)
    }

    private var actions: [FlowAction] {
        guard !draft.media.isEmpty else { return [] }
        return [
            FlowAction("Next", systemImage: "arrow.right", kind: .primary, isDisabled: model.imports.isBusy) {
                model.path.append(.length)
            },
            FlowAction("Start over", systemImage: "arrow.counterclockwise", kind: .destructive, isDisabled: model.isEditing) {
                model.startOver()
            },
        ]
    }
}

/// Above the library: what is picked so far, and the import while it runs.
private struct SelectionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.draft
        VStack(alignment: .leading, spacing: 8) {
            if draft.media.isEmpty {
                Text("Pick photos and videos, choose a length and get a finished film with music.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                SelectedMediaSummary(draft: draft)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: draft.media.count)
            }
            MediaImportStatus()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: draft.media.count)
    }
}

/// The photo library itself, embedded: a large grid where every tap picks or unpicks.
struct MediaLibraryPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PhotosPicker(
            selection: model.imports.selectionBinding,
            maxSelectionCount: MediaImportSession.maximumCount,
            selectionBehavior: .continuousAndOrdered,
            matching: MediaImportSession.filter,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            Text("Choose photos and videos")
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities(.selectionActions)
        // An edit in the clip strip saves the project when it finishes; the media must not
        // change under it.
        .disabled(model.isEditing)
    }
}

extension MediaImportSession {
    static let maximumCount = 200
    static let filter = PHPickerFilter.any(of: [.images, .videos, .livePhotos])

    var selectionBinding: Binding<[PhotosPickerItem]> {
        Binding(get: { self.selection }, set: { self.select($0) })
    }
}

/// Import progress and items that could not be read.
struct MediaImportStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.imports.progress
        if progress.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                Text("Importing \(progress.finished) of \(progress.total)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        if model.draft.skippedCount > 0 {
            // Only the icon is orange: orange text on white is too faint to read.
            Label {
                Text("\(model.draft.skippedCount) items could not be read and were skipped.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
        }
    }
}

/// How many items are picked, and how long their videos are.
struct SelectedMediaSummary: View {
    let draft: ProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(draft.media.count) selected")
                .font(.title3.bold())
            Text("Photos: \(draft.photoCount) · Videos: \(draft.videoCount) · Video length: \(Formatting.duration(draft.totalVideoDuration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
