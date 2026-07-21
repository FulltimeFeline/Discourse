import Foundation
import Observation
import OSLog
@preconcurrency import MatrixRustSDK

/// Driver↔widget traffic + call lifecycle. Notice level so it persists to
/// unified logging: `log show --predicate 'subsystem == "dev.discourse.call"'`
/// (add `--last 5m`) surfaces the MatrixRTC membership / delayed-event churn
/// behind call reconnects.
private let callLog = Logger(subsystem: "dev.discourse.call", category: "widget")

/// Hosts an Element Call (MatrixRTC) session: builds the virtual widget, runs
/// the SDK widget driver, and shuttles messages between driver and web view.
@MainActor
@Observable
final class CallViewModel: Identifiable {
    let roomName: String
    private(set) var webViewURL: URL?
    private(set) var error: String?
    /// Set when Element Call reports the user hung up / left, so the call
    /// window can close itself.
    private(set) var didHangUp = false

    private let room: Room
    private let client: Client
    private let ownUserId: String
    private let joinExisting: Bool

    private var handle: WidgetDriverHandle?
    private var retained: [Any] = []
    private var driverTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    /// Delivers driver→widget messages into the web view; set by the view.
    var postToWebView: ((String) -> Void)?

    #if os(macOS)
    /// Held for the whole call so App Nap can't throttle the occluded call
    /// window's timers — Element Call refreshes the MatrixRTC "delayed leave"
    /// heartbeat on a JS timer, and a throttled refresh lets the server drop us
    /// for everyone. Also keeps the Mac awake so a background call isn't cut by
    /// idle sleep.
    private var callActivity: NSObjectProtocol?
    #endif

    init(room: Room, client: Client, ownUserId: String, joinExisting: Bool = false) {
        self.room = room
        self.client = client
        self.ownUserId = ownUserId
        self.joinExisting = joinExisting
        self.roomName = room.displayName() ?? room.id()
    }

    func start() async {
        guard webViewURL == nil else { return }
        CallRegistry.localRooms.insert(room.id())
        beginCallActivity()
        do {
            // Self-hosted EC if the homeserver advertises one, Element's
            // otherwise. /room is the embedded-widget entrypoint; the bare
            // origin serves the standalone SPA (→ "Missing access token").
            let elementCallUrl = await WellKnownDiscovery.elementCallWidgetURL(userId: ownUserId)
                ?? "https://call.element.io/room"
            let settings = try newVirtualElementCallWidget(
                props: VirtualElementCallWidgetProperties(
                    elementCallUrl: elementCallUrl,
                    widgetId: UUID().uuidString,
                    // Parent is the call page itself, so widget postMessages
                    // stay in-page where our injected bridge can capture them.
                    parentUrl: elementCallUrl,
                    fontScale: nil,
                    font: nil,
                    encryption: .perParticipantKeys,
                    posthogUserId: nil,
                    posthogApiHost: nil,
                    posthogApiKey: nil,
                    rageshakeSubmitUrl: nil,
                    sentryDsn: nil,
                    sentryEnvironment: nil
                ),
                config: VirtualElementCallWidgetConfig(
                    intent: joinExisting ? .joinExisting : .startCall,
                    skipLobby: false,
                    header: nil,
                    hideHeader: true,
                    preload: nil,
                    appPrompt: false,
                    confineToRoom: true,
                    hideScreensharing: false,
                    controlledAudioDevices: nil,
                    sendNotificationType: nil
                )
            )

            let urlString = try await generateWebviewUrl(
                widgetSettings: settings,
                room: room,
                props: ClientProperties(
                    clientId: "com.riiiiiiiley.discourse",
                    languageTag: nil,
                    theme: nil
                )
            )

            callLog.notice("call url=\(urlString, privacy: .public)")
            let pair = try makeWidgetDriver(settings: settings)
            handle = pair.handle
            let capabilities = CallCapabilitiesBridge(ownUserId: ownUserId,
                                                      ownDeviceId: (try? client.deviceId()) ?? "")
            retained = [pair.driver, pair.handle, capabilities]
            driverTask = Task {
                await pair.driver.run(room: room, capabilitiesProvider: capabilities)
            }
            pumpTask = Task { [weak self] in
                while let message = await pair.handle.recv() {
                    guard !Task.isCancelled else { return }
                    callLog.notice("driver→widget: \(message.prefix(400), privacy: .public)")
                    self?.postToWebView?(message)
                }
            }

            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            webViewURL = url
        } catch {
            self.error = "Couldn't start the call: \(error.localizedDescription)"
        }
    }

    /// Element Call "host" widget actions that the embedding client is meant to
    /// answer itself — they're NOT part of the Matrix widget API the SDK's driver
    /// implements. Forwarding them to the driver gets an "unknown variant" error
    /// back, which desyncs Element Call's state machine (e.g. the mic shows muted
    /// while you're unmuted, join/screenshare stall). We ack them here instead.
    private static let hostHandledActions: Set<String> = [
        "io.element.join",
        "io.element.device_mute",
        "set_always_on_screen",
        "io.element.tile_layout",
    ]

    /// Widget→driver, called from the web view's message handler.
    func receiveFromWebView(_ message: String) {
        guard let handle else { return }
        callLog.notice("widget→driver: \(message.prefix(400), privacy: .public)")
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let action = json["action"] as? String {
            // Element Call posts a hangup/close action when the user leaves — the
            // window should then close itself rather than lingering on the widget.
            if action.contains("hangup") || action == "close"
                || action == "im.vector.hangup" || action == "io.element.close" {
                didHangUp = true
            }
            // Host-level actions the driver can't parse: ack them ourselves and
            // do NOT forward, so Element Call sees success instead of an error.
            if Self.hostHandledActions.contains(action) {
                ackWidgetAction(json)
                return
            }
        }
        Task { _ = await handle.send(msg: message) }
    }

    /// Posts an empty-success response back to the widget for a request the host
    /// handles. Element Call matches it by `requestId`; a `response` with no
    /// `error` reads as success (and `set_always_on_screen` wants `success`).
    private func ackWidgetAction(_ request: [String: Any]) {
        var reply = request
        let action = request["action"] as? String
        reply["response"] = action == "set_always_on_screen" ? ["success": true] : [String: Any]()
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let string = String(data: data, encoding: .utf8) else { return }
        callLog.notice("host-ack: \(action ?? "?", privacy: .public)")
        postToWebView?(string)
    }

    func stop() {
        CallRegistry.localRooms.remove(room.id())
        pumpTask?.cancel()
        driverTask?.cancel()
        pumpTask = nil
        driverTask = nil
        handle = nil
        retained = []
        postToWebView = nil
        endCallActivity()
    }

    /// Keeps the process alive and un-throttled for the call, so the MatrixRTC
    /// membership heartbeat keeps refreshing even when we're idle/backgrounded
    /// — otherwise the server's delayed-leave fires and other participants see
    /// us drop out.
    ///
    /// iOS deliberately does NOT touch `AVAudioSession`: the WKWebView owns the
    /// WebRTC capture session, and reconfiguring/activating it from here desyncs
    /// WebKit and breaks the mic. The `audio` background mode plus WebKit's own
    /// active capture session (held even while muted) already grant background
    /// execution. macOS holds an App Nap assertion so an occluded call window's
    /// heartbeat timers aren't throttled.
    private func beginCallActivity() {
        #if os(macOS)
        guard callActivity == nil else { return }
        callActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Keep the MatrixRTC call heartbeat alive while the window is occluded")
        #endif
    }

    private func endCallActivity() {
        #if os(macOS)
        if let callActivity {
            ProcessInfo.processInfo.endActivity(callActivity)
            self.callActivity = nil
        }
        #endif
    }
}

/// Rooms whose call we started/joined here, so the ringing UI skips our own.
@MainActor
enum CallRegistry {
    static var localRooms: Set<String> = []
}

/// Grants Element Call the permissions the SDK says it requires.
final class CallCapabilitiesBridge: WidgetCapabilitiesProvider {
    private let ownUserId: String
    private let ownDeviceId: String

    init(ownUserId: String, ownDeviceId: String) {
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: ownUserId, ownDeviceId: ownDeviceId)
    }
}
