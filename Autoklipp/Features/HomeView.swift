import SwiftData
import SwiftUI

/// Start screen: what the app does, a new film, and the saved ones (F15).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \SavedProject.updatedAt, order: .reverse) private var projects: [SavedProject]
    @State private var appeared = false
    @State private var projectToDelete: SavedProject?
    @State private var newFilmTaps = 0

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
                newFilmTaps += 1
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
            .sensoryFeedback(.impact(weight: .medium), trigger: newFilmTaps)
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .shadow(color: Brand.plum.opacity(0.35), radius: 8, y: 2)
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity)
        // Reaches up under the status bar and into the pull-down overscroll, and out to the
        // display's edges, also under bars the system puts on the side.
        .background(alignment: .bottom) {
            HeroBackground(animated: !reduceMotion)
                .padding(.top, -400)
                .ignoresSafeArea(edges: .horizontal)
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
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .padding(.bottom, -400)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
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
                        // Cards ease in and out at the edges of the row.
                        .scrollTransition(.interactive, axis: .horizontal) { card, phase in
                            card
                                .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                .opacity(phase.isIdentity ? 1 : 0.75)
                        }
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
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
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

private struct ProjectCard: View {
    let project: SavedProject

    var body: some View {
        let updated = project.updatedAt.formatted(.relative(presentation: .named))
        VStack(alignment: .leading, spacing: 8) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 168, height: 220)
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
                .clipShape(.rect(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            Text(project.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(updated)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 168, alignment: .leading)
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
