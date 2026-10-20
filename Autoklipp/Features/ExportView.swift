import ClipCore
import SwiftUI

/// Step 6: render at full quality, then save to Photos or share.
struct ExportView: View {
    let edl: EditDecisionList
    let draft: ProjectDraft

    @Environment(\.dismiss) private var dismiss
    @State private var format: AspectFormat = .portrait
    @State private var resolution: Resolution = .hd1080
    @State private var phase: Phase = .choosing
    @State private var progress = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var saved = false
    @State private var message: String?

    enum Phase: Equatable {
        case choosing
        case exporting
        case finished(URL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        Text("9:16 portrait").tag(AspectFormat.portrait)
                        Text("16:9 landscape").tag(AspectFormat.landscape)
                        Text("1:1 square").tag(AspectFormat.square)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Picker("Resolution", selection: $resolution) {
                        Text("1080p").tag(Resolution.hd1080)
                        Text("4K").tag(Resolution.uhd4k)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(phase != .choosing)

                Section {
                    switch phase {
                    case .choosing:
                        Button {
                            startExport()
                        } label: {
                            Label("Export film", systemImage: "film.stack")
                                .font(.headline)
                        }
                    case .exporting:
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("Rendering… \(progress.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Button("Cancel", role: .cancel) {
                            exportTask?.cancel()
                        }
                    case let .finished(url):
                        Button {
                            Task { await save(url) }
                        } label: {
                            Label(
                                saved ? LocalizedStringKey("Saved to Photos") : LocalizedStringKey("Save to Photos"),
                                systemImage: saved ? "checkmark.circle.fill" : "photo.badge.plus"
                            )
                        }
                        .disabled(saved)
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                } footer: {
                    if let message {
                        Text(message)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        exportTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { format = draft.format }
            .interactiveDismissDisabled(phase == .exporting)
        }
    }

    private func startExport() {
        phase = .exporting
        progress = 0
        message = nil
        saved = false
        let edl = edl
        let media = draft.media
        let song = draft.song
        let settings = RenderSettings(format: format, resolution: resolution)
        let folder = draft.storage.exportDirectory
        exportTask = Task {
            await FinishNotifier.requestPermissionIfNeeded()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: "Autoklipp-\(Int(Date().timeIntervalSince1970)).mp4")
                try await FinishNotifier.runAllowingBackground("Export") {
                    let built = try await FilmGenerator.build(edl, media: media, song: song, settings: settings)
                    try await VideoExporter.export(built, resolution: settings.resolution, to: url) { value in
                        Task { @MainActor in progress = value }
                    }
                }
                try Task.checkCancellation()
                phase = .finished(url)
                FinishNotifier.notifyIfInBackground(
                    title: String(localized: "Your film is ready"),
                    body: String(localized: "Open Autoklipp to save or share it.")
                )
            } catch is CancellationError {
                phase = .choosing
            } catch {
                phase = .choosing
                message = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    private func save(_ url: URL) async {
        do {
            try await PhotoLibrarySaver.save(videoAt: url)
            saved = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
