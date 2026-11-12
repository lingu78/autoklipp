import ClipCore
import SwiftUI

/// Step 2: choose how long the film should be.
struct LengthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LengthOptions(draft: model.draft)
                .padding()
        }
        .navigationTitle("Length")
        .navigationBarTitleDisplayMode(.inline)
        .flowActions([
            FlowAction("Next", systemImage: "arrow.right", kind: .primary) { model.path.append(.style) },
        ])
    }
}

/// The length choices, on their own screen or in the side panel.
struct LengthOptions: View {
    let draft: ProjectDraft
    @State private var customSeconds: Double = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // The length chosen, large: what the whole step is about.
            VStack(spacing: 4) {
                Text(Formatting.clock(draft.targetDuration))
                    .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: draft.targetDuration))
                    .foregroundStyle(Brand.diagonal)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("How long should the film be?")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("How long should the film be?"))
            .accessibilityValue(Text(Formatting.duration(draft.targetDuration)))
            .animation(.snappy, value: draft.targetDuration)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                choiceButton(.auto, title: Text("Auto"), detail: Text(Formatting.duration(AutoLength.suggest(for: draft.mediaItems))))
                ForEach(ProjectDraft.presetLengths, id: \.self) { seconds in
                    choiceButton(.preset(seconds), title: Text(Formatting.duration(seconds)), detail: nil)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom length: \(Formatting.duration(customSeconds))")
                    .font(.headline)
                Slider(value: $customSeconds, in: AutoLength.range, step: 5) {
                    Text("Custom length")
                } minimumValueLabel: {
                    Text(Formatting.duration(AutoLength.range.lowerBound))
                } maximumValueLabel: {
                    Text(Formatting.duration(AutoLength.range.upperBound))
                }
                .accessibilityValue(Text(Formatting.duration(customSeconds)))
                .onChange(of: customSeconds) { _, seconds in
                    draft.lengthChoice = .custom(seconds)
                }
            }

            // Stills are shown for whole beats of the song, so the song decides how long they can be.
            let maximum = Planner.maximumDuration(of: draft.mediaItems, beatPeriod: draft.song.map { 60 / max(1, $0.info.bpm) })
            if draft.targetDuration > maximum + Timing.lengthTolerance {
                Label(
                    "Your photos and videos are enough for about \(Formatting.duration(maximum)). The film will be shorter unless you add more.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if case let .custom(seconds) = draft.lengthChoice { customSeconds = seconds }
        }
        // A tick for each choice; the custom slider moves in steps of its own.
        .sensoryFeedback(.selection, trigger: chosenButton)
    }

    /// The choice button that is on, if any.
    private var chosenButton: LengthChoice? {
        if case .custom = draft.lengthChoice { return nil }
        return draft.lengthChoice
    }

    private func choiceButton(_ choice: LengthChoice, title: Text, detail: Text?) -> some View {
        let selected = draft.lengthChoice == choice
        return Button {
            withAnimation(.snappy) { draft.lengthChoice = choice }
        } label: {
            VStack(spacing: 2) {
                title.font(.headline)
                if let detail {
                    detail.font(.caption)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.diagonal) : AnyShapeStyle(Color(uiColor: .secondarySystemFill)))
            }
            .shadow(color: Brand.deep.opacity(selected ? 0.3 : 0), radius: 8, y: 4)
            .scaleEffect(selected ? 1.03 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
