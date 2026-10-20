import AVKit
import ClipCore
import SwiftUI

/// Step 5: watch the film and adjust it.
struct PreviewView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: Sheet?
    @State private var currentTime = 0.0
    @State private var editing = false

    enum Sheet: String, Identifiable {
        case export
        case style
        case music
        case texts

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let session = model.preview {
                VideoPlayer(player: session.player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(Text("Film preview"))
                    .onAppear { session.player.play() }
                    .onDisappear { session.player.pause() }
                    .task(id: ObjectIdentifier(session)) { await followPlayback(session.player) }
                    .padding(.horizontal)

                ForEach(Array(session.edl.notices.enumerated()), id: \.offset) { entry in
                    noticeView(entry.element)
                        .padding(.horizontal)
                }

                ClipStripView(
                    clips: session.edl.clips,
                    media: Dictionary(uniqueKeysWithValues: model.draft.media.map { ($0.id, $0) }),
                    currentTime: currentTime,
                    isBusy: editing,
                    onSelect: { clip in
                        let time = CMTime(seconds: clip.timelineStart + 0.01, preferredTimescale: 600)
                        session.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    },
                    onEdit: { edit in
                        editing = true
                        Task {
                            await model.apply(edit)
                            editing = false
                        }
                    }
                )

                Text("Drag to reorder · swipe up to remove · touch and hold to lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            }
            Spacer(minLength: 0)
            actions
                .padding(.horizontal)
        }
        .padding(.vertical)
        .navigationTitle(model.draft.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    open(.texts)
                } label: {
                    Label("Title and credits", systemImage: "textformat")
                }
                .disabled(model.preview == nil)
            }
        }
        .task { await model.preparePreview() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .export:
                if let session = model.preview {
                    ExportView(edl: session.edl, draft: model.draft)
                }
            case .style:
                ChangeSheet(title: Text("Change style")) {
                    StylePickerSection(draft: model.draft)
                } onDone: {
                    regenerate(newSeed: false)
                }
            case .music:
                ChangeSheet(title: Text("Change music")) {
                    MusicPickerSection(draft: model.draft, analysingSong: .constant(false))
                    SoundSection(draft: model.draft)
                } onDone: {
                    regenerate(newSeed: false)
                }
            case .texts:
                TextsSheet(title: model.draft.title, endCredit: model.draft.endCredit) { title, credit in
                    Task { await model.setTexts(title: title, endCredit: credit) }
                }
            }
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

    private var aspectRatio: CGFloat {
        let size = RenderSettings.preview(model.draft.format).renderSize
        return size.width / size.height
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    open(.music)
                } label: {
                    Label("Change music", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    open(.style)
                } label: {
                    Label("Change style", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 10) {
                Button {
                    regenerate(newSeed: true)
                } label: {
                    Label("Another version", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    open(.export)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.preview == nil || editing)
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

    private func open(_ sheet: Sheet) {
        model.preview?.player.pause()
        self.sheet = sheet
    }

    /// Makes the film again; locked clips and removed footage are respected (F12).
    private func regenerate(newSeed: Bool) {
        model.preview?.player.pause()
        if newSeed { model.draft.seed = UInt64.random(in: 1...UInt64.max) }
        if model.path.last == .preview { model.path.removeLast() }
        model.path.append(.generate)
    }

    private func followPlayback(_ player: AVPlayer) async {
        while !Task.isCancelled {
            let seconds = player.currentTime().seconds
            currentTime = seconds.isFinite ? seconds : 0
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// A sheet with picker sections; confirming makes the film again.
struct ChangeSheet<Content: View>: View {
    let title: Text
    @ViewBuilder let content: () -> Content
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create film") {
                            dismiss()
                            onDone()
                        }
                    }
                }
        }
    }
}

/// Title at the start and a line at the end (F14).
struct TextsSheet: View {
    @State var title: String
    @State var endCredit: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                } footer: {
                    Text("Shown over the first seconds of the film.")
                }
                Section {
                    TextField("End credit", text: $endCredit)
                } footer: {
                    Text("Shown over the last seconds of the film.")
                }
            }
            .navigationTitle("Title and credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(title, endCredit)
                        dismiss()
                    }
                }
            }
        }
    }
}
