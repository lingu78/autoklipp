import ClipCore
import SwiftUI
import UIKit

/// Step 6 as a sheet: render at full quality, then save to Photos or share. The model owns the
/// export, so it keeps running, and the sheet comes back, when the layout changes.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    let job: ExportJob

    var body: some View {
        NavigationStack {
            Form {
                ExportSections(job: job)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.closeExport()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// The export's choices and actions, in the sheet or in the side panel.
struct ExportSections: View {
    @Environment(AppModel.self) private var model
    @Bindable var job: ExportJob

    var body: some View {
        Section("Format") {
            Picker("Format", selection: $job.format) {
                Text("9:16 portrait").tag(AspectFormat.portrait)
                Text("16:9 landscape").tag(AspectFormat.landscape)
                Text("1:1 square").tag(AspectFormat.square)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Picker("Resolution", selection: $job.resolution) {
                Text("1080p").tag(Resolution.hd1080)
                Text("4K").tag(Resolution.uhd4k)
            }
            .pickerStyle(.segmented)
        }
        .disabled(job.phase != .choosing)

        Section {
            switch job.phase {
            case .choosing:
                Button {
                    if let edl = model.preview?.edl { job.start(edl) }
                } label: {
                    Label("Export film", systemImage: "film.stack")
                        .font(.headline)
                }
                // The film shown is the one exported; an edit still being made would change it.
                .disabled(model.preview == nil || model.isEditing)
            case .exporting:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: job.progress)
                    Text("Rendering… \(job.progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button("Cancel", role: .cancel) {
                    job.cancel()
                }
            case let .finished(url):
                Button {
                    Task { await job.saveToPhotos(url) }
                } label: {
                    Label(
                        job.saved ? LocalizedStringKey("Saved to Photos") : LocalizedStringKey("Save to Photos"),
                        systemImage: job.saved ? "checkmark.circle.fill" : "photo.badge.plus"
                    )
                }
                .disabled(job.saved || job.saving)
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if let message = job.message {
                Text(message)
            }
        }
    }
}
