import SwiftUI

/// Picks the layout from the space the app has (size class and width, never the device model)
/// and keeps the film's playback in step with what is on screen.
///
/// Folding or unfolding iPhone Duo, rotating it and Split View only resize the window: the
/// layout's views are replaced, while everything they show lives in AppModel and carries over,
/// the running import, film, export and playback included.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let layout = FlowLayout.choose(horizontalSizeClass: horizontalSizeClass, width: proxy.size.width)
            Group {
                switch layout {
                case .stack: FlowStack()
                case .columns: WorkspaceStack()
                }
            }
            .onChange(of: layout, initial: true) { _, layout in
                model.layout = layout
            }
        }
        // Only leaving the film pauses it; a new layout showing it again keeps it playing.
        .onChange(of: model.isFilmOnScreen) { _, onScreen in
            if !onScreen { model.preview?.player.pause() }
        }
        .onChange(of: model.path.isEmpty) { _, isEmpty in
            if isEmpty { model.leftFlow() }
        }
        // Moving to the other display changes which orientations the app supports.
        .onChange(of: horizontalSizeClass) { _, _ in
            AppDelegate.refreshOrientations()
        }
    }
}

/// One screen at a time: iPhone, iPhone Duo's outer display and narrow Split View.
struct FlowStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .media: MediaSelectionView()
                    case .length: LengthView()
                    case .style: StyleView()
                    case .generate: GenerateView()
                    case .preview: PreviewView()
                    }
                }
        }
    }
}

/// The start screen, then the film and the steps side by side: iPhone Duo's inner display.
struct WorkspaceStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: Binding(
            get: { model.path.isEmpty ? [] : [WorkspaceRoute()] },
            set: { if $0.isEmpty { model.path = [] } }
        )) {
            HomeView()
                .navigationDestination(for: WorkspaceRoute.self) { _ in
                    WorkspaceView()
                }
        }
    }
}

/// The whole flow as one destination in the two-column layout.
struct WorkspaceRoute: Hashable {}
