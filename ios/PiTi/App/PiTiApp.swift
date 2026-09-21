import SwiftUI

@main
struct PiTiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            PiTiWebView()
                .onOpenURL { url in
                    guard url.scheme == "piti", let page = url.host else { return }
                    PushNotificationManager.shared.open(["page": page])
                }
        }
    }
}
