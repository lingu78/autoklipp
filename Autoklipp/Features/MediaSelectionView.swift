import ClipCore
import PhotosUI
import SwiftUI

/// Step 1: pick photos and videos.
struct MediaSelectionView: View {
    @Environment(AppModel.self) private var model

    private var draft: ProjectDraft { model.draft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pick photos and videos, choose a length and get a finished film with music.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                PhotosPicker(
                    selection: model.imports.selectionBinding,
                    maxSelectionCount: MediaImportSession.maximumCount,
                    selectionBehavior: .ordered,
                    matching: MediaImportSession.filter,
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
                .disabled(model.imports.isBusy || model.isEditing)

                MediaImportStatus()

                if !draft.media.isEmpty {
                    SelectedMediaSummary(draft: draft)
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
