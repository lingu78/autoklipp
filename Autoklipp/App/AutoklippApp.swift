import AVFoundation
import SwiftData
import SwiftUI
import UIKit

@main
struct AutoklippApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            // Apple Intelligence may have been turned on or finished downloading meanwhile.
            if phase == .active { model.refreshDirectorAvailability() }
        }
    }
}

/// Keeps the app upright on phone-sized displays, as before, and lets it turn with the device
/// on a large display such as iPhone Duo's inner display, which is wider than tall when the
/// device opens like a book. Decided from size classes, not from the device model.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let traits = window?.windowScene?.traitCollection
            ?? application.connectedScenes.compactMap { ($0 as? UIWindowScene)?.traitCollection }.first
        guard let traits else { return .portrait }
        return Self.orientations(horizontal: traits.horizontalSizeClass, vertical: traits.verticalSizeClass)
    }

    static func orientations(horizontal: UIUserInterfaceSizeClass, vertical: UIUserInterfaceSizeClass) -> UIInterfaceOrientationMask {
        horizontal == .regular && vertical == .regular ? .allButUpsideDown : .portrait
    }

    /// Asks the system again, e.g. after the app moved to the other display.
    @MainActor
    static func refreshOrientations() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
