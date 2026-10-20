import AVFoundation
import SwiftData
import SwiftUI

@main
struct AutoklippApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Films and music previews should be heard even with the ring switch on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.container)
        }
        .onChange(of: scenePhase) { _, phase in
            // The compositor switches to CPU rendering while the GPU is off limits.
            RenderEnvironment.setInBackground(phase == .background)
        }
    }
}
