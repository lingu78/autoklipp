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
            HStack(spacing: 10) {
                FormatTile(format: .portrait, title: Text("9:16 portrait"), selection: $job.format)
                FormatTile(format: .landscape, title: Text("16:9 landscape"), selection: $job.format)
                FormatTile(format: .square, title: Text("1:1 square"), selection: $job.format)
            }
            .padding(.vertical, 6)
            .sensoryFeedback(.selection, trigger: job.format)
            // A tap from the phone when the film is ready, and again when it is in Photos.
            .sensoryFeedback(trigger: job.phase) { _, phase in
                guard case .finished = phase else { return nil }
                return .success
            }
            .sensoryFeedback(.success, trigger: job.saved)
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                // The film shown is the one exported; an edit still being made would change it.
                .disabled(model.preview == nil || model.isEditing)
            case .exporting:
                VStack(spacing: 10) {
                    Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: job.progress))
                        .animation(.snappy, value: job.progress)
                    ProgressView(value: job.progress)
                    Text("Rendering…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
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
                    .contentTransition(.symbolEffect(.replace))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .disabled(job.saved || job.saving)
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        } footer: {
            if let message = job.message {
                Text(message)
            }
        }
    }
}

/// A format as a small frame in its own proportions.
private struct FormatTile: View {
    let format: AspectFormat
    let title: Text
    @Binding var selection: AspectFormat

    var body: some View {
        let selected = selection == format
        Button {
            withAnimation(.snappy) { selection = format }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.diagonal) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)))
                    .frame(width: frame.width, height: frame.height)
                    .frame(height: 62)
                title
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var frame: CGSize {
        switch format {
        case .portrait: CGSize(width: 33, height: 58)
        case .landscape: CGSize(width: 58, height: 33)
        case .square: CGSize(width: 46, height: 46)
        }
    }
}
