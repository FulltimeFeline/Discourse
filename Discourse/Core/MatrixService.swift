import Foundation
@preconcurrency import MatrixRustSDK

/// Runs `operation` with a wall-clock timeout; returns true if it completed,
/// false if it timed out (the operation task is then cancelled).
@discardableResult
func runWithTimeout(seconds: Double,
                    _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation(); return true }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
        let completed = await group.next() ?? false
        group.cancelAll()
        return completed
    }
}

enum MatrixServiceError: LocalizedError {
    case passwordLoginUnsupported
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .passwordLoginUnsupported:
            "This homeserver doesn't support password login. OAuth sign-in is coming soon."
        case .sessionNotFound:
            "No stored session for this account."
        }
    }
}

/// Persists OAuth token refreshes the SDK performs mid-session. Without this
/// the keychain keeps the login-time pair forever; on OAuth homeservers (MAS)
/// the refresh token rotates, so on next launch `restoreSession` is fed an
/// already-consumed token, restore fails, and the account is stuck offline.
/// Callbacks arrive on Rust threads — the keychain read-modify-write is
/// self-contained and never touches app state.
final class SessionDelegate: ClientSessionDelegate {
    private let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let token = sessionStore.loadAll().first(where: { $0.session.userId == userId }) else {
            // Expected during fresh login: the account isn't stored yet.
            throw MatrixServiceError.sessionNotFound
        }
        return token.session.ffiSession
    }

    func saveSessionInKeychain(session: Session) {
        // Atomic read-modify-write: concurrent refreshes on other accounts'
        // Rust threads must not clobber this account's rotated token.
        try? sessionStore.mutate { tokens in
            var tokens = tokens
            guard let index = tokens.firstIndex(where: { $0.session.userId == session.userId }) else {
                // Unknown user (fresh login before completeLogin persists it):
                // the token is saved by AppState; leave the array untouched
                // rather than inventing one.
                return tokens
            }
            // Preserve storePassphrase/dataPath/cachePath; only the pair moved.
            tokens[index].session = .init(from: session)
            return tokens
        }
    }
}

/// Owns the FFI `Client` (and, from M2, the sync + room list services).
/// The only type in the app that drives MatrixRustSDK control flow.
final class MatrixService: @unchecked Sendable {
    let client: Client
    let userId: String
    /// Retained so the token-refresh delegate outlives client construction.
    private let sessionDelegate: SessionDelegate?

    private(set) var syncService: SyncService?
    private(set) var roomListService: RoomListService?
    private var syncStateHandle: TaskHandle?
    /// Feeds `syncStateStream` (the room list's banner + reconnection UI).
    private let syncStateBridge = SyncServiceStateBridge()
    /// A SEPARATE observer for the internal monitor (error-restart + send-
    /// queue gate). An AsyncStream has a single consumer — two `for await`
    /// loops on one bridge would split the state transitions between them —
    /// so the monitor registers its own SDK listener.
    private let syncMonitorBridge = SyncServiceStateBridge()
    private var syncMonitorHandle: TaskHandle?

    /// The SDK's unknown-token / soft-logout signal. `AppState` drops the
    /// affected account into a re-auth state instead of retrying restore.
    private let clientDelegateBridge = ClientDelegateBridge()
    private var clientDelegateHandle: TaskHandle?
    var authErrorStream: AsyncStream<Bool> { clientDelegateBridge.stream }

    /// Send-queue self-disable signal; drives the reachability-style re-enable.
    private let sendQueueBridge = SendQueueErrorBridge()
    private var sendQueueHandle: TaskHandle?
    private var sendQueueTask: Task<Void, Never>?
    private var syncMonitorTask: Task<Void, Never>?
    /// Latest sync state, tracked so the send-queue re-enable only fires when
    /// the connection is actually up.
    private var latestSyncState: SyncServiceState = .idle
    /// Debounce so a burst of send errors schedules one re-enable.
    private var queueReenableScheduled = false

    fileprivate init(client: Client, sessionDelegate: SessionDelegate? = nil) throws {
        self.client = client
        self.sessionDelegate = sessionDelegate
        self.userId = try client.userId()
        // Covers both login and restore: a revoked token surfaces here.
        clientDelegateHandle = try? client.setDelegate(delegate: clientDelegateBridge)
    }

    /// Builds and starts the sync service (idempotent).
    @MainActor
    func startSync() async throws {
        guard syncService == nil else { return }
        // Offline mode: the SDK serves cached data and reports `.offline`
        // (which the room list already renders) instead of churning `.error`
        // while the network is down.
        let sync = try await client.syncService()
            .withOfflineMode()
            .finish()
        syncService = sync
        roomListService = sync.roomListService()
        syncStateHandle = sync.state(listener: syncStateBridge)
        syncMonitorHandle = sync.state(listener: syncMonitorBridge)

        // Watch sync state: restart on a hard `.error` (Element X does the
        // same 250ms bounce), and remember the state for the send-queue
        // re-enable gate below. A deliberate pause (backgrounding) isn't an
        // error to recover from — `isPaused` suppresses the bounce.
        syncMonitorTask?.cancel()
        // Explicitly main-actor-isolated so `latestSyncState`/`isPaused` are
        // only ever touched on main — the same isolation `pauseSync`/
        // `resumeSync` run under. (It already inherited main from this
        // `@MainActor` method; pinning it keeps that guarantee if the call
        // site ever changes.)
        syncMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in self.syncMonitorBridge.stream {
                self.latestSyncState = state
                if state == .error, !self.isPaused {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !self.isPaused else { continue }
                    await self.syncService?.start()
                }
            }
        }

        // The SDK disables a room's send queue after any send error and never
        // re-enables it. Watch for that and re-enable shortly after, once sync
        // reports it's running again — a reachability-lite version of Element
        // X's NWPathMonitor gate.
        sendQueueHandle = client.subscribeToSendQueueStatus(listener: sendQueueBridge)
        sendQueueTask?.cancel()
        sendQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.sendQueueBridge.stream {
                self.scheduleSendQueueReenable()
            }
        }

        await sync.start()
    }

    /// Debounced re-enable: after a send-queue error, wait a beat and — if
    /// sync is running (i.e. the connection is back) — re-enable all queues.
    /// If it's still not running, try again on the next error.
    @MainActor
    private func scheduleSendQueueReenable() {
        guard !queueReenableScheduled else { return }
        queueReenableScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.queueReenableScheduled = false
            guard self.latestSyncState == .running else { return }
            await self.enableAllSendQueues()
        }
    }

    var syncStateStream: AsyncStream<SyncServiceState> { syncStateBridge.stream }

    /// The SDK disables a room's send queue after any send error; nothing
    /// re-enables it by itself. Called when connectivity recovers and before
    /// a manual retry, mirroring Element X's reachability handling.
    func enableAllSendQueues() async {
        await client.enableAllSendQueues(enable: true)
    }

    #if os(iOS)
    /// Registers this device's APNs token as a Matrix pusher, so the homeserver
    /// forwards events to the push gateway while the app is suspended.
    func registerPusher(deviceTokenHex: String) async {
        try? await client.setPusher(
            identifiers: PusherIdentifiers(pushkey: deviceTokenHex, appId: PushConfig.appId),
            kind: .http(data: HttpPusherData(
                url: PushConfig.pushGatewayURL,
                format: .eventIdOnly,
                defaultPayload: #"{"aps":{"mutable-content":1,"alert":{"loc-key":"New message"}}}"#)),
            appDisplayName: "Discourse",
            deviceDisplayName: "Discourse (iOS)",
            profileTag: nil,
            lang: "en",
            append: false)
    }
    #endif

    /// The homeserver's max upload size in bytes, fetched once and cached, so
    /// the composer can reject an oversize file before uploading it.
    private var cachedMaxUploadSize: UInt64?
    func maxUploadSize() async -> UInt64? {
        if let cachedMaxUploadSize { return cachedMaxUploadSize }
        let size = try? await client.getMaxMediaUploadSize()
        cachedMaxUploadSize = size
        return size
    }

    /// True while sync is intentionally paused (iOS backgrounding).
    private var isPaused = false

    /// Stops the sync loop for backgrounding WITHOUT tearing down the service,
    /// so the process suspends cleanly mid-nothing. The room list and timeline
    /// subscriptions stay attached to the same (stopped) service; `resumeSync`
    /// just restarts it. Never fully rebuilds — that would orphan those
    /// subscriptions.
    @MainActor
    func pauseSync() async {
        guard let syncService, !isPaused else { return }
        isPaused = true
        await syncService.stop()
    }

    /// Restarts a paused sync loop on foreground (or starts it if it never
    /// ran). Safe to call unconditionally from the scene-phase handler.
    @MainActor
    func resumeSync() async {
        // No `Task.isCancelled` guard: this is driven from the scene-phase
        // handler's `Task { … }`, which a rapid background→foreground bounce
        // can cancel — returning early there would leave the app silently
        // offline on foreground. Nothing downstream is cancellation-sensitive.
        if let syncService {
            isPaused = false
            await syncService.start()
        } else {
            try? await startSync()
        }
    }

    // MARK: Creating and joining rooms

    struct UserHit: Identifiable, Hashable {
        let id: String
        var displayName: String?
        var avatarURL: String?
        var name: String { displayName ?? id }
    }

    func searchUsers(query: String) async -> [UserHit] {
        guard let results = try? await client.searchUsers(searchTerm: query, limit: 10) else { return [] }
        return results.results.map {
            UserHit(id: $0.userId, displayName: $0.displayName, avatarURL: $0.avatarUrl)
        }
    }

    /// Opens the existing DM with this user, or creates an encrypted one.
    func startDm(userId: String) async throws -> String {
        if let existing = try? client.getDmRoom(userId: userId) {
            return existing.id()
        }
        return try await client.createRoom(request: CreateRoomParameters(
            name: nil,
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .trustedPrivateChat,
            invite: [userId]
        ))
    }

    enum NewRoomVisibility {
        case privateRoom
        case publicRoom
        /// Restricted join rule: members of the space can join freely.
        case spaceMembers(spaceId: String)
    }

    func createRoom(name: String, topic: String?, visibility: NewRoomVisibility,
                    isEncrypted: Bool, isSpace: Bool) async throws -> String {
        let isPublic = if case .publicRoom = visibility { true } else { false }
        var joinRule: JoinRule?
        if case .spaceMembers(let spaceId) = visibility {
            joinRule = .restricted(rules: [.roomMembership(roomId: spaceId)])
        }
        return try await client.createRoom(request: CreateRoomParameters(
            name: name,
            topic: (topic?.isEmpty == false) ? topic : nil,
            isEncrypted: isEncrypted,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat,
            joinRuleOverride: joinRule,
            isSpace: isSpace
        ))
    }

    /// Creates an Element-style video room. The FFI's `createRoom` can't set
    /// a custom `m.room.create` type, so this calls the client-server API
    /// directly.
    func createVideoRoom(name: String, topic: String?,
                         visibility: NewRoomVisibility) async throws -> String {
        let session = try client.session()
        guard let base = URL(string: session.homeserverUrl) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: base.appending(path: "_matrix/client/v3/createRoom"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isPublic = if case .publicRoom = visibility { true } else { false }
        var body: [String: Any] = [
            "name": name,
            "preset": isPublic ? "public_chat" : "private_chat",
            "creation_content": ["type": "io.element.video"],
        ]
        if let topic, !topic.isEmpty { body["topic"] = topic }
        if case .spaceMembers(let spaceId) = visibility {
            body["initial_state"] = [[
                "type": "m.room.join_rules",
                "state_key": "",
                "content": [
                    "join_rule": "restricted",
                    "allow": [["type": "m.room_membership", "room_id": spaceId]],
                ],
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roomId = json["room_id"] as? String else {
            throw URLError(.badServerResponse)
        }
        return roomId
    }

    /// Video rooms among a space's children, via the hierarchy API — the
    /// SDK's space listing doesn't surface `m.room.create` types.
    func videoRoomIds(inSpace spaceId: String) async -> Set<String> {
        guard let session = try? client.session(),
              let base = URL(string: session.homeserverUrl) else { return [] }
        var url = base.appending(path: "_matrix/client/v1/rooms/\(spaceId)/hierarchy")
        url.append(queryItems: [URLQueryItem(name: "limit", value: "200")])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rooms = json["rooms"] as? [[String: Any]] else { return [] }
        let videoTypes = ["io.element.video", "org.matrix.msc3417.call"]
        return Set(rooms.compactMap { room in
            guard let type = room["room_type"] as? String, videoTypes.contains(type) else {
                return nil
            }
            return room["room_id"] as? String
        })
    }

    /// Joins a room by `#alias:server` or `!roomid:server` and returns its ID.
    func joinRoom(address: String) async throws -> String {
        let room = try await client.joinRoomByIdOrAlias(roomIdOrAlias: address, serverNames: [])
        return room.id()
    }

    // MARK: Encryption / verification

    var verificationState: VerificationState {
        client.encryption().verificationState()
    }

    func verificationStates() -> (stream: AsyncStream<VerificationState>, retained: [Any]) {
        let bridge = VerificationStateBridge()
        let handle = client.encryption().verificationStateListener(listener: bridge)
        return (bridge.stream, [bridge, handle])
    }

    private var cachedVerificationController: SessionVerificationController?

    /// One shared controller for the whole session. `getSessionVerificationController`
    /// mints a NEW controller each call, and separate controllers get separate
    /// delegates, so the active flow's accept/emoji events land on the incoming
    /// watcher's delegate instead — stalling verification. Sharing one instance
    /// keeps every event on the currently-set delegate.
    @MainActor
    func sessionVerificationController() async throws -> SessionVerificationController {
        if let cachedVerificationController { return cachedVerificationController }
        let controller = try await client.getSessionVerificationController()
        cachedVerificationController = controller
        return controller
    }

    func recover(recoveryKey: String) async throws {
        try await client.encryption().recover(recoveryKey: recoveryKey)
    }

    // MARK: Session lifecycle

    /// Phase 1 of login: build a client for the homeserver and discover which
    /// auth methods it supports.
    static func prepare(homeserver: String) async throws -> PendingLogin {
        MatrixPlatform.initializeOnce()
        let sessionId = UUID().uuidString
        let dirs = try SessionStore.makeSessionDirectories(id: sessionId)
        let passphrase = SessionStore.randomPassphrase()
        let sessionDelegate = SessionDelegate(sessionStore: SessionStore())
        let client = try await buildClient(
            homeserver: homeserver,
            dataPath: dirs.dataPath,
            cachePath: dirs.cachePath,
            passphrase: passphrase,
            sessionDelegate: sessionDelegate
        )
        let details = await client.homeserverLoginDetails()
        return PendingLogin(client: client,
                            sessionDelegate: sessionDelegate,
                            dataPath: dirs.dataPath,
                            cachePath: dirs.cachePath,
                            passphrase: passphrase,
                            supportsPassword: details.supportsPasswordLogin(),
                            supportsOAuth: details.supportsOauthLogin(),
                            supportsSso: details.supportsSsoLogin())
    }

    static func logIn(homeserver: String, username: String, password: String) async throws -> (MatrixService, RestorationToken) {
        let pending = try await prepare(homeserver: homeserver)
        return try await pending.finishWithPassword(username: username, password: password)
    }

    static func restore(token: RestorationToken) async throws -> MatrixService {
        MatrixPlatform.initializeOnce()
        // Resolve against the current container — iOS moves the sandbox
        // between installs, so the token's absolute paths can be stale.
        let dirs = try SessionStore.currentSessionDirectories(token: token)
        let sessionDelegate = SessionDelegate(sessionStore: SessionStore())
        let client = try await buildClient(
            homeserver: token.session.homeserverUrl,
            dataPath: dirs.dataPath,
            cachePath: dirs.cachePath,
            passphrase: token.storePassphrase,
            sessionDelegate: sessionDelegate,
            // Use the version already recorded at login — no rediscovery.
            slidingSyncVersion: token.session.slidingSyncVersion == "native" ? .native : .none
        )
        try await client.restoreSession(session: token.session.ffiSession)
        // Let cross-signing/backup setup finish in the background so encrypted
        // history unlocks without user action where possible.
        Task { await client.encryption().waitForE2eeInitializationTasks() }
        return try MatrixService(client: client, sessionDelegate: sessionDelegate)
    }

    /// @MainActor to share isolation with the other sync-lifecycle methods —
    /// they all touch `syncService`/`syncMonitorTask`/`sendQueueTask`, and a
    /// scene-phase pause/resume could otherwise race this teardown.
    @MainActor
    func logOut() async {
        syncMonitorTask?.cancel()
        sendQueueTask?.cancel()
        await syncService?.stop()
        // Give recent message keys a chance to reach key backup before the
        // store is destroyed — otherwise those messages are unrecoverable on
        // other devices restored from backup. Best-effort and time-bounded so
        // a stuck/offline backup can't wedge sign-out.
        _ = await runWithTimeout(seconds: 8) { [client] in
            try? await client.encryption().waitForBackupUploadSteadyState(progressListener: nil)
        }
        try? await client.logout()
    }

    // MARK: Private

    private static func buildClient(homeserver: String, dataPath: String, cachePath: String,
                                    passphrase: String, sessionDelegate: SessionDelegate,
                                    slidingSyncVersion: SlidingSyncVersionBuilder = .discoverNative) async throws -> Client {
        try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: dataPath, cachePath: cachePath)
                .passphrase(passphrase: passphrase))
            // Login discovers the version; restore already knows it (from the
            // stored session), so it skips the network round-trip — the cold
            // launch no longer waits on the homeserver before showing cached data.
            .slidingSyncVersionBuilder(versionBuilder: slidingSyncVersion)
            // Persists mid-session OAuth token refreshes to the keychain, so a
            // relaunch restores with the current (rotated) refresh token.
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            // "Invisible crypto": set up cross-signing and key backup without
            // user ceremony, and self-heal UTDs from backup.
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            .enableShareHistoryOnInvite(enableShareHistoryOnInvite: true)
            .build()
    }
}

/// A client built for a homeserver, pre-authentication. Wraps all three auth
/// methods; whichever succeeds produces the (service, token) pair.
final class PendingLogin: @unchecked Sendable {
    // Reverse-DNS (dotted) scheme: MAS rejects single-word private-use schemes
    // like "discourse" during client registration (RFC 8252 §7.1).
    static let callbackScheme = "com.rileylopezsantana.discourse"
    static let oauthRedirectURL = "\(callbackScheme):/oauth-callback"
    static let ssoRedirectURL = "\(callbackScheme):/sso-callback"

    let supportsPassword: Bool
    let supportsOAuth: Bool
    let supportsSso: Bool

    private let client: Client
    private let sessionDelegate: SessionDelegate
    private let dataPath: String
    private let cachePath: String
    private let passphrase: String
    private var oauthData: OAuthAuthorizationData?
    private var ssoHandler: SsoHandler?

    init(client: Client, sessionDelegate: SessionDelegate, dataPath: String, cachePath: String,
         passphrase: String, supportsPassword: Bool, supportsOAuth: Bool, supportsSso: Bool) {
        self.client = client
        self.sessionDelegate = sessionDelegate
        self.dataPath = dataPath
        self.cachePath = cachePath
        self.passphrase = passphrase
        self.supportsPassword = supportsPassword
        self.supportsOAuth = supportsOAuth
        self.supportsSso = supportsSso
    }

    func finishWithPassword(username: String, password: String) async throws -> (MatrixService, RestorationToken) {
        guard supportsPassword else { throw MatrixServiceError.passwordLoginUnsupported }
        #if os(iOS)
        let deviceName = "Discourse (iOS)"
        #else
        let deviceName = "Discourse (macOS)"
        #endif
        try await client.login(username: username, password: password,
                               initialDeviceName: deviceName, deviceId: nil)
        return try finish()
    }

    /// OAuth step 1: the browser URL to authorize at.
    func startOAuth() async throws -> URL {
        let data = try await client.urlForOauth(
            oauthConfiguration: OAuthConfiguration(
                clientName: "Discourse",
                redirectUri: Self.oauthRedirectURL,
                clientUri: "https://github.com/rileylopezsantana/discourse",
                logoUri: nil,
                tosUri: nil,
                policyUri: nil,
                staticRegistrations: [:]
            ),
            prompt: nil,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )
        oauthData = data
        guard let url = URL(string: data.loginUrl()) else {
            throw URLError(.badURL)
        }
        return url
    }

    /// OAuth step 2: the `discourse://oauth-callback?...` URL from the browser.
    func finishOAuth(callbackUrl: URL) async throws -> (MatrixService, RestorationToken) {
        try await client.loginWithOauthCallback(callbackUrl: callbackUrl.absoluteString)
        return try finish()
    }

    func abortOAuth() async {
        if let oauthData {
            await client.abortOauthAuth(authorizationData: oauthData)
        }
        oauthData = nil
    }

    /// Legacy SSO step 1.
    func startSso() async throws -> URL {
        let handler = try await client.startSsoLogin(redirectUrl: Self.ssoRedirectURL, idpId: nil)
        ssoHandler = handler
        guard let url = URL(string: handler.url()) else {
            throw URLError(.badURL)
        }
        return url
    }

    /// Legacy SSO step 2.
    func finishSso(callbackUrl: URL) async throws -> (MatrixService, RestorationToken) {
        guard let ssoHandler else { throw URLError(.cancelled) }
        try await ssoHandler.finish(callbackUrl: callbackUrl.absoluteString)
        return try finish()
    }

    private func finish() throws -> (MatrixService, RestorationToken) {
        let session = try client.session()
        let token = RestorationToken(
            session: .init(from: session),
            storePassphrase: passphrase,
            dataPath: dataPath,
            cachePath: cachePath
        )
        return (try MatrixService(client: client, sessionDelegate: sessionDelegate), token)
    }
}

