import Foundation

/// Shared identifiers and endpoints for remote push. The app and the
/// notification service extension both read these, so they must agree.
///
/// `pushGatewayURL` points at a Matrix push gateway (sygnal) configured with
/// this app's APNs key and `appId`. It's the one piece that requires
/// infrastructure you host — until it's set, `setPusher` has nowhere to route.
enum PushConfig {
    /// Remote push is off until a gateway is configured AND the App Group +
    /// Keychain Sharing capabilities are provisioned for the app and extension.
    /// While off, the app uses the plain keychain and app-support store so
    /// sign-in works without those entitlements. Flip to true once both the
    /// gateway (`pushGatewayURL`) and the capabilities are set up.
    static let enabled = false

    /// App Group shared by the main app and the extension, so the extension can
    /// open the same session/crypto store and decrypt the pushed event.
    static let appGroup = "group.com.rileylopezsantana.Discourse"

    /// Keychain access group (the app's team-prefixed group) so the extension
    /// can read the restoration token. Resolved at runtime from the app's own
    /// keychain-access-groups entitlement, so no team id is hardcoded here.
    static let keychainAccessGroup = "com.rileylopezsantana.Discourse.shared"

    /// Matrix pusher app id (APNs). Must match the gateway's app config.
    static let appId = "com.rileylopezsantana.Discourse"

    /// The sygnal `/_matrix/push/v1/notify` endpoint. Fill in your gateway.
    static let pushGatewayURL = "https://push.example.com/_matrix/push/v1/notify"

    /// The extension's bundle id, for logging/diagnostics.
    static let serviceExtensionBundleId = "com.rileylopezsantana.Discourse.NSE"
}
