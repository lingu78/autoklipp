import Foundation
import UIKit
import UserNotifications

/// The background time ran out before an export was done.
struct BackgroundTimeExpired: LocalizedError {
    var errorDescription: String? {
        String(localized: "Autoklipp was in the background for too long. Keep the app open while the film is exported.")
    }
}

/// Keeps an export alive briefly in the background and tells the user when it is done.
@MainActor
enum FinishNotifier {
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Runs `work` inside a background task so it can finish if the app is sent away. If the
    /// background time runs out first, the work is cancelled and the task ended at once (iOS
    /// terminates an app that holds on to it), the user is told, and `BackgroundTimeExpired`
    /// is thrown.
    static func runAllowingBackground<T: Sendable>(
        _ name: String, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await work() }
        let background = BackgroundTaskHandle()
        background.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                task.cancel()
                background.expired = true
                FinishNotifier.notifyIfInBackground(
                    title: String(localized: "The export was interrupted"),
                    body: BackgroundTimeExpired().errorDescription ?? ""
                )
                background.end()
            }
        }
        defer { background.end() }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if background.expired { throw BackgroundTimeExpired() }
            throw error
        }
    }

    /// Posts a notification if the app is not in front.
    static func notifyIfInBackground(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// A background task that is ended exactly once, by the work or by the expiration handler.
@MainActor
private final class BackgroundTaskHandle {
    var identifier = UIBackgroundTaskIdentifier.invalid
    var expired = false

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
