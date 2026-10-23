import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()

    func configure() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func notify(watch: PickupWatch, results: [PickupResult]) async {
        let available = results.filter { !$0.configurations.isEmpty }
        guard !available.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(watch.product.name) is ready for pickup"
        content.body = available.map(\.storeName).joined(separator: ", ")
        content.sound = .default
        content.userInfo = ["watchID": watch.id.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: watch.id.uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let watchID = response.notification.request.content.userInfo["watchID"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .openPickupWatch, object: watchID)
        }
    }
}

extension Notification.Name {
    static let openPickupWatch = Notification.Name("openPickupWatch")
}
