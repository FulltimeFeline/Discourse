import Foundation
import os
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
    /// Our own server name (the `domain` in `@user:domain`).
    var ownServerName: String {
        guard let colon = userId.firstIndex(of: ":") else { return "" }
        return String(userId[userId.index(after: colon)...])
    }
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
    /// Client-API base URL for manual REST calls (extended profile), resolved
    /// once via `.well-known` so we hit the delegated homeserver
    /// (e.g. matrix.example.com) rather than the bare server name, which may
    /// 404 the client API.
    private var resolvedAPIBase: URL?

    #if os(macOS)
    /// Held while sync runs so App Nap can't throttle the sliding-sync long-poll
    /// when the window is minimized or occluded — otherwise room keys stop
    /// arriving and encrypted messages stick at "waiting to decrypt" until the
    /// app is relaunched. Allows idle system sleep (we only need networking, not
    /// to keep the Mac awake).
    private var backgroundActivity: NSObjectProtocol?
    #endif

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
        #if os(macOS)
        if backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keep Matrix sync running while the window is occluded")
        }
        #endif
        // Offline mode: the SDK serves cached data and reports `.offline`
        // (which the room list already renders) instead of churning `.error`
        // while the network is down.
        // Room-list timeline limit: makes the room-list sync return each room's
        // latest event, so sidebar previews populate WITHOUT subscribing to every
        // room. Blanket-subscribing (the old approach) produced a ~12k request
        // per sync and, more importantly, the receipts/typing extensions
        // (scoped to subscribed rooms) don't stream live under that load — this
        // is why read receipts and typing were frozen.
        let sync = try await client.syncService()
            .withOfflineMode()
            .withRoomListTimelineLimit(limit: 1)
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
    func registerPusher(pushkey: String) async {
        let log = Logger(subsystem: "dev.discourse.push", category: "pusher")
        do {
            try await client.setPusher(
                identifiers: PusherIdentifiers(pushkey: pushkey, appId: PushConfig.appId),
                kind: .http(data: HttpPusherData(
                    url: PushConfig.pushGatewayURL,
                    format: .eventIdOnly,
                    // mutable-content:1 wakes the NSE to decrypt; the literal
                    // alert is the visible fallback if the NSE can't run. (A
                    // `loc-key` here would need a matching localized string or
                    // iOS shows nothing.)
                    defaultPayload: #"{"aps":{"mutable-content":1,"sound":"default","alert":{"title":"Discourse","body":"New message"}}}"#)),
                appDisplayName: "Discourse",
                deviceDisplayName: "Discourse (iOS)",
                profileTag: nil,
                lang: "en",
                append: false)
            log.info("setPusher OK — appId=\(PushConfig.appId, privacy: .public) gateway=\(PushConfig.pushGatewayURL, privacy: .public) pushkey=\(pushkey.prefix(8), privacy: .public)…")
        } catch {
            log.error("setPusher FAILED: \(error, privacy: .public)")
        }
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

    /// Reads a room's custom state event content — the FFI exposes no state
    /// reader, so this hits the client-server API directly. nil = absent/error.
    func stateEventContent(roomId: String, type: String) async -> [String: Any]? {
        guard let session = try? client.session(),
              let base = await apiBase() else { return nil }
        let url = base.appending(path: "_matrix/client/v3/rooms/\(roomId)/state/\(type)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Writes a room state event (empty state key). Returns true on 2xx — false
    /// includes M_FORBIDDEN when the user lacks permission in the room.
    @discardableResult
    /// Whether the signed-in user is allowed to send a given state event in a
    /// room — used to hide edit controls (e.g. a space banner) the user has no
    /// power to change, rather than letting them try and fail.
    func canSendStateEvent(roomId: String, type: String) async -> Bool {
        guard let room = try? client.getRoom(roomId: roomId),
              let levels = try? await room.getPowerLevels() else { return false }
        return levels.canOwnUserSendState(stateEvent: .custom(value: type))
    }

    func setStateEvent(roomId: String, type: String, content: [String: Any]) async -> Bool {
        guard let session = try? client.session(),
              let base = await apiBase() else { return false }
        let url = base.appending(path: "_matrix/client/v3/rooms/\(roomId)/state/\(type)/")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: content)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code)
        else { return false }
        return true
    }

    /// Custom profile keys clients use for pronouns (there's no single standard
    /// yet — MSC4133 extended profiles are namespaced per client). Read all,
    /// write the common ones so pronouns interoperate across clients.
    private static let pronounKeys = ["foxchat.pronouns", "pronouns",
                                      "io.fsky.nyx.pronouns", "m.pronouns"]

    /// The true read-receipt positions for a room, straight from the sliding-
    /// sync receipts extension: `userId -> eventId` of each user's latest read
    /// event. The SDK's timeline mis-places the receipt on the *newest* event
    /// (leaves it a message behind), so the timeline reads this to correct it.
    /// Returns nil on failure (so we don't wipe existing receipts).
    /// One room's ephemeral state (read receipts + typing), read from regular
    /// `/sync` — which, unlike the sliding-sync extensions, gives the FULL
    /// receipt state (every reader, so avatars stack) and streams typing.
    /// `since == nil` is the initial snapshot; pass the returned `nextBatch`
    /// with a long `timeout` to stream changes in real time. `receipts` is
    /// `userId -> eventId` for readers present in THIS batch; `typing` is the
    /// current typer list when a typing event was included (else nil).
    struct RoomEphemerals {
        var receipts: [String: String]
        var typing: [String]?
        var nextBatch: String?
    }

    func fetchRoomEphemerals(roomId: String, since: String?) async -> RoomEphemerals? {
        guard let session = try? client.session(),
              let base = URL(string: session.homeserverUrl) else { return nil }
        let filter: [String: Any] = [
            "room": [
                "rooms": [roomId],
                "ephemeral": ["types": ["m.receipt", "m.typing"], "limit": 100],
                "timeline": ["limit": 0],
                "state": ["types": [] as [String]],
            ],
            "presence": ["types": [] as [String]],
            "account_data": ["types": [] as [String]],
        ]
        guard let filterData = try? JSONSerialization.data(withJSONObject: filter),
              let filterString = String(data: filterData, encoding: .utf8),
              var components = URLComponents(
                url: base.appending(path: "_matrix/client/v3/sync"), resolvingAgainstBaseURL: false)
        else { return nil }
        var query = [
            URLQueryItem(name: "filter", value: filterString),
            // Snapshot returns immediately; streaming long-polls up to 30s.
            URLQueryItem(name: "timeout", value: since == nil ? "0" : "30000"),
        ]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let nextBatch = json["next_batch"] as? String
        let room = ((json["rooms"] as? [String: Any])?["join"] as? [String: Any])?[roomId] as? [String: Any]
        let events = (room?["ephemeral"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
        var receipts: [String: String] = [:]
        var receiptTs: [String: Double] = [:]
        var typing: [String]?
        for event in events {
            switch event["type"] as? String {
            case "m.receipt":
                guard let content = event["content"] as? [String: Any] else { continue }
                for (eventId, value) in content {
                    guard let read = (value as? [String: Any])?["m.read"] as? [String: Any] else { continue }
                    for (userId, meta) in read {
                        let ts = (meta as? [String: Any])?["ts"] as? Double ?? 0
                        if ts >= (receiptTs[userId] ?? -1) { receiptTs[userId] = ts; receipts[userId] = eventId }
                    }
                }
            case "m.typing":
                typing = (event["content"] as? [String: Any])?["user_ids"] as? [String] ?? []
            default:
                break
            }
        }
        return RoomEphemerals(receipts: receipts, typing: typing, nextBatch: nextBatch)
    }

    // Commet-compatible extended-profile fields (MSC4133).
    static let bioKey = "chat.commet.profile_bio"
    static let statusKey = "chat.commet.profile_status"
    static let bannerKey = "chat.commet.profile_banner"
    /// MSC4175 standard timezone key. Note: MSC4133 reserves the `m.*` namespace,
    /// and servers that implement extended profiles but NOT MSC4175 (e.g.
    /// Tuwunel) silently reject writes to it — so the field would never persist.
    static let timezoneKey = "m.tz"
    /// Non-reserved fallback so timezone survives on such servers. We write both
    /// and read either (preferring the standard key).
    static let timezoneKeyFallback = "chat.commet.profile_timezone"
    static let socialLinksKey = "foxchat.social_links"

    /// One entry in `foxchat.social_links`: a labeled external link with an
    /// optional icon (mxc or https URL).
    struct SocialLink: Hashable, Identifiable {
        var id: String { "\(title)\u{1}\(link)" }
        var img: String?
        var title: String
        var link: String
    }

    struct ProfileInfo {
        var displayName: String?
        var avatarURL: String?
        var pronouns: String?
        var bio: String?
        var status: String?
        var bannerURL: String?
        var timezone: String?
        var socialLinks: [SocialLink] = []
    }

    /// A user's (federated) profile in one request: displayname, avatar, and the
    /// Commet extended-profile fields (bio, status, banner, timezone, pronouns).
    /// nil on failure.
    /// The client-API base URL, resolving `.well-known/matrix/client` once so
    /// delegated deployments (server name ≠ client host) work. Falls back to the
    /// session's homeserver URL if resolution fails.
    private func apiBase() async -> URL? {
        if let cached = profileCacheLock.withLock({ resolvedAPIBase }) { return cached }
        guard let session = try? client.session(),
              let raw = URL(string: session.homeserverUrl) else { return nil }
        let resolved = await Self.resolveClientAPIBase(serverURL: raw) ?? raw
        profileCacheLock.withLock { resolvedAPIBase = resolved }
        return resolved
    }

    /// Per-server client-API base cache for cross-server profile lookups.
    private var serverBaseCache: [String: URL] = [:]

    /// Serializes the two profile-fetch URL caches (`resolvedAPIBase` +
    /// `serverBaseCache`). `fetchProfile` fans out concurrently — one Task per
    /// call participant when the participant strip resolves everyone's pronouns/
    /// avatars at once — and this class is `@unchecked Sendable`, so without a
    /// lock those concurrent Dictionary mutations corrupt the heap and crash the
    /// app mid-call (a SIGBUS in profile fetch), which drops the call for every
    /// participant and relaunches into a rejoin loop. Never held across `await`.
    private let profileCacheLock = OSAllocatedUnfairLock()

    /// The client-API base URL for a Matrix server name (the `domain` in
    /// `@user:domain`), resolving its `.well-known/matrix/client` so we can query
    /// a remote user's *own* homeserver directly. This matters because Matrix
    /// federation doesn't relay custom extended-profile fields (bio/status/etc.)
    /// — the origin server does return them, and profiles are world-readable.
    private func serverAPIBase(forUserId userId: String) async -> URL? {
        guard let colon = userId.firstIndex(of: ":") else { return await apiBase() }
        let server = String(userId[userId.index(after: colon)...])
        if let cached = profileCacheLock.withLock({ serverBaseCache[server] }) { return cached }
        guard let serverURL = URL(string: "https://\(server)") else { return await apiBase() }
        let resolved = await Self.resolveClientAPIBase(serverURL: serverURL) ?? serverURL
        profileCacheLock.withLock { serverBaseCache[server] = resolved }
        return resolved
    }

    /// Resolves `.well-known/matrix/client` → `m.homeserver.base_url` for a
    /// server URL. Returns nil if there's no delegation (caller falls back).
    private static func resolveClientAPIBase(serverURL: URL) async -> URL? {
        let wellKnown = serverURL.appending(path: ".well-known/matrix/client")
        guard let (data, response) = try? await URLSession.shared.data(from: wellKnown),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hs = (json["m.homeserver"] as? [String: Any])?["base_url"] as? String,
              let url = URL(string: hs.hasSuffix("/") ? String(hs.dropLast()) : hs) else { return nil }
        return url
    }

    func fetchProfile(userId: String) async -> ProfileInfo? {
        guard let session = try? client.session(),
              let base = await serverAPIBase(forUserId: userId) else { return nil }
        let url = base.appending(path: "_matrix/client/v3/profile/\(userId)")
        var request = URLRequest(url: url)
        // Profiles are world-readable; only attach our token when the query goes
        // to our own homeserver, never leaking it to a remote server.
        if userId.hasSuffix(":\(ownServerName)") {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var pronouns: String?
        for key in Self.pronounKeys {
            let raw = (json[key] as? String) ?? ((json[key] as? [String: Any])?["body"] as? String)
            if let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty { pronouns = value; break }
        }
        func nonEmpty(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        }
        let socialLinks: [SocialLink] = (json[Self.socialLinksKey] as? [[String: Any]] ?? [])
            .compactMap { entry in
                guard let link = nonEmpty(entry["link"] as? String) else { return nil }
                let title = nonEmpty(entry["title"] as? String) ?? link
                return SocialLink(img: nonEmpty(entry["img"] as? String), title: title, link: link)
            }
        return ProfileInfo(
            displayName: json["displayname"] as? String,
            avatarURL: json["avatar_url"] as? String,
            pronouns: pronouns,
            bio: nonEmpty((json[Self.bioKey] as? [String: Any])?["body"] as? String
                          ?? json[Self.bioKey] as? String),
            status: nonEmpty(json[Self.statusKey] as? String ?? json["status_msg"] as? String),
            bannerURL: json[Self.bannerKey] as? String,
            timezone: nonEmpty(json[Self.timezoneKey] as? String
                               ?? json[Self.timezoneKeyFallback] as? String),
            socialLinks: socialLinks)
    }

    /// Sets one of the signed-in user's extended-profile fields (empty clears).
    /// `value` may be a String or a JSON object (e.g. bio's `{"body": …}`).
    @discardableResult
    func setProfileField(_ key: String, value: Any) async -> Bool {
        guard let session = try? client.session(),
              let base = await apiBase() else { return false }
        let url = base.appending(path: "_matrix/client/v3/profile/\(userId)/\(key)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [key: value])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code)
        else { return false }
        return true
    }

    /// Sets our own presence `status_msg` — the field Commet-family clients read
    /// as the user's status. Empty clears it. `presence: "online"` is required by
    /// the endpoint.
    @discardableResult
    func setPresenceStatus(_ statusMsg: String) async -> Bool {
        guard let session = try? client.session(),
              let base = await apiBase() else { return false }
        let url = base.appending(path: "_matrix/client/v3/presence/\(userId)/status")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["presence": "online", "status_msg": statusMsg])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code)
        else { return false }
        return true
    }

    /// Room IDs shared with `userId` (both of us joined), via MSC2666. Returns
    /// [] when the homeserver doesn't support the endpoint. Paginates through
    /// `next_batch_token`, capped so a broken server can't loop forever.
    func mutualRooms(with userId: String) async -> [String] {
        guard let session = try? client.session(), let base = await apiBase() else { return [] }
        var joined: [String] = []
        var batch: String?
        for _ in 0..<20 {
            guard var comps = URLComponents(
                url: base.appending(path: "_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms"),
                resolvingAgainstBaseURL: false) else { break }
            comps.queryItems = [URLQueryItem(name: "user_id", value: userId)]
            if let batch { comps.queryItems?.append(URLQueryItem(name: "batch_token", value: batch)) }
            guard let url = comps.url else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["joined"] as? [String] else { break }
            joined.append(contentsOf: ids)
            batch = json["next_batch_token"] as? String
            if batch == nil { break }
        }
        return joined
    }

    /// A user's pronouns; nil when unset.
    func fetchPronouns(userId: String) async -> String? {
        await fetchProfile(userId: userId)?.pronouns
    }

    /// Sets the signed-in user's own pronouns, writing the common keys (empty
    /// string clears them). Returns true if at least one write succeeded.
    @discardableResult
    func setPronouns(_ pronouns: String) async -> Bool {
        guard let session = try? client.session(),
              let base = await apiBase() else { return false }
        var anySucceeded = false
        for key in ["pronouns", "foxchat.pronouns"] {
            let url = base.appending(path: "_matrix/client/v3/profile/\(userId)/\(key)")
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [key: pronouns])
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) {
                anySucceeded = true
            }
        }
        return anySucceeded
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
        #if os(macOS)
        if let backgroundActivity {
            ProcessInfo.processInfo.endActivity(backgroundActivity)
            self.backgroundActivity = nil
        }
        #endif
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
            // The notification service extension opens the same crypto store in
            // multi-process mode; the main app must declare cross-process locking
            // too, or the shared store's lock state corrupts and the app crashes
            // when sync touches crypto (e.g. after tapping a push).
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: "mainapp"))
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
    static let callbackScheme = "com.riiiiiiiley.discourse"
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
                clientUri: "https://github.com/riiiiiiiley/Discourse",
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

