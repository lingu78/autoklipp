import AVKit
import ClipCore
import SwiftUI

/// Step 5: watch the film and adjust it.
struct PreviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if let session = model.preview {
                FilmPlayerSection(session: session)
            } else {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(.top)
        .navigationTitle(model.draft.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TitleAndCreditsButton()
            }
        }
        .flowActions(actions)
        .task { await model.preparePreview() }
        // Only the model closes a sheet (its buttons, or a step chosen on a large display). The
        // sheet also goes away when the layout changes, and must stay open in the model then.
        .sheet(item: Binding(get: { model.sheet }, set: { _ in })) { sheet in
            PreviewSheetContent(sheet: sheet)
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var actions: [FlowAction] {
        let disabled = model.preview == nil || model.isEditing
        return [
            FlowAction("Change music", systemImage: "music.note", isDisabled: disabled) { model.beginChange(.music) },
            FlowAction("Change style", systemImage: "paintpalette", isDisabled: disabled) { model.beginChange(.style) },
            FlowAction("Another version", systemImage: "shuffle", isDisabled: disabled) { model.createFilm(newVersion: true) },
            FlowAction("Export", systemImage: "square.and.arrow.up", kind: .primary, isDisabled: disabled) { model.openExport() },
        ]
    }
}

/// Opens the title and end credit (F14).
struct TitleAndCreditsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.openTexts()
        } label: {
            Label("Title and credits", systemImage: "textformat")
        }
        .disabled(model.preview == nil || model.isEditing || model.sheet != nil)
    }
}

/// The film with its notices and the clip strip; the same in both layouts, so that the player
/// carries on when one replaces the other.
struct FilmPlayerSection: View {
    @Environment(AppModel.self) private var model
    let session: PreviewSession
    var isBusy = false
    @State private var currentTime = 0.0

    var body: some View {
        VStack(spacing: 12) {
            VideoPlayer(player: session.player)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.black)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel(Text("Film preview"))
                .task(id: ObjectIdentifier(session)) { await followPlayback(session.player) }
                .padding(.horizontal)

            ForEach(Array(session.edl.notices.enumerated()), id: \.offset) { entry in
                noticeView(entry.element)
                    .padding(.horizontal)
            }
            if model.draft.directorFailed {
                Label("Apple Intelligence could not follow your description, so the film was made without it.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            ClipStripView(
                clips: session.edl.clips,
                media: Dictionary(uniqueKeysWithValues: model.draft.media.map { ($0.id, $0) }),
                currentTime: currentTime,
                isBusy: model.isEditing || isBusy,
                onSelect: { clip in
                    let time = CMTime(seconds: clip.timelineStart + 0.01, preferredTimescale: 600)
                    session.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                },
                onEdit: { edit in
                    Task { await model.apply(edit) }
                }
            )

            Text("Drag to reorder · swipe up to remove · touch and hold to lock")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var aspectRatio: CGFloat {
        let size = RenderSettings.preview(model.draft.format).renderSize
        return size.width / size.height
    }

    @ViewBuilder
    private func noticeView(_ notice: PlanNotice) -> some View {
        switch notice {
        case let .materialShorterThanTarget(available, target):
            Label(
                "There was only enough material for \(Formatting.duration(available)) of the \(Formatting.duration(target)) you asked for.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func followPlayback(_ player: AVPlayer) async {
        while !Task.isCancelled {
            let seconds = player.currentTime().seconds
            currentTime = seconds.isFinite ? seconds : 0
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// What a sheet over the film shows.
struct PreviewSheetContent: View {
    @Environment(AppModel.self) private var model
    let sheet: PreviewSheet

    var body: some View {
        switch sheet {
        case .export:
            if let job = model.export {
                ExportView(job: job)
            }
        case .style:
            ChangeSheet(title: Text("Change style"), isBusy: model.draft.analysingSong) {
                StylePickerSection(draft: model.draft)
            } onCancel: {
                model.cancelChange()
            } onDone: {
                model.createFilm()
            }
        case .music:
            ChangeSheet(title: Text("Change music"), isBusy: model.draft.analysingSong) {
                MusicPickerSection(draft: model.draft)
                SoundSection(draft: model.draft)
            } onCancel: {
                model.cancelChange()
            } onDone: {
                model.createFilm()
            }
        case .texts:
            TextsSheet()
        }
    }
}

/// A sheet with picker sections; confirming makes the film again. Closed only by its buttons,
/// which tell the model.
struct ChangeSheet<Content: View>: View {
    let title: Text
    /// A song is being analysed; the film cannot be made until it is done.
    var isBusy = false
    @ViewBuilder let content: () -> Content
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel, action: onCancel) {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .disabled(isBusy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onDone) {
                            Label("Create film", systemImage: "checkmark")
                        }
                        .disabled(isBusy)
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

/// Title at the start and a line at the end (F14). The text being typed lives in the model,
/// so it is still there when the sheet comes back in the other layout.
struct TextsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: text(\.title))
                } footer: {
                    Text("Shown over the first seconds of the film.")
                }
                Section {
                    TextField("End credit", text: text(\.endCredit))
                } footer: {
                    Text("Shown over the last seconds of the film.")
                }
            }
            .navigationTitle("Title and credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        model.closeTexts(saving: false)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.closeTexts(saving: true)
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func text(_ field: WritableKeyPath<TextsDraft, String>) -> Binding<String> {
        Binding(get: { model.texts?[keyPath: field] ?? "" }, set: { model.texts?[keyPath: field] = $0 })
    }
}
