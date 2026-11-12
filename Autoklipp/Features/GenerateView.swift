import SwiftUI

/// Step 4: generation with visible steps; can be cancelled. The model runs it, so it carries on
/// when the layout changes. Shown over the app's drifting gradient, the making of the film is a
/// moment of its own rather than a spinner.
struct GenerateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HeroBackground(animated: !reduceMotion)
                .ignoresSafeArea()
            if let job = model.generation {
                GenerationProgressView(job: job)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Creating film")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .flowActions([GenerationProgressView.leaveAction(model)])
        // The button under the gradient dark too.
        .environment(\.colorScheme, .dark)
    }
}

/// The steps of making the film, or what went wrong, in white for the gradient behind it.
struct GenerationProgressView: View {
    let job: GenerationJob
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 32) {
            if let errorMessage = job.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .accessibilityHidden(true)
                Text(errorMessage)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } else {
                // The mark's frames fan out and back while the film is made.
                AutoklippMark(size: 132, spread: breathing ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: breathing)
                    .onAppear { breathing = true }
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(job.step.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .animation(.snappy, value: job.step)
                    if job.step == .analysing, job.fraction > 0 {
                        ProgressView(value: job.fraction)
                            .tint(.white)
                            .frame(maxWidth: 240)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(job.steps, id: \.self) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .symbolEffect(.pulse, isActive: item == job.step && !reduceMotion)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(item == job.step ? .headline : .body)
                        }
                        .opacity(item.rawValue <= job.step.rawValue ? 1 : 0.6)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(item == job.step ? .updatesFrequently : [])
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 420)
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
