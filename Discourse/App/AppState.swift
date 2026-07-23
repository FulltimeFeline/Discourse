import Foundation
import Observation

/// Root state machine: launching → loggedOut → active(session).
@MainActor
@Observable
final class AppState {
    enum Phase {
        case launching
        case loggedOut
        /// Homeserver unreachable; session kept, retrying.
        case disconnected
        case active(SessionScope)
    }

    private(set) var phase: Phase = .launching
    var isQuickSwitcherPresented = false
    var isAddAccountPresented = false
    /// Set on notification click; the main window navigates and clears it.
    var pendingRoomNavigation: String?
    /// Room + event to jump to. The main window opens the room but leaves this
    /// set — the timeline clears it once it has scrolled to the event.
    var pendingEventNavigation: EventNavigation?
    var isSignOutConfirmPresented = false

    struct EventNavigation: Equatable {
        let roomId: String
        let eventId: String
        /// Consumers drop requests older than ~30s, so a navigation that never
        /// found its room doesn't fire hours later when the room opens.
        var requestedAt = Date()
    }
    var sidebarFilterFocusRequest = 0
    var ringingCall: RingingCall?
    /// Set when a ring is accepted; the room's timeline joins the call and clears it.
    var pendingCallJoin: String?
    /// Rooms whose call is open in a detached window; hides the in-room join banner.
    var activeCallRoomIds: Set<String> = []

    struct RingingCall: Identifiable, Equatable {
        var id: String { roomId }
        let roomId: String
        let roomName: String
        let avatarURL: String?
        let isDirect: Bool
    }

    // MARK: Timeline scroll memory

    /// Last visible event per room (nil/absent = bottom), persisted so reopening
    /// lands where you left off. Keyed by event ID: the SDK's timeline item IDs
    /// are per-instance and don't survive a relaunch.
    @ObservationIgnored private lazy var timelineAnchors: [String: String] = {
        let json = UserDefaults.standard.string(forKey: "timelineScrollAnchors") ?? "{}"
        return (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }()

    func timelineAnchor(forRoom roomId: String) -> String? {
        timelineAnchors[roomId]
    }

    func setTimelineAnchor(_ eventId: String?, forRoom roomId: String) {
        timelineAnchors[roomId] = eventId
        if let data = try? JSONEncoder().encode(timelineAnchors),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "timelineScrollAnchors")
        }
    }
    var newChatSheet: NewChatSheet?
    /// All signed-in accounts, in sign-in order.
    private(set) var accountTokens: [RestorationToken] = []

    private let sessionStore = SessionStore()
    /// Warm sessions, kept across account switches. Keyed by user ID.
    private var scopes: [String: SessionScope] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    var activeUserId: String? {
        if case .active(let scope) = phase { return scope.userId }
        return nil
    }

    /// Called once at launch: restore the last active account, if any.
    func start() async {
        guard case .launching = phase else { return }
        accountTokens = sessionStore.loadAll()
        guard !accountTokens.isEmpty else {
            phase = .loggedOut
            return
        }
        let target = sessionStore.activeUserId ?? accountTokens[0].session.userId
        await activate(userId: target)
        // Bring up the other accounts in the background so they, too, notify and
        // feed unread badges. Detached so it never delays the active account's UI.
        Task { await warmBackgroundAccounts() }
    }

    func switchAccount(to userId: String) async {
        guard userId != activeUserId else { return }
        await activate(userId: userId)
    }

    /// The session a notification action (reply / mark read) runs against.
    /// Background accounts go straight to their warm scope (only a syncing
    /// scope can have notified). Cold launch has only the active scope warm, so
    /// switch accounts first, then act on the now-active session.
    func sessionForNotificationAction(accountUserId: String?) async -> SessionScope? {
        if let accountUserId, accountUserId != activeUserId {
            if let warm = scopes[accountUserId] { return warm }
            await switchAccount(to: accountUserId)
            guard case .active(let scope) = phase, scope.userId == accountUserId else { return nil }
            return scope
        }
        if case .active(let scope) = phase { return scope }
        return nil
    }

    // MARK: Multi-account notifications & badges

    /// Restore + keep warm every other signed-in account, so background accounts
    /// sync (firing notifications on macOS and driving cross-account unread
    /// badges) and — on iOS — register a pusher for remote notifications. Local
    /// notification *display* and pusher registration each respect the account's
    /// per-account toggle; warming itself is unconditional so badges still work.
    func warmBackgroundAccounts() async {
        for token in accountTokens {
            let userId = token.session.userId
            guard userId != activeUserId, scopes[userId] == nil else { continue }
            guard let service = try? await MatrixService.restore(token: token) else { continue }
            let scope = SessionScope(service: service, token: token)
            scopes[userId] = scope
            registerBadgeReporting(for: scope)
            await scope.roomList.primeSnapshotForLaunch()
            Task { await scope.roomList.start() }
            #if os(iOS)
            PushRegistry.shared.registerPusher(for: service)
            #endif
        }
    }

    /// Live unread total for an account (0 if it isn't warm).
    func unreadCount(forUserId userId: String) -> Int {
        scopes[userId]?.roomList.unreadTotal ?? 0
    }

    /// Whether any signed-in account other than the active one has unread
    /// activity — drives the account-switcher / settings badge.
    var otherAccountsHaveUnread: Bool {
        scopes.contains { $0.key != activeUserId && $0.value.roomList.unreadTotal > 0 }
    }

    /// Display name (falling back to the localpart) for an account, for
    /// notification labels and the account list.
    func accountDisplayName(forUserId userId: String) -> String {
        if let name = scopes[userId]?.ownDisplayName, !name.isEmpty { return name }
        return Self.localpart(of: userId)
    }

    static func localpart(of userId: String) -> String {
        guard userId.hasPrefix("@") else { return userId }
        return String(userId.dropFirst().prefix(while: { $0 != ":" }))
    }

    /// Toggles an account's notifications: persists the choice and, on iOS,
    /// registers or deletes that account's pusher accordingly.
    func setNotificationsEnabled(_ enabled: Bool, forUserId userId: String) {
        Preferences.shared.setNotificationsEnabled(enabled, forUserId: userId)
        #if os(iOS)
        if let scope = scopes[userId] {
            PushRegistry.shared.registerPusher(for: scope.service)
        }
        #endif
    }

    /// PNG bytes for an avatar (mxc), fetched via the owning account's media
    /// loader so a local notification can show the pfp. Uses a warm scope if
    /// present, else the active one; never switches accounts.
    func notificationAvatarData(mxcUrl: String, accountUserId: String?) async -> Data? {
        let scope: SessionScope?
        if let accountUserId, let warm = scopes[accountUserId] {
            scope = warm
        } else if case .active(let active) = phase {
            scope = active
        } else {
            scope = nil
        }
        guard let scope,
              let image = await scope.mediaLoader.avatar(mxcUrl: mxcUrl, pixelSize: 128)
        else { return nil }
        return image.pngRepresentation
    }

    // MARK: App badge

    /// App badge is the unread sum over every warm account, not just whichever
    /// scope last synced. Also wires each scope's auth-error signal so a revoked
    /// background account gets signed out too.
    private func registerBadgeReporting(for scope: SessionScope) {
        scope.roomList.onUnreadTotalChanged = { [weak self] in
            self?.updateAggregateBadge()
        }
        scope.onAuthError = { [weak self] userId in
            Task { await self?.handleAuthError(userId: userId) }
        }
        scope.startAuthErrorMonitor()
        // Clear the once-per-account guard, so a re-signed-in account can be
        // signed out again if its new token also dies.
        authErrorHandledUserIds.remove(scope.userId)
        updateAggregateBadge()
    }

    /// Accounts already torn down for a dead token; the delegate can fire
    /// repeatedly for the same session.
    @ObservationIgnored private var authErrorHandledUserIds: Set<String> = []

    /// Confirmed unknown-token / soft-logout: the token is dead, so retrying
    /// restore (`.disconnected`) is futile. Remove the account so relaunch
    /// doesn't loop on it, then fall back to the next account or login. Like
    /// `logOut` but skips the network logout (token already invalid).
    func handleAuthError(userId: String) async {
        guard !authErrorHandledUserIds.contains(userId),
              accountTokens.contains(where: { $0.session.userId == userId }) else { return }
        authErrorHandledUserIds.insert(userId)

        let isActive = activeUserId == userId
        if let scope = scopes[userId] {
            scope.tearDown()
            SessionStore.removeSessionDirectories(token: scope.token)
            RoomListViewModel.removeSnapshot(forUserId: userId)
            MediaLoader.removeDiskCache(forUserId: userId)
            scopes[userId] = nil
        }
        accountTokens.removeAll { $0.session.userId == userId }
        try? sessionStore.saveAll(accountTokens)
        updateAggregateBadge()

        guard isActive else { return }
        // The active account's notification handlers point at the dead scope.
        NotificationManager.shared.openRoom = nil
        NotificationManager.shared.sendReply = nil
        NotificationManager.shared.markRoomRead = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        if let next = accountTokens.first {
            phase = .launching
            await activate(userId: next.session.userId)
        } else {
            sessionStore.clearAll()
            phase = .loggedOut
        }
    }

    private func updateAggregateBadge() {
        let total = scopes.values.reduce(0) { $0 + $1.roomList.unreadTotal }
        Platform.setBadge(count: total)
    }

    func logIn(homeserver: String, username: String, password: String) async throws {
        let (service, token) = try await MatrixService.logIn(
            homeserver: homeserver, username: username, password: password)
        try completeLogin(service: service, token: token)
    }

    /// Finalizes any auth result: persist the token, enter the session.
    func completeLogin(service: MatrixService, token: RestorationToken) throws {
        accountTokens.removeAll { $0.session.userId == token.session.userId }
        accountTokens.append(token)
        try sessionStore.saveAll(accountTokens)
        sessionStore.activeUserId = token.session.userId
        let scope = SessionScope(service: service, token: token)
        scopes[token.session.userId] = scope
        registerBadgeReporting(for: scope)
        isAddAccountPresented = false
        phase = .active(scope)
        #if os(iOS)
        PushRegistry.shared.setActiveService(scope.service)
        #endif
    }

    /// Signs out the active account; falls back to the next account if any.
    func logOut() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard case .active(let scope) = phase else {
            phase = .loggedOut
            return
        }
        scope.tearDown()
        // Handlers capture this scope; a queued action must not fire into a
        // dead session (the next account re-wires them).
        NotificationManager.shared.openRoom = nil
        NotificationManager.shared.sendReply = nil
        NotificationManager.shared.markRoomRead = nil
        await scope.service.logOut()
        SessionStore.removeSessionDirectories(token: scope.token)
        // Per-account cold-launch persistence: drop the sidebar snapshot and
        // disk thumbnails (which include encrypted-room avatars).
        RoomListViewModel.removeSnapshot(forUserId: scope.userId)
        MediaLoader.removeDiskCache(forUserId: scope.userId)
        scopes[scope.userId] = nil
        updateAggregateBadge()
        accountTokens.removeAll { $0.session.userId == scope.userId }
        try? sessionStore.saveAll(accountTokens)
        if let next = accountTokens.first {
            phase = .launching
            await activate(userId: next.session.userId)
        } else {
            sessionStore.clearAll()
            phase = .loggedOut
        }
    }

    private func activate(userId: String) async {
        guard let token = accountTokens.first(where: { $0.session.userId == userId }) else {
            phase = accountTokens.isEmpty ? .loggedOut : phase
            return
        }
        // Clear the outgoing account's "room on screen" marker. Otherwise its warm
        // background sync keeps treating that room as active and auto-clears its
        // unread on every message — rooms going read without being opened.
        if case .active(let current) = phase, current.userId != userId {
            current.roomList.activeRoomId = nil
        }
        if let warm = scopes[userId] {
            reconnectTask?.cancel()
            reconnectTask = nil
            sessionStore.activeUserId = userId
            phase = .active(warm)
            #if os(iOS)
            PushRegistry.shared.setActiveService(warm.service)
            #endif
            return
        }
        do {
            let service = try await MatrixService.restore(token: token)
            let scope = SessionScope(service: service, token: token)
            scopes[userId] = scope
            registerBadgeReporting(for: scope)
            sessionStore.activeUserId = userId
            reconnectTask?.cancel()
            reconnectTask = nil
            // Paint the cached sidebar before flipping to .active, so the first
            // frame shows chats instead of an empty list. Disk read is off-main
            // and the spinner is still up, so this adds no visible latency.
            await scope.roomList.primeSnapshotForLaunch()
            phase = .active(scope)
            #if os(iOS)
            PushRegistry.shared.setActiveService(scope.service)
            #endif
            // Start sync here, not from MainWindow's `.task`: the view tree
            // takes ~150–200ms to build before that fires, and until the first
            // diff lands the snapshot rooms have no FFI backing and can't open.
            // Idempotent — MainWindow's `.task` re-calls start() as a no-op.
            Task { await scope.roomList.start() }
        } catch {
            // Restore fails only when the server is unreachable or the client
            // can't build; a revoked token surfaces later, during sync. So keep
            // retrying rather than logging out on a transient network blip.
            phase = .disconnected
            scheduleReconnect(userId: userId)
        }
    }

    /// Retries restore every 30s until the server is reachable. No-op if a
    /// retry loop is already running.
    private func scheduleReconnect(userId: String) {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, case .disconnected = self.phase else { return }
                await self.activate(userId: userId)
            }
        }
    }
}

/// Everything scoped to a signed-in session. Torn down wholesale on logout.
@MainActor
@Observable
final class SessionScope {
    let service: MatrixService
    let token: RestorationToken
    let roomList: RoomListViewModel
    let mediaLoader: MediaLoader
    let stickers: StickerStore
    let customEmoji: CustomEmojiStore
    let presence: PresenceService
    let pronouns: PronounsStore

    struct IncomingVerification: Identifiable, Equatable {
        var id: String { flowId }
        let senderId: String
        let flowId: String
    }

    /// Not yet cross-signed: encrypted history stays locked until the user
    /// verifies or enters their recovery key.
    private(set) var needsVerification = false
    /// Own avatar (mxc URL), for the rail switcher.
    private(set) var ownAvatarURL: String?
    private(set) var ownDisplayName: String?

    /// Own extended-profile fields (Settings → Account).
    private(set) var ownPronouns: String?
    private(set) var ownBio: String?
    private(set) var ownStatus: String?
    private(set) var ownTimezone: String?
    private(set) var ownBannerURL: String?
    private(set) var ownSocialLinks: [MatrixService.SocialLink] = []

    func loadOwnProfile() async {
        if let url = try? await service.client.avatarUrl() {
            ownAvatarURL = url
        }
        if let name = try? await service.client.displayName() {
            ownDisplayName = name
        }
        if let profile = await service.fetchProfile(userId: service.userId) {
            ownPronouns = profile.pronouns
            ownBio = profile.bio
            ownStatus = profile.status
            ownTimezone = profile.timezone
            ownBannerURL = profile.bannerURL
            ownSocialLinks = profile.socialLinks
        }
    }

    // MARK: Profile editing (Settings → Account)

    func setDisplayName(_ name: String) async throws {
        try await service.client.setDisplayName(name: name)
        ownDisplayName = name
    }

    func setPronouns(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        await service.setPronouns(trimmed)
        let resolved = trimmed.isEmpty ? nil : trimmed
        ownPronouns = resolved
        pronouns.setLocal(resolved, for: service.userId)
    }

    func setBio(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bio is an object with a `body`, per Commet's schema.
        await service.setProfileField(MatrixService.bioKey, value: ["body": trimmed])
        ownBio = trimmed.isEmpty ? nil : trimmed
        pronouns.invalidate(service.userId)
    }

    func setStatus(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Commet-family clients read the status from presence `status_msg`; also
        // keep the profile field for clients that read that instead.
        await service.setPresenceStatus(trimmed)
        await service.setProfileField(MatrixService.statusKey, value: trimmed)
        ownStatus = trimmed.isEmpty ? nil : trimmed
        pronouns.invalidate(service.userId)
    }

    func setTimezone(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Write the standard MSC4175 key (for interop) AND a non-reserved
        // fallback: servers like Tuwunel reject `m.tz`, so the fallback is what
        // actually persists and reads back — otherwise the field looks emptied.
        await service.setProfileField(MatrixService.timezoneKey, value: trimmed)
        await service.setProfileField(MatrixService.timezoneKeyFallback, value: trimmed)
        ownTimezone = trimmed.isEmpty ? nil : trimmed
        pronouns.invalidate(service.userId)
    }

    func setSocialLinks(_ links: [MatrixService.SocialLink]) async {
        // [String: String] (not [String: Any]) so the payload stays Sendable
        // across the actor hop into the service.
        let payload: [[String: String]] = links.map { link in
            var dict: [String: String] = ["title": link.title, "link": link.link]
            if let img = link.img, !img.isEmpty { dict["img"] = img }
            return dict
        }
        await service.setProfileField(MatrixService.socialLinksKey, value: payload)
        ownSocialLinks = links
        pronouns.invalidate(service.userId)
    }

    func setAvatar(data: Data, mimeType: String) async throws {
        try await service.client.uploadAvatar(mimeType: mimeType, data: data)
        await loadOwnProfile()
    }

    func removeAvatar() async throws {
        try await service.client.removeAvatar()
        ownAvatarURL = nil
    }

    /// Uploads an image and sets it as the Commet profile banner.
    func setBanner(data: Data, mimeType: String) async throws {
        let mxc = try await service.client.uploadMedia(mimeType: mimeType, data: data,
                                                       progressWatcher: nil)
        await service.setProfileField(MatrixService.bannerKey, value: mxc)
        ownBannerURL = mxc
        pronouns.invalidate(service.userId)
    }

    func removeBanner() async {
        await service.setProfileField(MatrixService.bannerKey, value: "")
        ownBannerURL = nil
        pronouns.invalidate(service.userId)
    }

    /// Custom state event holding a space's banner image.
    static let spaceBannerEventType = "page.codeberg.everypizza.room.banner"

    /// Whether this user can change the given space's banner — the edit controls
    /// hide when this is false rather than offering an action that would fail.
    func canEditSpaceBanner(spaceId: String) async -> Bool {
        await service.canSendStateEvent(roomId: spaceId, type: Self.spaceBannerEventType)
    }

    /// Uploads an image and sets it as a space's banner (state event). Returns
    /// the new banner mxc URL on success, or nil if the user lacks permission.
    func setSpaceBanner(spaceId: String, data: Data, mimeType: String) async throws -> String? {
        let mxc = try await service.client.uploadMedia(mimeType: mimeType, data: data,
                                                       progressWatcher: nil)
        let ok = await service.setStateEvent(
            roomId: spaceId,
            type: Self.spaceBannerEventType,
            content: ["url": mxc, "mimetype": mimeType])
        return ok ? mxc : nil
    }

    @discardableResult
    func removeSpaceBanner(spaceId: String) async -> Bool {
        await service.setStateEvent(
            roomId: spaceId,
            type: Self.spaceBannerEventType,
            content: [:])
    }
    /// Set when another device asks this one to verify; drives a sheet.
    var incomingVerification: IncomingVerification?

    private var verificationRetained: [Any] = []
    private var verificationTask: Task<Void, Never>?
    private var incomingWatchTask: Task<Void, Never>?
    private var verificationDelegateBridge: SessionVerificationDelegateBridge?

    /// Fires with this scope's user ID when the SDK reports the token is dead.
    /// Wired by AppState to drop into re-auth.
    var onAuthError: ((String) -> Void)?
    private var authErrorTask: Task<Void, Never>?

    /// Watches the client's unknown-token signal. Start once, after AppState
    /// wires `onAuthError`.
    func startAuthErrorMonitor() {
        guard authErrorTask == nil else { return }
        authErrorTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.service.authErrorStream {
                self.onAuthError?(self.userId)
            }
        }
    }

    init(service: MatrixService, token: RestorationToken) {
        self.service = service
        self.token = token
        self.roomList = RoomListViewModel(service: service)
        self.mediaLoader = MediaLoader(client: service.client)
        self.stickers = StickerStore(client: service.client)
        self.customEmoji = CustomEmojiStore(client: service.client)
        self.pronouns = PronounsStore(service: service)
        self.presence = PresenceService(homeserverUrl: token.session.homeserverUrl,
                                        accessToken: token.session.accessToken,
                                        ownUserId: token.session.userId)
        // Status comes from presence `status_msg` (Commet's store), so let the
        // profile cache read it with the profile field as fallback.
        self.pronouns.presence = self.presence
        customEmoji.spacesProvider = { [weak roomList] in
            roomList?.spaces.map { (id: $0.id, name: $0.name) } ?? []
        }
        // Prime once the first sync has delivered the space list, so emote
        // reactions label correctly and `:autocomplete:` works before the
        // picker opens. The store re-checks the space set on every later call.
        Task { [customEmoji] in
            try? await Task.sleep(for: .seconds(5))
            await customEmoji.refreshIfStale()
        }
        // 56px = the sidebar rows' request; the rail's 80px falls back to these
        // entries until its own lands.
        roomList.prewarmAvatars = { [mediaLoader] urls in
            await mediaLoader.prewarmThumbnails(mxcUrls: urls, pixelSize: 56)
        }
    }

    var userId: String { service.userId }

    func startVerificationMonitor() {
        guard verificationTask == nil else { return }
        needsVerification = service.verificationState == .unverified
        let (stream, retained) = service.verificationStates()
        verificationRetained = retained
        verificationTask = Task { [weak self] in
            for await state in stream {
                self?.needsVerification = state == .unverified
            }
        }
        Task { await watchForIncomingVerification() }
    }

    /// Delegate on the session-verification controller, so requests from other
    /// devices surface here.
    func watchForIncomingVerification() async {
        guard let controller = try? await service.sessionVerificationController() else { return }
        let bridge = SessionVerificationDelegateBridge()
        verificationDelegateBridge = bridge
        controller.setDelegate(delegate: bridge)
        incomingWatchTask?.cancel()
        incomingWatchTask = Task { [weak self] in
            for await event in bridge.stream {
                if case .requestReceived(let senderId, let flowId) = event {
                    self?.incomingVerification = IncomingVerification(senderId: senderId, flowId: flowId)
                }
            }
        }
    }

    @ObservationIgnored private var timelines: [String: TimelineViewModel] = [:]
    /// Room IDs by access recency, oldest first. Drives LRU eviction.
    @ObservationIgnored private var timelineAccessOrder: [String] = []
    /// Each cached view model holds a live FFI timeline + diff listener, so
    /// unbounded caching gets expensive.
    private static let maxLiveTimelines = 8

    /// One view model per room, kept alive up to a cap so revisiting a recent
    /// room is instant. Evicted rooms rebuild on reopen.
    func timeline(forRoomId roomId: String) -> TimelineViewModel? {
        if let existing = timelines[roomId] {
            touchTimeline(roomId)
            return existing
        }
        guard let room = roomList.ffiRoom(withId: roomId) else { return nil }
        let viewModel = TimelineViewModel(room: room, ownUserId: userId,
                                          mediaLoader: mediaLoader, service: service,
                                          customEmoji: customEmoji)
        viewModel.isVideoRoom = roomList.videoRoomIds.contains(roomId)
        timelines[roomId] = viewModel
        touchTimeline(roomId)
        evictTimelinesIfNeeded()
        return viewModel
    }

    private func touchTimeline(_ roomId: String) {
        timelineAccessOrder.removeAll { $0 == roomId }
        timelineAccessOrder.append(roomId)
    }

    private func evictTimelinesIfNeeded() {
        guard timelines.count > Self.maxLiveTimelines else { return }
        for roomId in timelineAccessOrder {
            guard timelines.count > Self.maxLiveTimelines else { return }
            // Never evict the visible room (the only unparked one) or a room
            // whose call is still running in a detached window.
            guard let viewModel = timelines[roomId], viewModel.isParked,
                  calls[roomId] == nil else { continue }
            viewModel.stop()
            timelines[roomId] = nil
            timelineAccessOrder.removeAll { $0 == roomId }
        }
    }

    /// Sends plain text to a room without its timeline being on screen (the
    /// notification Reply action). Starts the cached view model if needed, then
    /// re-parks it so it stays evictable.
    func sendMessage(_ text: String, toRoomId roomId: String) async {
        // Cold launch replays queued replies while the sidebar is still
        // snapshot-only (no FFI rooms yet); wait for sync to deliver the room
        // instead of dropping the user's text.
        guard let viewModel = await awaitTimeline(forRoomId: roomId) else { return }
        await viewModel.start()
        // A parked view model may hold an in-progress edit/reply; a
        // notification reply must not hijack it.
        let savedEdit = viewModel.editTarget
        let savedReply = viewModel.replyTarget
        viewModel.editTarget = nil
        viewModel.replyTarget = nil
        await viewModel.sendText(text)
        // Restore only if the user didn't touch the composer during the send.
        if viewModel.editTarget == nil { viewModel.editTarget = savedEdit }
        if viewModel.replyTarget == nil { viewModel.replyTarget = savedReply }
        if roomList.activeRoomId != roomId {
            viewModel.isParked = true
        }
    }

    /// `timeline(forRoomId:)` with a bounded wait for the FFI room (up to ~30s,
    /// polled at 500ms); snapshot-restored rooms have no backing until the
    /// first sync batch lands.
    private func awaitTimeline(forRoomId roomId: String) async -> TimelineViewModel? {
        for _ in 0..<60 {
            if let viewModel = timeline(forRoomId: roomId) { return viewModel }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    @ObservationIgnored private var calls: [String: CallViewModel] = [:]

    /// The live call for a room, created once and kept alive so it can run in a
    /// detached window independent of any view lifecycle.
    func call(forRoomId roomId: String) -> CallViewModel? {
        if let existing = calls[roomId] { return existing }
        guard let viewModel = timeline(forRoomId: roomId)?.callViewModel() else { return nil }
        calls[roomId] = viewModel
        return viewModel
    }

    /// Tears down and drops the call, so reopening starts a fresh session.
    func endCall(forRoomId roomId: String) {
        calls[roomId]?.stop()
        calls[roomId] = nil
    }

    func tearDown() {
        verificationTask?.cancel()
        verificationTask = nil
        incomingWatchTask?.cancel()
        incomingWatchTask = nil
        authErrorTask?.cancel()
        authErrorTask = nil
        verificationDelegateBridge = nil
        verificationRetained = []
        timelines.values.forEach { $0.stop() }
        timelines = [:]
        timelineAccessOrder = []
        roomList.stop()
    }
}
