import Foundation
import Observation
@preconcurrency import MatrixRustSDK

/// Hosts an Element Call (MatrixRTC) session: builds the virtual widget, runs
/// the SDK widget driver, and shuttles messages between driver and web view.
@MainActor
@Observable
final class CallViewModel: Identifiable {
    let roomName: String
    private(set) var webViewURL: URL?
    private(set) var error: String?

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

            fputs("CALLDBG url=\(urlString)\n", stderr)
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
                    fputs("CALLDBG driver→widget: \(message.prefix(120))\n", stderr)
                    self?.postToWebView?(message)
                }
            }

            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            webViewURL = url
        } catch {
            self.error = "Couldn't start the call: \(error.localizedDescription)"
        }
    }

    /// Widget→driver, called from the web view's message handler.
    func receiveFromWebView(_ message: String) {
        guard let handle else { return }
        fputs("CALLDBG widget→driver: \(message.prefix(120))\n", stderr)
        Task { _ = await handle.send(msg: message) }
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
