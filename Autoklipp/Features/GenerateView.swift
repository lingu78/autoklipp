import SwiftUI

/// Step 4: generation with visible steps; can be cancelled. The model runs it, so it carries on
/// when the layout changes.
struct GenerateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            if let job = model.generation {
                GenerationProgressView(job: job)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
        .navigationTitle("Creating film")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .flowActions([GenerationProgressView.leaveAction(model)])
    }
}

/// The steps of making the film, or what went wrong.
struct GenerationProgressView: View {
    let job: GenerationJob

    var body: some View {
        VStack(spacing: 28) {
            if let errorMessage = job.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } else {
                if job.step == .analysing, job.fraction > 0 {
                    ProgressView(value: job.fraction)
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(job.steps, id: \.self) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .foregroundStyle(item.rawValue <= job.step.rawValue ? Color.accentColor : .secondary)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(item == job.step ? .headline : .body)
                                .foregroundStyle(item.rawValue <= job.step.rawValue ? .primary : .secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(item == job.step ? .updatesFrequently : [])
                    }
                }
            }
        }
    }

    private func icon(for item: GenerationStep) -> String {
        if item.rawValue < job.step.rawValue { return "checkmark.circle.fill" }
        if item == job.step { return "circle.dotted" }
        return "circle"
    }

    /// Cancel while the film is being made, Back after an error.
    @MainActor
    static func leaveAction(_ model: AppModel) -> FlowAction {
        if model.generation?.errorMessage != nil {
            return FlowAction("Back", systemImage: "chevron.backward", kind: .cancel) { model.cancelGeneration() }
        }
        return FlowAction("Cancel", systemImage: "xmark", kind: .cancel) { model.cancelGeneration() }
    }
}
