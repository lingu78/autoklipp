import Foundation
import UIKit
import UserNotifications

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

    /// Runs `work` inside a background task so it can finish if the app is sent away.
    static func runAllowingBackground<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name)
        defer {
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        }
        return try await work()
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
