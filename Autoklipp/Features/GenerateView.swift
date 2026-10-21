import SwiftUI

/// Step 4: generation with visible steps; can be cancelled.
struct GenerateView: View {
    @Environment(AppModel.self) private var model
    @State private var step: GenerationStep = .analysing
    @State private var fraction = 0.0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Back") { goBack() }
                    .buttonStyle(.borderedProminent)
            } else {
                if step == .analysing, fraction > 0 {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(steps, id: \.self) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .foregroundStyle(item.rawValue <= step.rawValue ? Color.accentColor : .secondary)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(item == step ? .headline : .body)
                                .foregroundStyle(item.rawValue <= step.rawValue ? .primary : .secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(item == step ? .updatesFrequently : [])
                    }
                }
                Button("Cancel", role: .cancel) { goBack() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Creating film")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task { await generate() }
    }

    private var steps: [GenerationStep] {
        let draft = model.draft
        return GenerationStep.steps(directed: !draft.instructionInEffect.isEmpty && draft.directorPlan == nil)
    }

    private func icon(for item: GenerationStep) -> String {
        if item.rawValue < step.rawValue { return "checkmark.circle.fill" }
        if item == step { return "circle.dotted" }
        return "circle"
    }

    private func generate() async {
        let draft = model.draft
        draft.forgetDirectorPlanIfStale()
        let input = GenerationInput(draft: draft)
        let settings = RenderSettings.preview(draft.format)
        do {
            let output = try await FilmGenerator.generate(input, settings: settings) { newStep, newFraction in
                await MainActor.run {
                    step = newStep
                    fraction = newFraction
                }
            }
            try Task.checkCancellation()
            draft.adopt(output, from: input)
            model.preview?.player.pause()
            model.preview = PreviewSession(edl: output.edl, built: output.built)
            model.save()
            if model.path.last == .generate {
                model.path.removeLast()
                // A new version replaces the film in the preview underneath.
                if model.path.last != .preview { model.path.append(.preview) }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? FilmGenerator.GenerationError)?.errorDescription ?? AppModel.buildFailedMessage
        }
    }

    /// Back to where the run started: the style step, or the film that was shown before.
    private func goBack() {
        if model.path.last == .generate { model.path.removeLast() }
    }
}
