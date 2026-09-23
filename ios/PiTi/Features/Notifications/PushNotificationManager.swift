import UIKit
import UserNotifications

@MainActor
final class PushNotificationManager {
    static let shared = PushNotificationManager()
    private init() {}
    private(set) var currentToken: String?
    private(set) var pendingRoute: [String: String]?
    private(set) var permission = "notDetermined"

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }
    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.permission = "authorized"
                case .denied: self.permission = "denied"
                default: self.permission = "notDetermined"
                }
                if self.permission == "authorized" { UIApplication.shared.registerForRemoteNotifications() }
                self.changed()
            }
        }
    }
    func received(deviceToken: Data) {
        // APNs tokens may change. Request each launch; never cache on disk.
        currentToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        changed()
    }
    func registrationFailed(_ error: Error) {
        currentToken = nil
        permission = "registrationFailed"
        changed()
    }
    func open(_ route: [String: String]) {
        guard let page = route["page"], ["calendar", "messages", "finance", "profile", "today", "dashboard"].contains(page) else { return }
        pendingRoute = route
        changed()
    }
    func clearRoute(ifMatching route: [String: String]) {
        if pendingRoute == route { pendingRoute = nil }
    }
    private func changed() {
        NotificationCenter.default.post(name: .pitiNativeChanged, object: nil)
    }
}
extension Notification.Name {
    static let pitiNativeChanged = Notification.Name("piti.native-changed")
}
