import SwiftData
import SwiftUI

/// Start screen: what the app does, a new film, and the saved ones (F15).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \SavedProject.updatedAt, order: .reverse) private var projects: [SavedProject]
    @State private var appeared = false
    @State private var projectToDelete: SavedProject?

    var body: some View {
        ScrollView {
            // The content sheet slides a little over the hero.
            VStack(spacing: -28) {
                hero
                content
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(Text(verbatim: "Autoklipp"))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(duration: 0.9, bounce: 0.35).delay(0.15)) { appeared = true }
            }
        }
        .confirmationDialog(
            Text("Delete this film?"),
            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
            titleVisibility: .visible,
            presenting: projectToDelete
        ) { project in
            Button("Delete film", role: .destructive) { model.delete(project) }
        } message: { _ in
            Text("The film and its copies of your photos and videos are removed from Autoklipp. The originals in Photos stay.")
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.message != nil && model.path.isEmpty }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 16) {
            AutoklippMark(size: 124, spread: appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text(verbatim: "Autoklipp")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            Text("Your photos and videos become a finished film, cut to the beat of the music.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.newProject()
            } label: {
                Label("New film", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(Brand.deep)
                    .frame(maxWidth: 360)
                    .padding(.vertical, 16)
                    .background(.white, in: .capsule)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .buttonStyle(PressScale())
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .shadow(color: Brand.plum.opacity(0.35), radius: 8, y: 2)
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity)
        // Reaches up under the status bar and into the pull-down overscroll.
        .background(alignment: .bottom) {
            HeroBackground(animated: !reduceMotion)
                .padding(.top, -400)
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 32) {
            if !projects.isEmpty {
                films
            }
            steps
            Label {
                Text("Everything is processed on your iPhone. Nothing is uploaded.")
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
        }
        .padding(.top, 28)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .systemBackground),
            in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
        )
    }

    private var films: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your films")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(projects) { project in
                        Button {
                            model.open(project)
                        } label: {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(PressScale())
                        .contextMenu {
                            Button(role: .destructive) {
                                projectToDelete = project
                            } label: {
                                Label("Delete film", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: Text("Delete film")) { projectToDelete = project }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How it works")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            StepRow(
                symbol: "photo.on.rectangle.angled",
                title: LocalizedStringKey("Pick photos and videos"),
                detail: LocalizedStringKey("Up to 200 at a time, straight from Photos.")
            )
            StepRow(
                symbol: "slider.horizontal.3",
                title: LocalizedStringKey("Choose length and style"),
                detail: LocalizedStringKey("From 15 seconds to 10 minutes, calm or full of energy.")
            )
            StepRow(
                symbol: "sparkles",
                title: LocalizedStringKey("Get a finished film"),
                detail: LocalizedStringKey("Cut on the beat with transitions and music. Adjust it, then save or share.")
            )
        }
        .padding(.horizontal, 20)
    }
}

/// Colours of the app icon's gradient.
private enum Brand {
    static let orange = Color(red: 238 / 255, green: 110 / 255, blue: 64 / 255)
    static let coral = Color(red: 232 / 255, green: 82 / 255, blue: 82 / 255)
    static let raspberry = Color(red: 214 / 255, green: 54 / 255, blue: 107 / 255)
    static let deep = Color(red: 176 / 255, green: 32 / 255, blue: 100 / 255)
    static let plum = Color(red: 128 / 255, green: 24 / 255, blue: 90 / 255)
}

/// The icon's mark: three stacked frames with a play symbol. `spread` fans the frames out
/// from a single stack (0) to the icon's layout (1).
private struct AutoklippMark: View {
    let size: CGFloat
    let spread: CGFloat

    var body: some View {
        ZStack {
            frame(opacity: 0.3, step: 2)
            frame(opacity: 0.55, step: 1)
            frame(opacity: 1, step: 0)
                .overlay {
                    PlayTriangle()
                        .fill(Brand.raspberry)
                        .frame(width: size * 0.166, height: size * 0.186)
                        .offset(x: size * (-0.051 + 0.015), y: size * 0.076)
                }
                .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.015)
        }
        .frame(width: size, height: size)
    }

    /// As in the icon: the front frame sits left of and below the centre, and each frame
    /// behind it is a step up and to the right.
    private func frame(opacity: Double, step: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.047, style: .continuous)
            .fill(.white.opacity(opacity))
            .frame(width: size * 0.508, height: size * 0.352)
            .offset(x: size * (-0.051 + 0.049 * step * spread), y: size * (0.076 - 0.078 * step * spread))
    }
}

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The icon's warm gradient, drifting slowly unless motion is reduced.
private struct HeroBackground: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let dx = Float(animated ? 0.12 * sin(time * 0.35) : 0)
            let dy = Float(animated ? 0.08 * cos(time * 0.27) : 0)
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Brand.orange, Brand.orange, Brand.coral,
                    Brand.coral, Brand.raspberry, Brand.deep,
                    Brand.raspberry, Brand.deep, Brand.plum,
                ]
            )
        }
    }
}

private struct ProjectCard: View {
    let project: SavedProject

    var body: some View {
        let updated = project.updatedAt.formatted(.relative(presentation: .named))
        VStack(alignment: .leading, spacing: 8) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 150, height: 190)
                .overlay {
                    if let data = project.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(Formatting.clock(project.duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(8)
                }
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            Text(project.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(updated)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(project.title), \(Formatting.duration(project.duration)), \(updated)"))
    }
}

private struct StepRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(colors: [Brand.coral, Brand.deep], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shrinks a little while pressed.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
