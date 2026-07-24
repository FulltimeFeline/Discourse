import SwiftUI

/// Set on iPhone, where chat is a slide-over layer: "back" slides it out.
private struct CloseChatKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var closeChat: (@MainActor () -> Void)? {
        get { self[CloseChatKey.self] }
        set { self[CloseChatKey.self] = newValue }
    }
}

#if os(iOS)
/// Rectangle minus its left band — trims the title button's hit area where the
/// widened back chevron overhangs it. (Left, not leading: Shape has no layout
/// direction; fine until RTL.)
private struct LeadingInsetRect: Shape {
    let inset: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX + inset, y: rect.minY,
                    width: max(0, rect.width - inset), height: rect.height))
    }
}
#endif

struct TimelineView: View {
    let viewModel: TimelineViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.closeChat) private var closeChat
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pronounsStore) private var pronounsStore
    /// Persisted so the details column survives room switches and relaunches.
    @AppStorage("showsDetailsColumn") private var showsDetails = false
    @State private var threadTarget: ThreadTarget?
    @State private var profileTarget: ProfileTarget?
    @State private var showsSearch = false
    /// Scroll target from reply clicks and search hits; consumed inside the
    /// ScrollViewReader, where the proxy lives.
    @State private var jumpEventId: String?
    /// Like jumpEventId but lands with no animation.
    @State private var restoreEventId: String?
    /// One-shot: on open, land on the first unread unless a saved position wins.
    @State private var openUnreadScrollId: String?
    /// Transient status capsule; auto-clears, cancel-and-replace on repeat.
    @State private var transientNotice: String?
    @State private var transientNoticeTask: Task<Void, Never>?
    /// Home-indicator inset, measured here (the composer's context can't see it)
    /// so the expression panel can reach the screen edge.
    @State private var bottomInset: CGFloat = 0
    /// Detail-area width, for sizing the toolbar title/subtitle. Starts at phone
    /// width so the iOS title item can't overflow before first measurement.
    @State private var detailWidth: CGFloat = 390
    #if os(iOS)
    /// iPhone has no multi-scene support, so no detached call window.
    @State private var showsPhoneCall = false
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The 230pt details drawer only fits regular-width layouts.
    private var detailsColumnFits: Bool { horizontalSizeClass == .regular }



    #else
    private var detailsColumnFits: Bool { true }
    #endif

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if isVideoRoom && !appState.activeCallRoomIds.contains(viewModel.roomId) {
                    // A video room is a standing call; the join affordance is
                    // always present.
                    videoRoomBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if viewModel.hasActiveCall && !appState.activeCallRoomIds.contains(viewModel.roomId) {
                    callBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                timelineBody
            }
            .animation(.easeOut(duration: 0.25), value: viewModel.hasActiveCall)
            .animation(.easeOut(duration: 0.25),
                       value: appState.activeCallRoomIds.contains(viewModel.roomId))
            .frame(minWidth: 330)
            if showsDetails && detailsColumnFits {
                Rectangle()
                    .fill(Color.columnDivider)
                    .frame(width: 0.5)
                    .ignoresSafeArea()
                RoomDetailsColumn(viewModel: viewModel) { eventId in
                    jump(to: eventId)
                }
                .frame(width: 230)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            detailWidth = width
        }
        #if os(macOS)
        .navigationTitle(viewModel.roomName)
        .navigationSubtitle(subtitle)
        #else
        // No navigationTitle: the fused leading item is the title. Custom title
        // items get clamped/centered/overflowed by the toolbar — don't add one.
        // Bar and backdrop must be forced visible (no-title screens inherit the
        // root's hidden bar).
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        #endif
        .toolbar {
            #if os(iOS)
            // ONE fused element: avatar + name + lock. Separate toolbar items
            // can't sit tight (the toolbar owns inter-item spacing) and the
            // native title strips attachments. Width capped from the measured
            // bar budget so the toolbar can't overflow into ⋯.
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 2) {
                    // Slide-over back button; no push, so no system chevron.
                    if let closeChat {
                        Button(action: closeChat) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                                .frame(width: 30, height: 36)
                                // 44pt hit target overhanging the fused title
                                // (whose hit shape is trimmed to match, below)
                                // so a missed back-tap can't open room details.
                                .frame(width: 44, height: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.trailing, -14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    }
                    Button {
                        showsDetails = true
                    } label: {
                        HStack(spacing: 6) {
                            RoomAvatarView(name: viewModel.roomName,
                                           isDirect: viewModel.isDirect,
                                           size: 30,
                                           avatarURL: viewModel.avatarURL)
                                .presenceIndicator(userId: viewModel.dmPeerId, size: 10)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 5) {
                                    Text(viewModel.roomName)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if viewModel.isEncrypted {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                            .accessibilityLabel("End-to-end encrypted")
                                    }
                                }
                                if let peer = viewModel.dmPeerId,
                                   let status = pronounsStore?.status(for: peer), !status.isEmpty {
                                    Text(status)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        // Conservative budget: over-claiming collapses the
                        // trailing buttons into a ⋯ overflow menu.
                        .frame(width: max(80, min(detailWidth - 260, 240)), alignment: .leading)
                        // Cede leading 12pt to the back chevron's hit frame when present.
                        .contentShape(closeChat == nil
                                      ? AnyShape(Rectangle())
                                      : AnyShape(LeadingInsetRect(inset: 12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows room details")
                }
            }
            .sharedBackgroundVisibility(.hidden)
            #endif
            #if os(macOS)
            // iOS shows the lock inline with the title instead.
            if viewModel.isEncrypted {
                ToolbarItem(placement: .navigation) {
                    Image(systemName: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("This room is end-to-end encrypted")
                        .accessibilityLabel("End-to-end encrypted")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Call", systemImage: "phone") {
                    startCall()
                }
                .help("Start or join a call")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Search", systemImage: "magnifyingglass") {
                    showsSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search this room (⌘F)")
            }
            // iPhone opens details by tapping the title; elsewhere, explicit toggle.
            if detailsColumnFits {
                ToolbarItem(placement: .primaryAction) {
                    Button("Details", systemImage: "info.circle") {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showsDetails.toggle()
                        }
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Show Details (⌘⌥I)")
                }
            }
        }
        .sheet(item: $profileTarget) { target in
            ProfileSheet(target: target, ownUserId: viewModel.ownUserId) { userId in
                if let roomId = await viewModel.startDm(userId: userId) {
                    appState.pendingRoomNavigation = roomId
                    return true
                }
                return false
            }
        }
        #if os(iOS)
        // Compact width: details become a native sheet; wide keeps the column.
        .sheet(isPresented: Binding(
            get: { showsDetails && !detailsColumnFits },
            set: { if !$0 { showsDetails = false } }
        )) {
            RoomDetailsSheet(viewModel: viewModel) { eventId in
                showsDetails = false
                jump(to: eventId)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
        #endif
        .sheet(isPresented: $showsSearch) {
            RoomSearchSheet(viewModel: viewModel) { eventId in
                jump(to: eventId)
            }
        }
        // A ring accepted from the banner joins here once the room is on screen.
        .onChange(of: appState.pendingCallJoin, initial: true) { _, roomId in
            guard roomId == viewModel.roomId else { return }
            appState.pendingCallJoin = nil
            startCall()
        }
        // Cross-room event navigation (global search): MainWindow opened the
        // room; consume the event half once the timeline can show it.
        .onChange(of: appState.pendingEventNavigation, initial: true) { _, navigation in
            guard let navigation, navigation.roomId == viewModel.roomId else { return }
            appState.pendingEventNavigation = nil
            // Don't fire a stale request when the room is finally visited later.
            guard Date().timeIntervalSince(navigation.requestedAt) < 30 else { return }
            jump(to: navigation.eventId)
        }
        .overlay(alignment: .top) {
            if let transientNotice {
                Text(transientNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsPhoneCall) {
            PhoneCallScreen(roomId: viewModel.roomId)
        }
        #endif
    }

    /// Detached window on macOS/iPad; full-screen cover on iPhone, where
    /// openWindow silently does nothing.
    private func startCall() {
        #if os(iOS)
        guard UIApplication.shared.supportsMultipleScenes else {
            showsPhoneCall = true
            return
        }
        #endif
        openWindow(id: "call", value: viewModel.roomId)
    }

    /// Back-fills until the event is loaded; a miss (redacted, or past the
    /// pagination bound) shows a notice instead of failing silently.
    private func jump(to eventId: String) {
        Task {
            if await viewModel.ensureLoaded(eventId: eventId) {
                jumpEventId = eventId
            } else {
                showNotice("Couldn't find that message")
            }
        }
    }

    /// Shows the transient capsule; repeat calls cancel-and-replace the auto-clear.
    private func showNotice(_ text: String) {
        transientNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { transientNotice = text }
        transientNoticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { transientNotice = nil }
        }
    }

    /// Toolbar subtitle, truncated to fit: the title bar otherwise lets long
    /// subtitles spill across the trailing toolbar items before eliding. Width
    /// bucketed and memoized so resize re-measures at most once per 8pt step.
    private var subtitle: String {
        // DMs: show the peer's Commet status under their name (they rarely have a
        // topic). Rooms: the topic.
        if viewModel.isDirect, let peer = viewModel.dmPeerId,
           let status = pronounsStore?.status(for: peer), !status.isEmpty {
            return Self.truncatedSubtitle(status, toFit: subtitleWidth)
        }
        guard let topic = viewModel.topic else { return "" }
        let available = subtitleWidth
        let key = "\(Int(available))|\(topic)"
        if let hit = SubtitleCache.entries[key] { return hit }
        let value = Self.truncatedSubtitle(topic, toFit: available)
        if SubtitleCache.entries.count > 64 {
            SubtitleCache.entries.removeAll(keepingCapacity: true)
        }
        SubtitleCache.entries[key] = value
        return value
    }

    /// Title-bar width available to the subtitle: total minus the leading inset,
    /// lock badge, and the call/search/details cluster. Bucketed to 8pt so a
    /// resize re-measures at most once per step.
    private var subtitleWidth: CGFloat {
        let reserved: CGFloat = viewModel.isEncrypted ? 290 : 240
        return max(60, ((detailWidth - reserved) / 8).rounded(.down) * 8)
    }

    private static func truncatedSubtitle(_ topic: String, toFit available: CGFloat) -> String {
        let flattened = topic.replacingOccurrences(of: "\n", with: " ")
        let font = PlatformFont.systemFont(ofSize: 11)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        guard width(flattened) > available else { return flattened }
        // Longest prefix that fits with an ellipsis.
        var low = 0, high = flattened.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(String(flattened.prefix(mid)) + "…") <= available {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return flattened.prefix(low).trimmingCharacters(in: .whitespaces) + "…"
    }

    @MainActor
    private enum SubtitleCache {
        static var entries: [String: String] = [:]
    }

    private var callBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Call in progress")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Join") {
                startCall()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.green.opacity(0.12))
    }

    /// Live lookup, not the flag snapshotted at timeline creation: space
    /// listings (the only source of creation types) may load later.
    private var isVideoRoom: Bool {
        if case .active(let scope) = appState.phase,
           scope.roomList.videoRoomIds.contains(viewModel.roomId) {
            return true
        }
        return viewModel.isVideoRoom
    }

    private var videoRoomBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(viewModel.hasActiveCall ? "Video room — call in progress" : "Video room")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Join") {
                startCall()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.12))
    }

    private var timelineBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    paginationHeader
                    ForEach(viewModel.entries) { entry in
                        TimelineEntryRow(entry: entry, viewModel: viewModel,
                                         openThread: { rootEventId in
                                             threadTarget = ThreadTarget(id: rootEventId, viewModel: viewModel.threadViewModel(rootEventId: rootEventId))
                                         },
                                         openProfile: { target in
                                             profileTarget = target
                                         },
                                         jumpToEvent: { eventId in
                                             jump(to: eventId)
                                         })
                        .equatable()
                        .id(entry.id)
                        .onAppear {
                            viewModel.visibleEntryIds.insert(entry.id)
                            if entry.id == viewModel.firstUnreadMarkerId {
                                viewModel.setUnreadMarkerOnScreen(true)
                            }
                        }
                        .onDisappear {
                            viewModel.visibleEntryIds.remove(entry.id)
                            if entry.id == viewModel.firstUnreadMarkerId {
                                viewModel.setUnreadMarkerOnScreen(false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            // Bottom-proximity from real scroll geometry, not a sentinel: a
            // LazyVStack instantiates a sentinel ~a screen early, flipping
            // isAtBottom (and firing read receipts) while the newest message is
            // still below the fold. visibleRect already accounts for the inset.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.visibleRect.maxY <= 40
            } action: { _, atBottom in
                guard viewModel.isAtBottom != atBottom else { return }
                viewModel.isAtBottom = atBottom
                if atBottom { viewModel.markAsRead() }
            }
            #if os(iOS)
            // Drag/scroll dismisses the keyboard. A tap gesture here can't be
            // added back: on ScrollView+LazyVStack it competes with the rows'
            // contextMenu long-press, which then only works after a scroll.
            .scrollDismissesKeyboard(.interactively)
            #endif
            // Jump-to-present. Animation scoped inside the overlay: a bare
            // .animation on the scroll view would animate programmatic scrolls
            // too (room-switch restore visibly "travelling"). Separate child
            // view so isAtBottom flips invalidate only the overlay.
            .overlay(alignment: .bottomTrailing) {
                JumpToPresentOverlay(viewModel: viewModel) {
                    if let last = viewModel.entries.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            // "Jump to unread" pill: appears when the read marker is loaded but
            // scrolled out of view.
            .overlay(alignment: .top) {
                JumpToUnreadOverlay(viewModel: viewModel) {
                    if let id = viewModel.firstUnreadMarkerId {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
            .onChange(of: viewModel.entries.last?.id) { _, newLast in
                guard let newLast else { return }
                // Follow the tail while at the bottom, and always for our own
                // message — including when the local echo (no event ID) is
                // replaced by the confirmed event, which would otherwise stop
                // the follow and leave us just above the bottom.
                let sentOwn: Bool = {
                    if case .message(let m) = viewModel.entries.last {
                        return m.isOwn
                    }
                    return false
                }()
                guard viewModel.isAtBottom || sentOwn else { return }
                proxy.scrollTo(newLast, anchor: .bottom)
                // Again after layout: the new row's real height (wrapping,
                // media) isn't known on the first pass, leaving it half shown.
                DispatchQueue.main.async {
                    proxy.scrollTo(newLast, anchor: .bottom)
                }
            }
            // The typing tag grows the composer (a bottom safe-area inset); when
            // at the bottom, re-anchor so the newest message isn't left hidden
            // behind it.
            .onChange(of: viewModel.typingUsers.isEmpty) { _, _ in
                guard viewModel.isAtBottom, let last = viewModel.entries.last?.id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            // Land on the first unread on open, no travel animation.
            .onChange(of: openUnreadScrollId) { _, id in
                guard let id else { return }
                openUnreadScrollId = nil
                proxy.scrollTo(id, anchor: .top)
            }
            // Unpark restore (iOS keeps the view mounted, so `.task` doesn't
            // re-run): land back on the pre-switch position after the reset.
            .onChange(of: viewModel.unparkScrollTarget) { _, eventId in
                guard let eventId else { return }
                viewModel.clearUnparkScrollTarget()
                if let target = viewModel.entries.first(where: {
                    if case .message(let m) = $0 { return m.eventId == eventId }
                    return false
                }) {
                    proxy.scrollTo(target.id, anchor: .bottom)
                }
            }
            // Scroll-memory restore: land there instantly.
            .onChange(of: restoreEventId) { _, eventId in
                guard let eventId else { return }
                restoreEventId = nil
                if let target = viewModel.entries.first(where: {
                    if case .message(let m) = $0 { return m.eventId == eventId }
                    return false
                }) {
                    proxy.scrollTo(target.id, anchor: .bottom)
                }
            }
            .onChange(of: jumpEventId) { _, eventId in
                guard let eventId else { return }
                jumpEventId = nil
                if let target = viewModel.entries.first(where: {
                    if case .message(let m) = $0 { return m.eventId == eventId }
                    return false
                }) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target.id, anchor: .center)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(viewModel: viewModel, bottomSafeInset: bottomInset)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.bottom
        } action: { inset in
            // The keyboard also lands here (~300pt); capture only
            // home-indicator-scale values or the panel height math collapses.
            if inset < 100 { bottomInset = inset }
        }
        #if os(iOS)
        // The composer manages its own keyboard lift (see ComposerView) so the
        // system safe-area animation doesn't fight ours.
        .ignoresSafeArea(.keyboard)
        #endif
        .dropDestination(for: ComposerDropItem.self) { items, _ in
            guard !items.isEmpty else { return false }
            for item in items {
                switch item {
                case .file(let data, let filename):
                    viewModel.stageAttachment(data: data, filename: filename)
                case .image(let data):
                    viewModel.stageAttachment(data: data, filename: "image")
                }
            }
            return true
        }
        .sheet(item: $threadTarget) { target in
            ThreadView(viewModel: target.viewModel)
        }
        .task {
            await viewModel.start()
            // Land where the user left off, if that event is loaded; else bottom.
            if let saved = appState.timelineAnchor(forRoom: viewModel.roomId),
               viewModel.entries.contains(where: { entry in
                   if case .message(let m) = entry { return m.eventId == saved }
                   return false
               }) {
                restoreEventId = saved
            } else if let markerId = viewModel.firstUnreadMarkerId {
                // No saved position but unreads exist: land on the first.
                openUnreadScrollId = markerId
            }
            // Member profiles back the read-receipt avatars on rows.
            await viewModel.loadMembers()
        }
        .onDisappear {
            // Backup save (e.g. window closing). Skip if teardown drained the
            // visibility set — MainWindow's room-switch path already saved.
            guard viewModel.isAtBottom || !viewModel.visibleEntryIds.isEmpty else { return }
            appState.setTimelineAnchor(viewModel.scrollAnchorEventId, forRoom: viewModel.roomId)
        }
        .overlay {
            if let error = viewModel.error {
                ContentUnavailableView("Timeline Unavailable",
                                       systemImage: "exclamationmark.bubble",
                                       description: Text(error))
            } else if viewModel.entries.isEmpty {
                // Only until the initial page lands (an empty room still gets a
                // timeline-start entry), so this never sticks.
                ProgressView("Loading messages…")
                    .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private var paginationHeader: some View {
        if !viewModel.reachedStart {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 12)
            // Visibility-driven, not .task(id: entries.count): the count
            // changes on every diff, which cancelled and re-fired pagination
            // constantly. Polls while the header is visible (paginateBackwards
            // has its own reentrancy guard); dies on disappear or reachedStart.
            .task {
                while !Task.isCancelled && !viewModel.reachedStart {
                    await viewModel.paginateBackwards()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

}

#if os(iOS)
/// Full-screen call UI for iPhone (no multi-scene, so no detached window).
/// Hosts the shared CallView with the same session bookkeeping as CallWindowView.
private struct PhoneCallScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let roomId: String

    var body: some View {
        Group {
            if case .active(let scope) = appState.phase,
               let call = scope.call(forRoomId: roomId) {
                CallView(viewModel: call)
            } else {
                // Session gone mid-call (logout): still needs a way out.
                VStack(spacing: 0) {
                    HStack {
                        Label("Call", systemImage: "phone.fill")
                            .font(.headline)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    Divider()
                    ContentUnavailableView("Call Unavailable", systemImage: "phone.down")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.platformWindowBackground)
            }
        }
        .onAppear { appState.activeCallRoomIds.insert(roomId) }
        .onDisappear {
            appState.activeCallRoomIds.remove(roomId)
            if case .active(let scope) = appState.phase {
                scope.endCall(forRoomId: roomId)
            }
        }
        // MainWindow's incoming-call banner sits under this cover (audible but
        // invisible); mirror it here so a ring during a call is answerable.
        .overlay(alignment: .top) {
            ZStack {
                if let call = appState.ringingCall {
                    IncomingCallView(call: call) {
                        appState.ringingCall = nil
                        // Ring for the room we're already in: nothing to do.
                        guard call.roomId != roomId else { return }
                        // End the current call first: openChat drops foreign-room
                        // navigation while a call is live, so live-call state must
                        // clear before the navigation lands. (onDisappear repeats
                        // this; both steps are idempotent.)
                        appState.activeCallRoomIds.remove(roomId)
                        if case .active(let scope) = appState.phase {
                            scope.endCall(forRoomId: roomId)
                        }
                        dismiss()
                        appState.pendingCallJoin = call.roomId
                        appState.pendingRoomNavigation = call.roomId
                    } decline: {
                        appState.ringingCall = nil
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: appState.ringingCall)
        }
    }
}
#endif

/// The "Jump to unread" pill. Separate view so only it re-renders as the read
/// marker's on-screen state changes while scrolling.
private struct JumpToUnreadOverlay: View {
    let viewModel: TimelineViewModel
    @Environment(Preferences.self) private var prefs
    let action: () -> Void

    var body: some View {
        let visible = viewModel.unreadMarkerVisible
            && viewModel.firstUnreadMarkerId != nil
            && !viewModel.isAtBottom
            && !viewModel.unreadMarkerOnScreen
        return ZStack {
            if visible {
                Button(action: action) {
                    Label("Jump to unread", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .adaptiveGlass(in: Capsule(), reduceTransparency: prefs.reduceTransparency)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(prefs.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: visible)
    }
}

/// The jump-to-latest button. Separate view so it alone observes `isAtBottom`.
private struct JumpToPresentOverlay: View {
    let viewModel: TimelineViewModel
    @Environment(Preferences.self) private var prefs
    let jumpToBottom: () -> Void

    var body: some View {
        ZStack {
            if !viewModel.isAtBottom {
                Button(action: jumpToBottom) {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .adaptiveGlass(in: Circle(), reduceTransparency: prefs.reduceTransparency)
                        #if os(iOS)
                        // 44pt touch target, 36pt visual unchanged.
                        .frame(width: 44, height: 44)
                        #endif
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .hoverEffect(.highlight)
                .padding(.trailing, 10)
                .padding(.bottom, 6)
                #else
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                #endif
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .help("Jump to latest")
                .accessibilityLabel("Jump to latest")
            }
        }
        .animation(prefs.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: viewModel.isAtBottom)
    }
}

struct TimelineEntryRow: View {
    let entry: TimelineEntry
    let viewModel: TimelineViewModel
    var openThread: (String) -> Void = { _ in }
    var openProfile: (ProfileTarget) -> Void = { _ in }
    var jumpToEvent: (String) -> Void = { _ in }

    var body: some View {
        switch entry {
        case .message(let message):
            MessageRow(message: message, viewModel: viewModel,
                       openThread: openThread, openProfile: openProfile,
                       jumpToEvent: jumpToEvent)
        case .system(_, let text):
            SystemRow(text: text)
        case .dayDivider(_, let date):
            DayDividerView(date: date)
        case .readMarker:
            // The inline "NEW" divider auto-clears once seen (and stays gone on
            // return), tracked by the same dismissal state as the jump pill.
            if viewModel.unreadMarkerVisible {
                ReadMarkerView()
            }
        case .timelineStart:
            TimelineStartView()
        case .hidden:
            EmptyView()
        }
    }
}

/// Data-only equality (the closures always perform the same action), so
/// `.equatable()` skips re-evaluating rows whose entry didn't change when the
/// entries array mutates. Observation-tracked reads inside still invalidate
/// affected rows directly.
/// (`@preconcurrency`: SwiftUI always compares views on the main actor, so the
/// isolated `==` is safe without requiring TimelineEntry to be Sendable.)
extension TimelineEntryRow: @preconcurrency Equatable {
    static func == (l: TimelineEntryRow, r: TimelineEntryRow) -> Bool {
        l.entry == r.entry
    }
}

/// Tabbed right column: room Info, Members, and a Media gallery.
struct RoomDetailsColumn: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info, members, media
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .info: "Info"
            case .members: "Members"
            case .media: "Media"
            }
        }
    }

    let viewModel: TimelineViewModel
    var jumpToEvent: (String) -> Void = { _ in }
    /// Remembered across rooms and launches.
    @AppStorage("detailsColumnTab") private var tab: Tab = .members
    @Namespace private var pillNamespace
    @State private var hoveredTab: Tab?

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    private var isWindowInactive: Bool { controlActiveState == .inactive }
    #else
    private var isWindowInactive: Bool { false }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Hand-rolled tabs: the system segmented control draws each segment
            // as a separate island and shifts color with the vibrancy behind
            // it, so it never matches across tabs.
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            tab = item
                        }
                    } label: {
                        Text(item.title)
                            .font(.callout.weight(tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item
                                             ? (isWindowInactive ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                                             : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background {
                                if tab == item {
                                    Capsule().fill(selectedFill)
                                        .matchedGeometryEffect(id: "tab", in: pillNamespace)
                                } else if hoveredTab == item {
                                    Capsule().fill(.quaternary.opacity(0.5))
                                }
                            }
                            .contentShape(Capsule())
                            #if os(iOS)
                            // 44pt touch target, visible capsule unchanged.
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .padding(.vertical, -8)
                            #endif
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredTab = hovering ? item : (hoveredTab == item ? nil : hoveredTab)
                    }
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            switch tab {
            case .info: RoomInfoTab(viewModel: viewModel)
            case .members: MemberListView(viewModel: viewModel)
            case .media: MediaGalleryView(viewModel: viewModel.mediaViewModel(),
                                          jumpToEvent: jumpToEvent)
            }
        }
    }

    /// Accent while active, gray when the window isn't.
    private var selectedFill: AnyShapeStyle {
        isWindowInactive
            ? AnyShapeStyle(Color.gray.opacity(0.35))
            : AnyShapeStyle(.tint.opacity(0.85))
    }
}

/// The Info tab: avatar, name, topic, and room facts.
private struct RoomInfoTab: View {
    let viewModel: TimelineViewModel
    @Environment(AppState.self) private var appState
    @State private var settingsTarget: SettingsTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                RoomAvatarView(name: viewModel.roomName, isDirect: false, size: 72,
                               avatarURL: viewModel.avatarURL)
                    .padding(.top, 14)
                Text(viewModel.roomName)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let topic = viewModel.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.isEncrypted {
                        Label("End-to-end encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    }
                    Label("\(viewModel.memberCount) members", systemImage: "person.2")
                    if viewModel.hasActiveCall {
                        Label("Call in progress", systemImage: "phone.fill")
                            .foregroundStyle(.green)
                    }
                    Button {
                        Platform.copyToClipboard(viewModel.roomId)
                    } label: {
                        Label("Copy Room ID", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(viewModel.roomId)
                    Button {
                        settingsTarget = SettingsTarget(roomId: viewModel.roomId,
                                                        isSpace: false)
                    } label: {
                        Label("Room Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Room Settings")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        .sheet(item: $settingsTarget) { target in
            if case .active(let scope) = appState.phase {
                RoomSettingsSheet(scope: scope, target: target)
            }
        }
    }
}

/// The Media tab: image grid on top, other attachments as rows. Backed by an
/// attachment-filtered timeline that back-fills on demand.
private struct MediaGalleryView: View {
    let viewModel: TimelineViewModel
    var jumpToEvent: (String) -> Void = { _ in }

    private var mediaMessages: [MessageItem] {
        viewModel.entries.reversed().compactMap {
            if case .message(let message) = $0 { return message }
            return nil
        }
    }

    var body: some View {
        let messages = mediaMessages
        let images = messages.compactMap { message -> (MessageItem, ImageItem)? in
            if case .image(let image) = message.kind { return (message, image) }
            return nil
        }
        let others = messages.filter {
            if case .image = $0.kind { return false }
            return true
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 4)], spacing: 4) {
                        ForEach(images, id: \.0.id) { message, image in
                            Button {
                                if let eventId = message.eventId { jumpToEvent(eventId) }
                            } label: {
                                MediaThumbCell(image: image, loader: viewModel.mediaLoader)
                            }
                            .buttonStyle(.plain)
                            #if os(iOS)
                            .hoverEffect(.highlight)
                            #endif
                            // Thumbnail-only button; give it a spoken name.
                            .accessibilityLabel(Text(
                                image.caption
                                    ?? (image.filename.isEmpty ? String(localized: "Image") : image.filename)))
                        }
                    }
                }
                ForEach(others) { message in
                    Button {
                        if let eventId = message.eventId { jumpToEvent(eventId) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: message))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label(for: message))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(message.timestamp, format: .dateTime.day().month().year())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !viewModel.reachedStart {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    // Visibility-driven, like the main timeline's header.
                    // Attachments are sparse; keep back-filling while visible.
                    // Dies on disappear, reachedStart, or once enough is loaded.
                    .task {
                        while !Task.isCancelled && !viewModel.reachedStart
                            && viewModel.entries.count < 80 {
                            await viewModel.paginateBackwards()
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                }
            }
            .padding(8)
        }
        .overlay {
            if messages.isEmpty && viewModel.reachedStart {
                ContentUnavailableView("No Media", systemImage: "photo.on.rectangle",
                                       description: Text("Nothing has been shared here yet."))
            }
        }
        .task { await viewModel.start() }
    }

    private func iconName(for message: MessageItem) -> String {
        switch message.kind {
        case .audio(let audio): audio.isVoiceMessage ? "waveform" : "music.note"
        case .media(_, let systemImage): systemImage
        default: "doc"
        }
    }

    private func label(for message: MessageItem) -> String {
        switch message.kind {
        case .audio(let audio): audio.isVoiceMessage ? String(localized: "Voice message") : audio.filename
        case .media(let label, _): label
        default: String(localized: "Attachment")
        }
    }
}

/// Square thumbnail for the media grid.
private struct MediaThumbCell: View {
    let image: ImageItem
    let loader: MediaLoader
    @Environment(\.displayScale) private var displayScale
    @State private var thumb: PlatformImage?

    /// Clamped so fractional macOS backing scales don't fragment cache keys.
    private var pixelSize: CGFloat {
        62 * min(max(displayScale, 1), 3)
    }

    /// Seeded from cache so recycled grid cells (@State resets on re-instantiate)
    /// don't flash the placeholder while re-fetching.
    private var displayThumb: PlatformImage? {
        thumb ?? loader.cachedThumbnail(for: image.source, pixelSize: pixelSize)
    }

    var body: some View {
        ZStack {
            if let displayThumb {
                Image(platformImage: displayThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary.opacity(0.5))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task {
            thumb = await loader.thumbnail(for: image.source, pixelSize: pixelSize)
        }
    }
}

/// Member column as a native inspector: search, role-grouped, DM from the
/// context menu.
/// A named role: its emoji (unicode or custom emote) and its name in the tag color.
struct RoleTagLabel: View {
    let tag: PowerLevelTag
    var loader: MediaLoader?

    var body: some View {
        HStack(spacing: 4) {
            if let key = tag.iconKey, !key.isEmpty {
                if tag.iconIsMxc {
                    EmoteImageView(url: key, size: 15, loader: loader)
                } else {
                    Text(key)
                }
            }
            Text(tag.name)
                .foregroundStyle(Color(hex: tag.color) ?? .secondary)
        }
    }
}

struct MemberListView: View {
    let viewModel: TimelineViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.presenceService) private var presence
    @State private var query = ""
    @State private var profileTarget: ProfileTarget?
    @State private var showsInvite = false
    @State private var moderation: ModerationAction?
    @State private var moderationError: String?

    struct ModerationAction: Identifiable {
        var id: String { "\(isBan)-\(member.id)" }
        let member: TimelineViewModel.MemberItem
        let isBan: Bool
    }

    /// Static helpers so the iPhone details sheet shares the role order and
    /// predicate without duplicating them.
    static func filteredMembers(_ members: [TimelineViewModel.MemberItem],
                                matching query: String) -> [TimelineViewModel.MemberItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    /// Members grouped by their actual power level, highest first — each level
    /// is a named role via `in.cinny.room.power_level_tags`.
    static func memberGroups(of members: [TimelineViewModel.MemberItem])
        -> [(level: Int, members: [TimelineViewModel.MemberItem])] {
        Dictionary(grouping: members, by: \.powerLevel)
            .sorted { $0.key > $1.key }
            .map { (level: $0.key, members: $0.value) }
    }

    var body: some View {
        // Computed once per evaluation: the old computed-property chain re-ran
        // the member filter and presence scan several times per render.
        let filtered = Self.filteredMembers(viewModel.members, matching: query)
        // Members whose presence is confirmed offline; grouped into their own
        // bottom section so active members stay up top.
        let offlineMembers = filtered.filter { presence?.state(of: $0.id) == .offline }
        let offlineIds = Set(offlineMembers.map(\.id))
        // Role groups of everyone not confirmed offline (online, idle, or not
        // yet fetched — the latter stay up top until proven offline).
        let groups = Self.memberGroups(of: filtered.filter { !offlineIds.contains($0.id) })
        return list(filtered: filtered, groups: groups, offlineMembers: offlineMembers)
    }

    private func list(filtered: [TimelineViewModel.MemberItem],
                      groups: [(level: Int, members: [TimelineViewModel.MemberItem])],
                      offlineMembers: [TimelineViewModel.MemberItem]) -> some View {
        List {
            // Headers as plain rows: List section headers draw a divider that
            // can't be turned off.
            ForEach(groups, id: \.level) { group in
                HStack(spacing: 4) {
                    RoleTagLabel(tag: viewModel.roleTag(forLevel: group.level),
                                 loader: viewModel.mediaLoader)
                    Text("— \(group.members.count)")
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.semibold))
                .listRowSeparator(.hidden)
                .padding(.top, 6)
                ForEach(group.members) { member in
                    memberRow(member)
                }
            }
            if !offlineMembers.isEmpty {
                HStack(spacing: 4) {
                    Text("Offline")
                    Text("— \(offlineMembers.count)")
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .padding(.top, 6)
                ForEach(offlineMembers) { member in
                    memberRow(member)
                        .opacity(0.6)
                }
            }
        }
        .listStyle(.plain)
        // Transparent so all three tabs share the sidebar material.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search members", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect()
                if viewModel.canInvite {
                    Button {
                        showsInvite = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .frame(width: 26, height: 26)
                            .glassEffect()
                    }
                    .buttonStyle(.plain)
                    .help("Invite People…")
                    .accessibilityLabel("Invite People")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showsInvite) {
            if case .active(let scope) = appState.phase {
                InviteSheet(scope: scope, roomId: viewModel.roomId,
                            roomName: viewModel.roomName)
            }
        }
        .modifier(ModerationPrompts(viewModel: viewModel,
                                    moderation: $moderation,
                                    moderationError: $moderationError))
        .overlay {
            if viewModel.membersLoadFailed && viewModel.members.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Members", systemImage: "person.2.slash")
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.loadMembers(force: true) }
                    }
                }
            } else if viewModel.members.isEmpty {
                ProgressView()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .sheet(item: $profileTarget) { target in
            ProfileSheet(target: target, ownUserId: viewModel.ownUserId) { userId in
                if let roomId = await viewModel.startDm(userId: userId) {
                    appState.pendingRoomNavigation = roomId
                    return true
                }
                return false
            }
        }
        .task { await viewModel.loadMembers() }
    }

    private func memberRow(_ member: TimelineViewModel.MemberItem) -> some View {
        Button {
            profileTarget = ProfileTarget(userId: member.id,
                                          displayName: member.displayName,
                                          avatarURL: member.avatarURL)
        } label: {
            MemberRowLabel(member: member, ownUserId: viewModel.ownUserId)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .help(member.id)
        .contextMenu {
            MemberActionsMenu(member: member, viewModel: viewModel, appState: appState) {
                profileTarget = ProfileTarget(userId: member.id,
                                              displayName: member.displayName,
                                              avatarURL: member.avatarURL)
            } moderate: { action in
                moderation = action
            }
        }
    }
}

/// Avatar + name + "you" tag, shared by the column's member rows (26pt) and the
/// iPhone sheet's rows (32pt).
private struct MemberRowLabel: View {
    let member: TimelineViewModel.MemberItem
    let ownUserId: String
    var avatarSize: CGFloat = 26
    var presenceSize: CGFloat = 8
    var spacing: CGFloat = 8
    @Environment(\.pronounsStore) private var pronounsStore

    var body: some View {
        HStack(spacing: spacing) {
            RoomAvatarView(name: member.name, isDirect: true, size: avatarSize,
                           avatarURL: member.avatarURL)
                .presenceIndicator(userId: member.id, size: presenceSize)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(member.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let pronouns = pronounsStore?.pronouns(for: member.id) {
                        Text(pronouns)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if member.id == ownUserId {
                        Text("you")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                // Commet custom status, Discord-style, under the name.
                if let status = pronounsStore?.status(for: member.id), !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Member context-menu actions, shared between the column and the iPhone sheet
/// so moderation gating stays in one place.
private struct MemberActionsMenu: View {
    let member: TimelineViewModel.MemberItem
    let viewModel: TimelineViewModel
    let appState: AppState
    let openProfile: () -> Void
    let moderate: (MemberListView.ModerationAction) -> Void

    var body: some View {
        Button("View Profile", systemImage: "person.crop.circle", action: openProfile)
        if member.id != viewModel.ownUserId {
            Button("Message", systemImage: "square.and.pencil") {
                Task {
                    if let roomId = await viewModel.startDm(userId: member.id) {
                        appState.pendingRoomNavigation = roomId
                    }
                }
            }
        }
        Button("Copy User ID", systemImage: "doc.on.doc") {
            Platform.copyToClipboard(member.id)
        }
        if member.id != viewModel.ownUserId,
           viewModel.canKick || viewModel.canBan {
            Divider()
            if viewModel.canKick {
                Button("Remove from Room…", systemImage: "person.badge.minus", role: .destructive) {
                    moderate(MemberListView.ModerationAction(member: member, isBan: false))
                }
            }
            if viewModel.canBan {
                Button("Ban from Room…", systemImage: "nosign", role: .destructive) {
                    moderate(MemberListView.ModerationAction(member: member, isBan: true))
                }
            }
        }
    }
}

/// Kick/ban confirmation dialog and failure alert, shared between the column's
/// member list and the iPhone details sheet.
private struct ModerationPrompts: ViewModifier {
    let viewModel: TimelineViewModel
    @Binding var moderation: MemberListView.ModerationAction?
    @Binding var moderationError: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                moderation.map { action in
                    Text(action.isBan ? "Ban \(action.member.name) from this room?"
                         : "Remove \(action.member.name) from this room?")
                } ?? Text("Confirm"),
                isPresented: Binding(get: { moderation != nil },
                                     set: { if !$0 { moderation = nil } }),
                titleVisibility: .visible
            ) {
                Button(moderation?.isBan == true ? "Ban" : "Remove", role: .destructive) {
                    guard let action = moderation else { return }
                    moderation = nil
                    Task {
                        moderationError = action.isBan
                            ? await viewModel.ban(userId: action.member.id)
                            : await viewModel.kick(userId: action.member.id)
                    }
                }
            } message: {
                if moderation?.isBan == true {
                    Text("They won't be able to rejoin until unbanned.")
                } else {
                    Text("They can rejoin if the room allows it.")
                }
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { moderationError != nil },
                set: { if !$0 { moderationError = nil } }
            )) {
                Button("OK") { moderationError = nil }
            } message: {
                Text(moderationError ?? "")
            }
    }
}

#if os(iOS)
/// iPhone room details: the same data and handlers as RoomDetailsColumn, as a
/// native inset-grouped sheet. Wide layouts keep the column.
private struct RoomDetailsSheet: View {
    let viewModel: TimelineViewModel
    var jumpToEvent: (String) -> Void = { _ in }
    @Environment(AppState.self) private var appState
    @Environment(\.presenceService) private var presence
    @State private var query = ""
    @State private var profileTarget: ProfileTarget?
    @State private var showsInvite = false
    @State private var settingsTarget: SettingsTarget?
    @State private var moderation: MemberListView.ModerationAction?
    @State private var moderationError: String?

    var body: some View {
        NavigationStack {
            List {
                // Searching narrows to member results; the static sections
                // would only push them below the fold.
                if query.isEmpty {
                    headerSection
                    actionsSection
                    mediaSection
                }
                membersSections
            }
            // Let the sheet's glass show through.
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Search members")
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $profileTarget) { target in
                ProfileSheet(target: target, ownUserId: viewModel.ownUserId) { userId in
                    if let roomId = await viewModel.startDm(userId: userId) {
                        appState.pendingRoomNavigation = roomId
                        return true
                    }
                    return false
                }
            }
            .sheet(isPresented: $showsInvite) {
                if case .active(let scope) = appState.phase {
                    InviteSheet(scope: scope, roomId: viewModel.roomId,
                                roomName: viewModel.roomName)
                }
            }
            .sheet(item: $settingsTarget) { target in
                if case .active(let scope) = appState.phase {
                    RoomSettingsSheet(scope: scope, target: target)
                }
            }
            .modifier(ModerationPrompts(viewModel: viewModel,
                                        moderation: $moderation,
                                        moderationError: $moderationError))
            .task { await viewModel.loadMembers() }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                RoomAvatarView(name: viewModel.roomName, isDirect: false, size: 72,
                               avatarURL: viewModel.avatarURL)
                Text(viewModel.roomName)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let topic = viewModel.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    Label("\(viewModel.memberCount) members", systemImage: "person.2")
                    if viewModel.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    }
                    if viewModel.hasActiveCall {
                        Label("Call in progress", systemImage: "phone.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Same handlers as the column's Info tab and invite affordance, as native
    /// grouped rows.
    private var actionsSection: some View {
        Section {
            if viewModel.canInvite {
                Button {
                    showsInvite = true
                } label: {
                    Label("Invite People…", systemImage: "person.badge.plus")
                }
            }
            Button {
                settingsTarget = SettingsTarget(roomId: viewModel.roomId,
                                                isSpace: false)
            } label: {
                Label("Room Settings…", systemImage: "gearshape")
            }
            Button {
                Platform.copyToClipboard(viewModel.roomId)
            } label: {
                Label("Copy Room ID", systemImage: "doc.on.doc")
            }
        }
    }

    private var mediaSection: some View {
        Section {
            NavigationLink {
                MediaGalleryView(viewModel: viewModel.mediaViewModel(),
                                 jumpToEvent: jumpToEvent)
                    .navigationTitle("Media")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Media & Files", systemImage: "photo.on.rectangle")
            }
        }
    }

    @ViewBuilder
    private var membersSections: some View {
        // Hoisted locals, mirroring MemberListView: one filter + presence scan
        // per evaluation instead of one per computed-property read.
        let filtered = MemberListView.filteredMembers(viewModel.members, matching: query)
        let offlineMembers = filtered.filter { presence?.state(of: $0.id) == .offline }
        let offlineIds = Set(offlineMembers.map(\.id))
        let groups = MemberListView.memberGroups(of: filtered.filter { !offlineIds.contains($0.id) })
        if viewModel.members.isEmpty {
            Section("Members") {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        } else if groups.isEmpty && offlineMembers.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(groups, id: \.level) { group in
                Section {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                } header: {
                    HStack {
                        RoleTagLabel(tag: viewModel.roleTag(forLevel: group.level),
                                     loader: viewModel.mediaLoader)
                        Text("\(group.members.count)")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !offlineMembers.isEmpty {
                Section {
                    ForEach(offlineMembers) { member in
                        memberRow(member).opacity(0.6)
                    }
                } header: {
                    HStack {
                        Text("Offline")
                        Text("\(offlineMembers.count)")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func memberRow(_ member: TimelineViewModel.MemberItem) -> some View {
        Button {
            profileTarget = ProfileTarget(userId: member.id,
                                          displayName: member.displayName,
                                          avatarURL: member.avatarURL)
        } label: {
            MemberRowLabel(member: member, ownUserId: viewModel.ownUserId,
                           avatarSize: 32, presenceSize: 10, spacing: 10)
                .contentShape(Rectangle())
        }
        // Rows are names, not actions; keep them label-colored.
        .foregroundStyle(.primary)
        .contextMenu {
            MemberActionsMenu(member: member, viewModel: viewModel, appState: appState) {
                profileTarget = ProfileTarget(userId: member.id,
                                              displayName: member.displayName,
                                              avatarURL: member.avatarURL)
            } moderate: { action in
                moderation = action
            }
        }
    }
}
#endif

struct SystemRow: View {
    let text: String

    var body: some View {
        // Gutter math mirrors MessageRow (40pt gutter, 10pt gap, 8pt inset) so
        // "X joined" aligns with message text.
        HStack(spacing: 10) {
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }
}

struct DayDividerView: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            divider
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            divider
        }
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

struct ReadMarkerView: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.red.opacity(0.6))
                .frame(height: 1)
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
            Rectangle()
                .fill(.red.opacity(0.6))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages below")
    }
}

struct TimelineStartView: View {
    var body: some View {
        Text("This is the beginning of the conversation.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}
