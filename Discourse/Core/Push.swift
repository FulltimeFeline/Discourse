#if os(iOS)
import UIKit
import UserNotifications
import os

/// Bridges APNs registration to the active session's Matrix pusher. The device
/// token and the active service arrive independently, so registration fires
/// whenever both are present (and a gateway is configured).
@MainActor
final class PushRegistry {
    static let shared = PushRegistry()

    private var pushkey: String?
    private weak var service: MatrixService?

    private let log = Logger(subsystem: "dev.discourse.push", category: "registry")

    private var gatewayConfigured: Bool { !PushConfig.pushGatewayURL.contains("example.com") }

    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [log] granted, error in
            log.info("authorization granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func setDeviceToken(_ pushkey: String) {
        self.pushkey = pushkey
        register()
    }

    func setActiveService(_ service: MatrixService?) {
        self.service = service
        register()
    }

    private func register() {
        guard gatewayConfigured else { log.error("gateway not configured: \(PushConfig.pushGatewayURL, privacy: .public)"); return }
        guard let pushkey else { log.info("waiting for APNs device token"); return }
        guard let service else { log.info("waiting for active session"); return }
        log.info("registering pusher (token+service+gateway ready)")
        Task { await service.registerPusher(pushkey: pushkey) }
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
        // Base64, NOT hex: sygnal's default `convert_device_token_to_hex: true`
        // base64-decodes the pushkey. Sending hex makes it decode garbage, and
        // APNs rejects every push with BadDeviceToken. This matches the Element/
        // Matrix iOS convention.
        let pushkey = deviceToken.base64EncodedString()
        Task { @MainActor in PushRegistry.shared.setDeviceToken(pushkey) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
#endif
