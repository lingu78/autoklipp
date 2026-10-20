import os

/// Process-wide facts the compositor needs while it renders on its own queue.
enum RenderEnvironment {
    private static let background = OSAllocatedUnfairLock(initialState: false)

    /// iOS does not allow GPU work in the background, so rendering switches to the CPU.
    static var isInBackground: Bool {
        background.withLock { $0 }
    }

    static func setInBackground(_ value: Bool) {
        background.withLock { $0 = value }
    }
}
