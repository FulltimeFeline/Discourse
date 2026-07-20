import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct DiscourseApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif

    init() {
        MatrixPlatform.initializeOnce()
        NotificationManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootContainer()
                .environment(appState)
                .environment(Preferences.shared)
                .task { await appState.start() }
        }
        .commands {
            AppCommands(appState: appState)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
        // Pause presence polling in the background (macOS hits .background when
        // windows are closed/occluded too), resume on return. Sync is the SDK's.
        .onChange(of: scenePhase) { _, newPhase in
            guard case .active(let scope) = appState.phase else { return }
            switch newPhase {
            case .background:
                scope.presence.pause()
                #if os(iOS)
                // Stop sync cleanly before suspension, under a short background
                // assertion. macOS stays always-on (powers local notifications
                // with its windows closed).
                pauseSyncForBackground(scope)
                #endif
            case .active:
                scope.presence.resume()
                #if os(iOS)
                Task { await scope.service.resumeSync() }
                #endif
            default:
                break
            }
        }

        // Detached call window, one per room, so the app stays usable in a call.
        WindowGroup(id: "call", for: String.self) { $roomId in
            if let roomId, case .active(let scope) = appState.phase,
               let call = scope.call(forRoomId: roomId) {
                CallWindowView(roomId: roomId, viewModel: call)
                    .themedByPreferences()
                    .environment(appState)
                    .environment(Preferences.shared)
            }
        }
        .defaultSize(width: 900, height: 620)

        #if os(macOS)
        // Separate scene: needs its own Preferences injection and theme, since
        // the appearance controls live here and must update this window live.
        Settings {
            SettingsView()
                .themedByPreferences()
                .environment(appState)
                .environment(Preferences.shared)
        }
        #endif
    }

    #if os(iOS)
    /// Stops sync under a background-task assertion, so the loop halts before
    /// suspension rather than being killed mid-request.
    @MainActor
    private func pauseSyncForBackground(_ scope: SessionScope) {
        let app = UIApplication.shared
        var assertion: UIBackgroundTaskIdentifier = .invalid
        assertion = app.beginBackgroundTask(withName: "discourse.pauseSync") {
            app.endBackgroundTask(assertion)
            assertion = .invalid
        }
        Task { @MainActor in
            await scope.service.pauseSync()
            if assertion != .invalid {
                app.endBackgroundTask(assertion)
                assertion = .invalid
            }
        }
    }
    #endif
}

/// Hosts a call in its own window, syncing shared state so the in-room banner
/// reflects it and the session tears it down on close.
struct CallWindowView: View {
    @Environment(AppState.self) private var appState
    let roomId: String
    let viewModel: CallViewModel

    var body: some View {
        CallView(viewModel: viewModel)
            .onAppear { appState.activeCallRoomIds.insert(roomId) }
            .onDisappear {
                appState.activeCallRoomIds.remove(roomId)
                if case .active(let scope) = appState.phase {
                    scope.endCall(forRoomId: roomId)
                }
            }
    }
}

/// Applies appearance preferences (theme + accent) above the phase router, so
/// they cover the login screen too.
struct RootContainer: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        RootView()
            .preferredColorScheme(prefs.colorScheme)
            .tint(prefs.resolvedTint)
    }
}

/// Applies appearance preferences to any scene. Reads `Preferences` from the
/// environment (inject it OUTSIDE this modifier), so a theme change in the
/// Settings window updates that window live.
private struct PreferencesTheme: ViewModifier {
    @Environment(Preferences.self) private var prefs
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(prefs.colorScheme)
            .tint(prefs.resolvedTint)
    }
}

extension View {
    func themedByPreferences() -> some View { modifier(PreferencesTheme()) }
}

/// Launch backdrop shown while the session restores: just the window
/// background, so cold launch reads as an already-open app filling in rather
/// than a loading screen.
private struct LaunchBackdrop: View {
    var body: some View {
        Color.platformWindowBackground
            .ignoresSafeArea()
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .launching:
            // No spinner splash: restore takes ~0.4s and a loading screen for
            // that reads as slow. The backdrop matches the chat window
            // background; chats replace it the instant restore lands.
            LaunchBackdrop()
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 480)
                #endif
        case .loggedOut:
            LoginView()
        case .disconnected:
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Can't connect to server")
                    .font(.headline)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Trying to reconnect…")
                        .foregroundStyle(.secondary)
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
        case .active(let scope):
            MainWindow(scope: scope)
                .id(scope.userId)
                #if os(macOS)
                .frame(minHeight: 480)
                #endif
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var prefs
    let scope: SessionScope
    @State private var selectedRoom: String?
    @State private var showsVerification = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Rail width, measured from the traffic-light cluster so the rail sits
    /// under it. 68 is the fallback until the window exists to measure.
    @State private var railWidth: CGFloat = 68
    /// Last selected room per space (and Home) plus the last open space,
    /// JSON-encoded, persisted per account.
    @AppStorage("roomSelectionBySpace") private var storedSelections = "{}"

    private var spaceKey: String {
        "\(scope.userId)|\(scope.roomList.selectedSpaceId ?? "home")"
    }

    private var spaceMemoryKey: String { "\(scope.userId)|__space" }

    private func selectionMap() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self,
                                   from: Data(storedSelections.utf8))) ?? [:]
    }

    private func rememberSelection(_ roomId: String?, forKey key: String) {
        var map = selectionMap()
        map[key] = roomId
        if let data = try? JSONEncoder().encode(map),
           let json = String(data: data, encoding: .utf8) {
            storedSelections = json
        }
    }

    var body: some View {
        splitView
            // At the root so the rail's avatars load too, not just the columns.
            .environment(\.mediaLoader, scope.mediaLoader)
            .environment(\.presenceService, scope.presence)
            .overlay(alignment: .top) {
                if let call = appState.ringingCall {
                    IncomingCallView(call: call) {
                        appState.ringingCall = nil
                        appState.pendingCallJoin = call.roomId
                        appState.pendingRoomNavigation = call.roomId
                    } decline: {
                        appState.ringingCall = nil
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: appState.ringingCall)
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The chat mounted over the room list (phone only). Distinct from
    /// `selectedRoom`, which persists per space: swiping back to the list
    /// slides the chat away but the room stays selected.
    @State private var pushedRoomId: String?
    /// 0 = room list, 1 = chat fully on screen; tracks the finger mid-swipe.
    @State private var chatProgress: CGFloat = 0
    @State private var panBase: CGFloat = 0
    /// Gesture translation at capture: the finger has already moved by the
    /// minimum distance, so measuring from here keeps the chat from snapping
    /// forward by that much.
    @State private var panStart: CGFloat = 0
    @State private var isPanning = false
    /// When the last pager pan released; row taps within a beat of it are the
    /// pan's own touch-up, not selection.
    @State private var lastPanEndedAt = Date.distantPast
    /// Measured bar height, fed to the base tabs as a bottom inset so their
    /// content scrolls clear of the overlaid glass bar.
    @State private var tabBarHeight: CGFloat = 60

    private var isPhone: Bool { horizontalSizeClass == .compact }

    private func setFocusedChat(_ roomId: String?) {
        NotificationManager.shared.focusedRoomId = roomId
        scope.roomList.activeRoomId = roomId
    }

    /// Slides the chat layer in (mounting it first if it's a different room).
    private func openChat(_ roomId: String) {
        // The call cover hangs off the pushed room's TimelineView; remounting
        // for a different room would tear it down and hang up. Drop
        // foreign-room navigation while a call is live.
        if let current = pushedRoomId, current != roomId,
           appState.activeCallRoomIds.contains(current) {
            return
        }
        // Opening a room always lands on the Chat tab.
        phoneTab = .chat
        if pushedRoomId != roomId { pushedRoomId = roomId }
        let vm = scope.timeline(forRoomId: roomId)
        vm?.isParked = false
        vm?.markAsRead()
        setFocusedChat(roomId)
        withAnimation(.pagerSettle) {
            chatProgress = 1
        }
    }

    /// Slides the chat layer out but keeps it mounted, parked offscreen, so
    /// swiping back reveals it as left. Unmount-and-restore made the timeline
    /// visibly re-scroll during the swipe.
    private func closeChat() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let id = pushedRoomId, let vm = scope.timeline(forRoomId: id) {
            appState.setTimelineAnchor(vm.scrollAnchorEventId, forRoom: id)
            vm.isParked = true
        }
        setFocusedChat(nil)
        withAnimation(.pagerSettle) {
            chatProgress = 0
        }
    }

    private enum PhoneTab: Hashable { case chat, settings }
    @State private var phoneTab: PhoneTab = .chat

    /// A Chat/Settings tab bar anchored to the room-list layer so it rides the
    /// list's parallax and the chat covers it on the way in. A system TabView
    /// bar can't do this (it draws over tab content).
    private var phoneLayout: some View {
        chatTab
    }

    /// The room list and the selected chat as side-by-side layers of one pager:
    /// the chat slides over the list tracking the finger, either direction.
    private var chatTab: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .topLeading) {
                Group {
                    if phoneTab == .chat {
                        listLayer
                            // Parallax: the list drifts as the chat rides over it.
                            .offset(x: -chatProgress * width * 0.25)
                    } else {
                        ProfileTabView(scope: scope)
                    }
                }
                // Bottom inset so content scrolls clear of the glass bar.
                // `.contentMargins` (not `.safeAreaPadding`): each tab wraps its
                // scroll content in a `NavigationStack` that re-derives its safe
                // area and drops an inset applied out here; `.contentMargins`
                // reaches every descendant scroll view.
                .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
                .overlay {
                    Color.black.opacity(0.15 * chatProgress)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                // One bar, bottom-pinned under the chat layer: content scrolls
                // beneath the floating capsule, the keyboard never lifts it,
                // and it rides the list's parallax on the Chat tab.
                phoneTabBar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        tabBarHeight = height
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard)
                    .offset(x: phoneTab == .chat ? -chatProgress * width * 0.25 : 0)
                if phoneTab == .chat, let roomId = pushedRoomId {
                    NavigationStack {
                        RoomTimelineDestination(roomId: roomId, scope: scope)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .environment(\.closeChat, closeChat)
                    .background(Color.platformWindowBackground)
                    .shadow(color: .black.opacity(0.18), radius: 14, x: -5)
                    .offset(x: (1 - chatProgress) * width)
                }
            }
            // Mid-pan the finger steers the pager; nothing underneath may take
            // the press.
            .allowsHitTesting(!isPanning)
            .gesture(chatPanRecognizer(width: width))
            // No vertical scrolling underneath once the pan is captured.
            .scrollDisabled(isPanning)
        }
    }

    /// Floating glass tab-bar capsule. Owned by the base layer so the chat can
    /// cover it.
    private var phoneTabBar: some View {
        HStack(spacing: 4) {
            phoneTabItem(.chat, title: "Chat") {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 22, weight: .medium))
            }
            phoneTabItem(.settings, title: "Settings") {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .medium))
            }
        }
        .padding(4)
        .adaptiveGlass(in: Capsule(), reduceTransparency: prefs.reduceTransparency)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        // Hug the home indicator like the system bar.
        .padding(.bottom, -6)
    }

    private func phoneTabItem(_ tab: PhoneTab, title: LocalizedStringKey,
                              @ViewBuilder icon: () -> some View) -> some View {
        let isSelected = phoneTab == tab
        return Button {
            // Plain assignment: content must swap instantly.
            phoneTab = tab
        } label: {
            VStack(spacing: 2) {
                icon()
                    .frame(height: 24)
                Text(title)
                    .font(.caption)
            }
            // Only the selected item takes the tint.
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 104)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.primary.opacity(0.12))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var listLayer: some View {
        @Bindable var appState = appState
        return NavigationStack {
            HStack(spacing: 0) {
                SpacesRail(viewModel: scope.roomList, scope: scope)
                    .frame(width: 68)
                    .background(Color.platformWindowBackground)
                Divider()
                    .padding(.top, 28)
                    .ignoresSafeArea(edges: .bottom)
                SidebarView(scope: scope,
                            viewModel: scope.roomList,
                            // Any write of the binding (even re-tapping the
                            // selected room) opens the chat; the selection
                            // persists across closes.
                            selection: Binding(
                                get: { selectedRoom },
                                set: { newValue in
                                    // A swipe keeps the finger inside one row,
                                    // so that row's Button fires on release; a
                                    // swipe must not double as a tap. The button
                                    // can fire before or after onEnded, hence
                                    // both guards.
                                    guard !isPanning,
                                          Date().timeIntervalSince(lastPanEndedAt) > 0.15
                                    else { return }
                                    selectedRoom = newValue
                                    if let newValue { openChat(newValue) }
                                }
                            ),
                            activeSheet: $appState.newChatSheet,
                            showsVerification: $showsVerification)
                    .background(Color.platformWindowBackground)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// One pan for both directions: left pulls the chat in over the list, right
    /// pushes it out. Progress follows the finger; release settles by position
    /// + fling velocity.
    ///
    /// UIKit-backed (not a SwiftUI DragGesture): `cancelsTouchesInView` cancels
    /// the button touch the swipe started on, so an avatar/chip/row under the
    /// finger can't fire on release. Direction-aware `shouldBegin` keeps
    /// swipe-to-reply and vertical scrolling out of the pager's hands.
    private func chatPanRecognizer(width: CGFloat) -> ChatPanRecognizer {
        ChatPanRecognizer { velocity in
            // The pager only exists on the Chat tab.
            guard phoneTab == .chat else { return false }
            guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
            if chatProgress >= 1 {
                // Open chat: only rightward (close); leftward is swipe-to-reply.
                return velocity.x > 0
            }
            if chatProgress <= 0 {
                // On the list: only leftward (open), and only with a chat to
                // slide in.
                guard velocity.x < 0 else { return false }
                return pushedRoomId != nil || selectedRoom != nil
            }
            return true
        } onBegan: {
            if pushedRoomId == nil {
                // Nothing parked yet (fresh session, no selection).
                guard let selectedRoom else { return }
                scope.timeline(forRoomId: selectedRoom)?.isParked = true
                chatProgress = 0
                pushedRoomId = selectedRoom
            } else if chatProgress > 0 {
                // Closing drag: drop the keyboard with the layer so the list
                // doesn't slide in under an open keyboard.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil)
            }
            panBase = chatProgress
            isPanning = true
        } onChanged: { translationX in
            guard isPanning else { return }
            let delta = -translationX / width
            // Finger-tracking must never animate.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                chatProgress = min(1, max(0, panBase + delta))
            }
        } onEnded: { translationX, velocityX in
                guard isPanning else { return }
                isPanning = false
                // Project the fling ~0.18s out.
                let predicted = panBase - (translationX + velocityX * 0.18) / width
                if predicted > 0.5 {
                    // Only a settle-OPEN release may also fire a row button
                    // under the finger; closing leaves the list free for a tap.
                    lastPanEndedAt = Date()
                    if let id = pushedRoomId {
                        let vm = scope.timeline(forRoomId: id)
                        vm?.isParked = false
                        vm?.markAsRead()
                        setFocusedChat(id)
                    }
                    withAnimation(.pagerSettle) {
                        chatProgress = 1
                    }
                } else {
                    // The swipe's touch-up can fire whatever row sat under the
                    // finger; the 150ms guard swallows exactly that.
                    lastPanEndedAt = Date()
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil)
                    if let id = pushedRoomId, let vm = scope.timeline(forRoomId: id) {
                        appState.setTimelineAnchor(vm.scrollAnchorEventId, forRoom: id)
                        vm.isParked = true
                    }
                    setFocusedChat(nil)
                    withAnimation(.pagerSettle) {
                        chatProgress = 0
                    }
                }
            }
    }

    /// The first keyboard bring-up pays a lazy-init cost (the extension
    /// handshake) that can take seconds. Focus and immediately resign a
    /// throwaway field to pay it now, so the first real focus is instant.
    private func prewarmKeyboard() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first else { return }
        let field = UITextField()
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }
    #endif

    /// iPhone gets stack navigation; iPad and macOS keep the three-pane layout.
    @ViewBuilder
    private var layoutRoot: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            phoneLayout
        } else {
            desktopLayout
        }
        #else
        desktopLayout
        #endif
    }

    private var desktopLayout: some View {
        @Bindable var appState = appState
        // iPad: live binding so the system toggle can collapse the room list;
        // macOS pins every column open.
        #if os(iOS)
        let columns = $columnVisibility
        #else
        let columns = Binding.constant(NavigationSplitViewVisibility.all)
        #endif
        // Rail lives outside the split view: NavigationSplitView enforces a
        // minimum sidebar width far wider than the traffic-light cluster.
        return HStack(spacing: 0) {
            #if os(macOS)
            SpacesRail(viewModel: scope.roomList, scope: scope)
                .frame(width: railWidth)
                .background(TrafficLightWidthReader(width: $railWidth))
                .background(SidebarMaterial().ignoresSafeArea())
            #else
            SpacesRail(viewModel: scope.roomList, scope: scope)
                .frame(width: 68)
                .background(.ultraThinMaterial)
            #endif

            NavigationSplitView(columnVisibility: columns) {
                // The sidebar column, but opaque over the system's vibrancy
                // rather than a translucent list.
                SidebarView(scope: scope,
                            viewModel: scope.roomList,
                            selection: $selectedRoom,
                            activeSheet: $appState.newChatSheet,
                            showsVerification: $showsVerification)
                    // macOS: the window material so the room list takes the same
                    // tint as the timeline detail instead of a flat color.
                    #if os(macOS)
                    .background(WindowMaterial().ignoresSafeArea())
                    #else
                    .background(Color.platformWindowBackground)
                    #endif
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
                    // iPad keeps the system toggle; macOS pins the columns.
                    #if os(macOS)
                    .toolbar(removing: .sidebarToggle)
                    #endif
            } detail: {
                Group {
                    if let roomId = selectedRoom {
                        RoomTimelineDestination(roomId: roomId, scope: scope)
                    } else {
                        ContentUnavailableView(
                            "No Room Selected",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Choose a room from the sidebar to start chatting.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var splitView: some View {
        @Bindable var appState = appState
        @Bindable var scope = scope
        return layoutRoot
        .environment(\.mediaLoader, scope.mediaLoader)
        .environment(\.presenceService, scope.presence)
        .task {
            // Monitor and profile don't depend on the room list; run them
            // alongside start(). Plain Tasks (not async let) inherit the main
            // actor, so the non-Sendable scope never crosses isolation.
            scope.startVerificationMonitor()
            let startTask = Task { await scope.roomList.start() }
            let profileTask = Task { await scope.loadOwnProfile() }
            await startTask.value
            await profileTask.value
            if scope.needsVerification {
                showsVerification = true
            }
        }
        .sheet(isPresented: $appState.isQuickSwitcherPresented) {
            QuickSwitcherView(rooms: scope.roomList.rooms) { roomId in
                openRoom(roomId)
            }
        }
        .sheet(item: $appState.newChatSheet) { sheet in
            switch sheet {
            case .directMessage:
                NewDirectMessageSheet(scope: scope) { openRoom($0) }
            case .room(let spaceId):
                NewRoomSheet(scope: scope, isSpace: false, destinationSpaceId: spaceId) { openRoom($0) }
            case .videoRoom(let spaceId):
                NewRoomSheet(scope: scope, isSpace: false, destinationSpaceId: spaceId,
                             isVideoRoom: true) { openRoom($0) }
            case .space:
                NewRoomSheet(scope: scope, isSpace: true) { openRoom($0) }
            case .join:
                JoinRoomSheet(scope: scope) { openRoom($0) }
            }
        }
        .sheet(isPresented: $showsVerification) {
            VerificationSheet(scope: scope)
        }
        .sheet(item: $scope.incomingVerification) { request in
            VerificationSheet(scope: scope, incoming: request)
        }
        .sheet(isPresented: $appState.isAddAccountPresented) {
            LoginView(isSheet: true)
                #if os(macOS)
                .frame(width: 480, height: 520)
                #endif
        }
        // Presented here for the menu-bar command and the rail's switcher item;
        // commands can't present dialogs themselves.
        .confirmationDialog(
            "Sign out of \(scope.userId)?",
            isPresented: $appState.isSignOutConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.logOut() }
            }
        } message: {
            Text("This signs \(scope.userId) out of Discourse on this device.")
        }
        .onAppear {
            #if os(iOS)
            // Deferred past first paint: the handshake is seconds of work that
            // must not race launch rendering.
            Task {
                try? await Task.sleep(for: .seconds(1))
                prewarmKeyboard()
            }
            #endif
            if selectedRoom == nil {
                let map = selectionMap()
                if let storedSpace = map[spaceMemoryKey], storedSpace != "home",
                   scope.roomList.selectedSpaceId == nil {
                    // Reopen last session's space; its room is restored by the
                    // selectedSpaceId onChange below.
                    Task { await scope.roomList.selectSpace(storedSpace) }
                } else {
                    selectedRoom = map[spaceKey]
                }
            }
            #if os(iOS)
            // On the phone the list is what's on screen at launch; only an
            // open chat suppresses its notifications/unreads.
            let focusedAtLaunch = isPhone ? pushedRoomId : selectedRoom
            #else
            let focusedAtLaunch = selectedRoom
            #endif
            NotificationManager.shared.focusedRoomId = focusedAtLaunch
            scope.roomList.activeRoomId = focusedAtLaunch
            NotificationManager.shared.openRoom = { roomId, accountUserId in
                Task {
                    // A background account's room isn't in this scope; switch
                    // first, then the fresh window's onChange (initial: true)
                    // picks up the pending navigation.
                    if let accountUserId, accountUserId != appState.activeUserId {
                        await appState.switchAccount(to: accountUserId)
                    }
                    appState.pendingRoomNavigation = roomId
                }
            }
            NotificationManager.shared.sendReply = { roomId, text, accountUserId in
                Task {
                    // Background-account replies go straight to the owning warm
                    // scope, no account switch.
                    guard let target = await appState.sessionForNotificationAction(
                        accountUserId: accountUserId) else { return }
                    await target.sendMessage(text, toRoomId: roomId)
                }
            }
            NotificationManager.shared.markRoomRead = { roomId, accountUserId in
                Task {
                    let target = await appState.sessionForNotificationAction(
                        accountUserId: accountUserId)
                    target?.roomList.markRead(roomIds: [roomId])
                }
            }
            NotificationManager.shared.onIncomingCall = { room in
                guard appState.ringingCall == nil else { return }
                appState.ringingCall = AppState.RingingCall(
                    roomId: room.id, roomName: room.name,
                    avatarURL: room.avatarURL, isDirect: room.isDirect)
            }
            NotificationManager.shared.onCallEnded = { roomId in
                if appState.ringingCall?.roomId == roomId {
                    appState.ringingCall = nil
                }
            }
        }
        .onChange(of: selectedRoom) { oldValue, newValue in
            // Save the outgoing room's scroll anchor while its visibility set is
            // still intact; teardown drains it.
            if let oldValue, let vm = scope.timeline(forRoomId: oldValue) {
                appState.setTimelineAnchor(vm.scrollAnchorEventId, forRoom: oldValue)
                #if os(macOS)
                // Park so the LRU can evict; the phone pager parks itself below.
                vm.isParked = true
                #else
                if !isPhone { vm.isParked = true }
                #endif
            }
            if let newValue {
                #if os(macOS)
                scope.timeline(forRoomId: newValue)?.isParked = false
                #else
                if !isPhone { scope.timeline(forRoomId: newValue)?.isParked = false }
                #endif
            }
            // Foreign-space opens (⌘K, notifications, search) stay transient:
            // only persist when the room belongs to the current view, or when
            // clearing (nil) unwinds it.
            let belongs: Bool = {
                guard let newValue else { return true }
                if let visible = scope.roomList.visibleRoomIds {
                    return visible.contains(newValue)
                }
                guard let room = scope.roomList.rooms.first(where: { $0.id == newValue })
                else { return false }
                return room.isDirect || !scope.roomList.allSpaceChildIds.contains(newValue)
            }()
            if belongs {
                rememberSelection(newValue, forKey: spaceKey)
            }
            #if os(iOS)
            if isPhone {
                // Keep the parked chat layer in sync so a swipe-in reveals the
                // selected room, pre-warmed.
                if chatProgress == 0, pushedRoomId != newValue {
                    if let newValue {
                        scope.timeline(forRoomId: newValue)?.isParked = true
                    }
                    pushedRoomId = newValue
                }
                // Focus follows the open chat, not the list selection.
                return
            }
            #endif
            NotificationManager.shared.focusedRoomId = newValue
            scope.roomList.activeRoomId = newValue
        }
        // Each space keeps its own remembered room.
        .onChange(of: scope.roomList.selectedSpaceId) { _, newSpaceId in
            selectedRoom = selectionMap()["\(scope.userId)|\(newSpaceId ?? "home")"]
            rememberSelection(newSpaceId ?? "home", forKey: spaceMemoryKey)
        }
        // initial: true — an account switch remounts this window, and a
        // navigation set just before the remount must still land.
        .onChange(of: appState.pendingRoomNavigation, initial: true) { _, roomId in
            guard let roomId else { return }
            openRoom(roomId)
            appState.pendingRoomNavigation = nil
        }
        .onChange(of: appState.pendingEventNavigation, initial: true) { _, navigation in
            guard let navigation else { return }
            openRoom(navigation.roomId)
            // Not cleared here: the TimelineView consumes it once it has
            // scrolled to the event.
        }
    }

    /// Selects a room and, on the phone, slides its chat screen in.
    private func openRoom(_ roomId: String) {
        selectedRoom = roomId
        #if os(iOS)
        if isPhone { openChat(roomId) }
        #endif
    }
}

/// Resolves a room id to its timeline inside a real view body. Lookups made
/// directly in a `navigationDestination` closure aren't observation-tracked,
/// so a cold-launch-restored room stayed on the spinner forever; here the body
/// re-runs when the room list updates.
private struct RoomTimelineDestination: View {
    let roomId: String
    let scope: SessionScope

    var body: some View {
        if let timeline = scope.timeline(forRoomId: roomId) {
            TimelineView(viewModel: timeline)
                .id(roomId)
        } else {
            ProgressView("Opening room…")
        }
    }
}

#if os(iOS)
/// UIKit-backed pager pan. A SwiftUI DragGesture lets the button under the
/// finger fire on release; a UIPanGestureRecognizer with `cancelsTouchesInView`
/// cancels that touch the moment the pan recognizes, so a swipe over an
/// avatar/chip/row can't also act as a tap.
struct ChatPanRecognizer: UIGestureRecognizerRepresentable {
    /// Direction gate, fed the initial velocity; which drags belong to the
    /// pager depends on which layer is showing.
    var shouldBegin: (CGPoint) -> Bool
    var onBegan: () -> Void
    /// Horizontal translation since the pan began.
    var onChanged: (CGFloat) -> Void
    /// Final translation and velocity, for the fling settle.
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(shouldBegin: shouldBegin)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            // Zero the ~10pt of pre-recognition movement so the layer doesn't
            // jump under the finger.
            recognizer.setTranslation(.zero, in: view)
            Self.cancelCompetingRecognizers(around: view, except: recognizer)
            onBegan()
        case .changed:
            onChanged(recognizer.translation(in: view).x)
        case .ended, .cancelled, .failed:
            onEnded(recognizer.translation(in: view).x,
                    recognizer.velocity(in: view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let shouldBegin: (CGPoint) -> Bool
        init(shouldBegin: @escaping (CGPoint) -> Bool) { self.shouldBegin = shouldBegin }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else {
                return false
            }
            return shouldBegin(pan.velocity(in: view))
        }

        // Fully simultaneous: exclusivity made capture unreliable (SwiftUI's
        // unified recognizer could claim the touch first). Instead the pan
        // cancels competitors itself on begin (see cancelCompetingRecognizers).
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// Flipping `isEnabled` off and on forcibly cancels a recognizer's
    /// in-flight recognition; this is what kills the pressed avatar/chip under a
    /// swipe, since `cancelsTouchesInView` and exclusivity don't. Scroll-view
    /// pans are spared so scroll position doesn't hiccup; walking up from the
    /// gesture's view covers SwiftUI's hosting-view recognizers.
    fileprivate static func cancelCompetingRecognizers(around view: UIView,
                                                       except pan: UIGestureRecognizer) {
        var current: UIView? = view
        while let host = current {
            for other in host.gestureRecognizers ?? []
            where other !== pan && !(other is UIPanGestureRecognizer) {
                if other.state == .possible || other.state == .began || other.state == .changed {
                    other.isEnabled = false
                    other.isEnabled = true
                }
            }
            current = host.superview
        }
    }
}
#endif
