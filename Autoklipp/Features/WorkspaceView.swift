import ClipCore
import PhotosUI
import SwiftUI

/// The flow on a large display (iPhone Duo's inner display): the film, or the photo library while
/// picking, on the left (about 65 %), the steps on the right with the active one open. Shows the
/// same model state as the one-column screens, so folding and unfolding change only the layout.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let split = ColumnSplit(width: proxy.size.width, fold: proxy.verticalFold)
            HStack(spacing: 0) {
                WorkspaceStage()
                    .frame(width: split.primary)
                Color.clear
                    .frame(width: split.gap)
                StepPanel()
                    .frame(width: split.sidebar)
                    .overlay(alignment: .leading) {
                        // No line over the fold; the gap there separates the columns.
                        if split.gap == 0 {
                            Rectangle()
                                .fill(Color(uiColor: .separator))
                                .frame(width: 0.5)
                        }
                    }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.activeStep == .generate, model.generation == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    TitleAndCreditsButton()
                }
            }
        }
        .sheet(item: Binding(get: { model.sheet == .texts ? PreviewSheet.texts : nil }, set: { _ in })) { _ in
            TextsSheet()
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.message != nil && !model.path.isEmpty }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var title: Text {
        model.draft.edl == nil ? Text("New film") : Text(model.draft.displayTitle)
    }
}

/// The left column: the photo library while picking, the steps of making the film, the film
/// with its clip strip, or the picked media until there is a film.
private struct WorkspaceStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.activeStep == .media {
                MediaLibraryPicker()
            } else if let job = model.generation {
                GenerationProgressView(job: job)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        HeroBackground(animated: !reduceMotion)
                            .ignoresSafeArea()
                    }
            } else if model.hasFilm {
                Group {
                    if let session = model.preview {
                        FilmPlayerSection(session: session, isBusy: model.export?.isExporting == true)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.vertical, 12)
                // The film on a dark stage, as on the phone.
                .background { FilmStage() }
                .environment(\.colorScheme, .dark)
                .task { await model.preparePreview() }
            } else {
                SelectedMediaMosaic(draft: model.draft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

/// The picked photos and videos, until there is a film to show in their place.
private struct SelectedMediaMosaic: View {
    let draft: ProjectDraft

    var body: some View {
        if draft.media.isEmpty {
            ContentUnavailableView("No photos or videos yet", systemImage: "photo.on.rectangle.angled")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your film appears here once it is made.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // An even number of columns, so that a fold down the middle falls between two.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                        ForEach(draft.media) { media in
                            MediaThumbnail(media: media)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: Steps

/// The right column: every step as a header, the active one opened below it.
private struct StepPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(FlowStep.allCases) { step in
                    Section {
                        StepHeader(step: step)
                            .id(step)
                    }
                    if step == model.activeStep {
                        StepContent(step: step)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.activeStep) { _, step in
                guard let step else { return }
                withAnimation { proxy.scrollTo(step, anchor: .top) }
            }
        }
    }
}

/// A step's number, title and what was chosen in it; tapping it opens the step.
private struct StepHeader: View {
    @Environment(AppModel.self) private var model
    let step: FlowStep

    var body: some View {
        let active = model.activeStep == step
        Button {
            model.show(step)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: step.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(active ? Color.white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(active ? AnyShapeStyle(Brand.diagonal) : AnyShapeStyle(Color.accentColor.opacity(0.12)), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.headline)
                    summary
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if !active {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.canShow(step))
        .accessibilityAddTraits(active ? [.isHeader, .isSelected] : .isHeader)
    }

    private var summary: Text {
        let draft = model.draft
        switch step {
        case .media:
            return draft.media.isEmpty ? Text("No photos or videos yet") : Text("\(draft.media.count) selected")
        case .length:
            let length = Text(Formatting.duration(draft.targetDuration))
            return draft.lengthChoice == .auto ? Text("Auto") + Text(verbatim: " · ") + length : length
        case .style:
            let style = Text(draft.style.title)
            guard let song = draft.song else { return style }
            return style + Text(verbatim: " · ") + Text(verbatim: song.title)
        case .generate:
            if model.generation != nil { return Text("Creating film") }
            guard model.hasFilm, let edl = draft.edl else { return Text("No film yet") }
            return Text(Formatting.duration(edl.duration))
        case .export:
            switch model.export?.phase {
            case .exporting?: return Text("Rendering…")
            case .finished?: return Text("Ready to save or share")
            default: return model.hasFilm ? Text("Save to Photos or share") : Text("No film yet")
            }
        }
    }
}

/// What an open step shows: the same choices as the step's own screen on a phone.
private struct StepContent: View {
    @Environment(AppModel.self) private var model
    let step: FlowStep

    var body: some View {
        switch step {
        case .media: mediaContent
        case .length: lengthContent
        case .style: styleContent
        case .generate: generateContent
        case .export: exportContent
        }
    }

    // MARK: Media

    @ViewBuilder
    private var mediaContent: some View {
        let draft = model.draft
        Section {
            if draft.media.isEmpty {
                Text("Pick photos and videos in the library, choose a length and get a finished film with music.")
                    .foregroundStyle(.secondary)
            } else {
                SelectedMediaSummary(draft: draft)
                // Enough for about this long a film with the chosen song.
                let maximum = Planner.maximumDuration(of: draft.mediaItems, beatPeriod: draft.song.map { 60 / max(1, $0.info.bpm) })
                Label("Enough for a film of up to \(Formatting.duration(maximum))", systemImage: "film")
                    .font(.subheadline)
            }
            MediaImportStatus()
            if !draft.media.isEmpty {
                // Even columns, so that a fold through the panel falls between two.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(draft.media) { media in
                        MediaThumbnail(media: media)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        if !draft.media.isEmpty {
            Section {
                primaryButton("Next", systemImage: "arrow.right", disabled: model.imports.isBusy) {
                    model.show(.length)
                }
                Button("Start over", role: .destructive) { model.startOver() }
                    .disabled(model.isEditing)
            }
        }
    }

    // MARK: Length

    @ViewBuilder
    private var lengthContent: some View {
        Section {
            LengthOptions(draft: model.draft)
                .padding(.vertical, 8)
        }
        Section {
            primaryButton("Next", systemImage: "arrow.right") { model.show(.style) }
        }
    }

    // MARK: Style and music

    @ViewBuilder
    private var styleContent: some View {
        let draft = model.draft
        // Changing a film that exists, as Change style and Change music do on a phone: Cancel
        // puts the film's choices back.
        let changing = model.sheet == .style || model.sheet == .music
        StyleSections(draft: draft, describing: model.directorAvailable)
        Section {
            primaryButton("Create film", systemImage: "wand.and.stars", disabled: draft.analysingSong) {
                model.createFilm()
            }
            if changing {
                Button("Cancel", role: .cancel) { model.cancelChange() }
                    .disabled(draft.analysingSong)
            }
        }
    }

    // MARK: Generate

    @ViewBuilder
    private var generateContent: some View {
        if let job = model.generation {
            Section {
                if let message = job.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                    Button("Back") { model.cancelGeneration() }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.step.title)
                            .font(.headline)
                        ProgressView(value: Double(job.steps.firstIndex(of: job.step) ?? 0), total: Double(max(1, job.steps.count)))
                    }
                    .accessibilityElement(children: .combine)
                    Button("Cancel", role: .cancel) { model.cancelGeneration() }
                }
            }
        } else {
            let disabled = model.preview == nil || model.isEditing
            Section {
                Button {
                    model.createFilm(newVersion: true)
                } label: {
                    Label("Another version", systemImage: "shuffle")
                }
                .disabled(disabled)
                Button {
                    model.openTexts()
                } label: {
                    Label("Title and credits", systemImage: "textformat")
                }
                .disabled(disabled)
            } footer: {
                Text("Drag to reorder · swipe up to remove · touch and hold to lock")
            }
            Section {
                primaryButton("Export", systemImage: "square.and.arrow.up", disabled: disabled) {
                    model.show(.export)
                }
            }
        }
    }

    // MARK: Export

    @ViewBuilder
    private var exportContent: some View {
        if let job = model.export {
            ExportSections(job: job)
        }
    }

    private func primaryButton(
        _ title: LocalizedStringKey, systemImage: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(disabled)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}
