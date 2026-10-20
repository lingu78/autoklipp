import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            MediaSelectionView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .length: LengthView()
                    case .style: StyleView()
                    case .generate: GenerateView()
                    case .preview: PreviewView()
                    }
                }
        }
    }
}
