import SwiftData
import SwiftUI

/// Start screen: a new film, or one of the saved ones (F15).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SavedProject.updatedAt, order: .reverse) private var projects: [SavedProject]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pick photos and videos, choose a length and get a finished film with music.")
                        .foregroundStyle(.secondary)
                    Button {
                        model.newProject()
                    } label: {
                        Label("New film", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            }

            if !projects.isEmpty {
                Section("Your films") {
                    ForEach(projects) { project in
                        Button {
                            model.open(project)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.delete(projects[index]) }
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: "Autoklipp"))
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.message != nil && model.path.isEmpty }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

private struct ProjectRow: View {
    let project: SavedProject

    var body: some View {
        HStack(spacing: 12) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 56, height: 56)
                .overlay {
                    if let data = project.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(.headline)
                Text("\(Formatting.duration(project.duration)) · \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
