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
    static let enabled = true

    /// App Group shared by the main app and the extension, so the extension can
    /// open the same session/crypto store and decrypt the pushed event.
    static let appGroup = "group.com.riiiiiiiley.Discourse"

    /// Keychain access group shared by the app and the extension. It MUST carry
    /// the team-id prefix the OS actually grants: the entitlement value
    /// `$(AppIdentifierPrefix)com.riiiiiiiley.Discourse.shared` expands to
    /// `<TeamID>.com.riiiiiiiley.Discourse.shared`, and a keychain query has to
    /// match that exact string. An un-prefixed literal fails every call with
    /// `errSecMissingEntitlement` (-34018). Team `44LAW4UL9G` (see project.yml
    /// DEVELOPMENT_TEAM); the iOS SecTask entitlement-reading APIs don't exist,
    /// so the prefix is hardcoded here.
    static let keychainAccessGroup = "44LAW4UL9G.com.riiiiiiiley.Discourse.shared"

    /// Matrix pusher app id (APNs). Must match the gateway's app config.
    static let appId = "com.riiiiiiiley.Discourse"

    /// The sygnal `/_matrix/push/v1/notify` endpoint.
    static let pushGatewayURL = "https://push.fulltimefeline.com/_matrix/push/v1/notify"

    /// The extension's bundle id, for logging/diagnostics.
    static let serviceExtensionBundleId = "com.riiiiiiiley.Discourse.NSE"
}
