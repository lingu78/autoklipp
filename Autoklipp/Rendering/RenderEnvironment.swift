import os
import UIKit

/// Process-wide facts the compositor needs while it renders on its own queue.
enum RenderEnvironment {
    private struct State {
        /// The scene phase is `.background`.
        var sceneInBackground = false
        /// Between UIKit's "will resign active" and "did become active".
        var inactive = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// iOS does not allow GPU work in the background, so rendering switches to the CPU. It
    /// switches as soon as the app stops being active: the scene phase reports `.background`
    /// only once the app is already there, and GPU frames rendered meanwhile come out blank.
    static var isInBackground: Bool {
        _ = observing
        return state.withLock { $0.sceneInBackground || $0.inactive }
    }

    static func setInBackground(_ value: Bool) {
        _ = observing
        state.withLock { $0.sceneInBackground = value }
    }

    /// UIKit posts these on the main thread, before the app moves to the background.
    private static let observing: Bool = {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            RenderEnvironment.state.withLock { $0.inactive = true }
        }
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            RenderEnvironment.state.withLock { $0.inactive = false }
        }
        return true
    }()
}
