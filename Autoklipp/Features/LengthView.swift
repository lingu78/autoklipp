import ClipCore
import SwiftUI

/// Step 2: choose how long the film should be.
struct LengthView: View {
    @Environment(AppModel.self) private var model
    @State private var customSeconds: Double = 90

    private var draft: ProjectDraft { model.draft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("How long should the film be?")
                    .font(.title2.bold())

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

                let maximum = Planner.maximumDuration(of: draft.mediaItems)
                if draft.targetDuration > maximum + Timing.lengthTolerance {
                    Label(
                        "Your photos and videos are enough for about \(Formatting.duration(maximum)). The film will be shorter unless you add more.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Length")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.path.append(.style)
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
        .onAppear {
            if case let .custom(seconds) = draft.lengthChoice { customSeconds = seconds }
        }
    }

    private func choiceButton(_ choice: LengthChoice, title: Text, detail: Text?) -> some View {
        let selected = draft.lengthChoice == choice
        return Button {
            draft.lengthChoice = choice
        } label: {
            VStack(spacing: 2) {
                title.font(.headline)
                if let detail {
                    detail.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
