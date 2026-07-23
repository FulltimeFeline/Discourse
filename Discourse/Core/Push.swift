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
    /// Services (per account) awaiting a pusher once the APNs token arrives, so
    /// EVERY signed-in account — not just the active one — gets remote pushes.
    private var pendingServices: [MatrixService] = []

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
        let pending = pendingServices
        pendingServices = []
        for service in pending { registerPusher(for: service) }
    }

    func setActiveService(_ service: MatrixService?) {
        self.service = service
        register()
    }

    /// Registers (or removes) a pusher for a specific account's service —
    /// e.g. a warm background account — respecting its per-account notification
    /// toggle. Called again when the toggle changes.
    func registerPusher(for service: MatrixService) {
        guard gatewayConfigured else { return }
        let enabled = Preferences.shared.notificationsEnabled(forUserId: service.userId)
        guard let pushkey else {
            if enabled { pendingServices.append(service) }
            return
        }
        if enabled {
            Task { await service.registerPusher(pushkey: pushkey) }
        } else {
            Task { await service.removePusher(pushkey: pushkey) }
        }
    }

    private func register() {
        guard gatewayConfigured else { log.error("gateway not configured: \(PushConfig.pushGatewayURL, privacy: .public)"); return }
        guard let service else { log.info("waiting for active session"); return }
        registerPusher(for: service)
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

    // Opt out of UIKit state restoration. Its background snapshot archive
    // (`_updateStateRestorationArchiveForBackgroundEvent`) was being built off
    // the main thread and aborting with "Call must be made on main thread" when
    // the app backgrounds — e.g. after tapping a notification. We don't use
    // state restoration (SwiftUI owns navigation state), so decline it.
    func application(_ application: UIApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: UIApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }
}
#endif
