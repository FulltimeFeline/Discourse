#if os(iOS)
import UIKit
import UserNotifications

/// Bridges APNs registration to the active session's Matrix pusher. The device
/// token and the active service arrive independently, so registration fires
/// whenever both are present (and a gateway is configured).
@MainActor
final class PushRegistry {
    static let shared = PushRegistry()

    private var deviceTokenHex: String?
    private weak var service: MatrixService?

    private var gatewayConfigured: Bool { !PushConfig.pushGatewayURL.contains("example.com") }

    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func setDeviceToken(_ hex: String) {
        deviceTokenHex = hex
        register()
    }

    func setActiveService(_ service: MatrixService?) {
        self.service = service
        register()
    }

    private func register() {
        guard gatewayConfigured, let deviceTokenHex, let service else { return }
        Task { await service.registerPusher(deviceTokenHex: deviceTokenHex) }
    }
}

/// SwiftUI has no direct APNs hook, so a small app delegate captures the token.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in PushRegistry.shared.requestAuthorizationAndRegister() }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushRegistry.shared.setDeviceToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
