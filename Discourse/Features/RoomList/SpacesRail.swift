import SwiftUI
import UniformTypeIdentifiers

/// The server column: Home plus one avatar per joined top-level space, with the
/// account switcher pinned at the bottom.
struct SpacesRail: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var prefs
    let viewModel: RoomListViewModel
    let scope: SessionScope

    @State private var leavingSpace: RoomListViewModel.SpaceItem?
    @State private var draggingSpaceId: String?

    /// In-process drag type so only rail-originated drags match the drop delegates;
    /// a foreign text drag can't replay a stale draggingSpaceId.
    private static let spaceDragType = UTType(exportedAs: "es.discourse.space-reorder")

    var body: some View {
        VStack(spacing: 0) {
            railScroll
            Spacer(minLength: 0)
            // iOS has the Profile tab for this.
            #if os(macOS)
            accountSwitcher
                .padding(.vertical, 8)
            #endif
        }
        .frame(maxWidth: .infinity)
        // Undo the split view's sidebar content padding.
        .ignoresSafeArea(.container, edges: .horizontal)
        .confirmationDialog(
            leavingSpace.map { Text("Leave “\($0.name)”?") } ?? Text("Leave?"),
            isPresented: Binding(get: { leavingSpace != nil },
                                 set: { if !$0 { leavingSpace = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave Space", role: .destructive) {
                if let space = leavingSpace {
                    Task { await viewModel.leave(roomId: space.id) }
                }
                leavingSpace = nil
            }
        } message: {
            Text("Rooms in the space stay joined. You'll need an invite to rejoin a private space.")
        }
    }

    private var railScroll: some View {
        // Full strip width: the scroll view clips at its bounds, and the unread pips
        // hang left of the 48pt slots.
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                railButton(isSelected: viewModel.selectedSpaceId == nil, help: "Home",
                           hasUnread: viewModel.homeHasUnread,
                           hasMention: viewModel.homeHasMention) {
                    ZStack {
                        // Color.accentColor only reads the asset-catalog accent;
                        // the accent preference is applied as .tint, which it
                        // ignores — resolve through Preferences instead.
                        Circle().fill((prefs.resolvedTint ?? Color.accentColor).gradient)
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: avatarSize, height: avatarSize)
                } action: {
                    Task { await viewModel.selectSpace(nil) }
                }
                .contextMenu {
                    Button("Mark All as Read", systemImage: "envelope.open") {
                        viewModel.markRead(roomIds: viewModel.homeRoomIds)
                    }
                }

                // Divider between the chats button and the spaces. Concrete gray:
                // semantic styles vibrancy-blend into invisibility on the sidebar.
                Capsule()
                    .fill(Color.gray.opacity(0.55))
                    .frame(width: 32, height: 2)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)

                ForEach(viewModel.orderedSpaces) { space in
                    railButton(isSelected: viewModel.selectedSpaceId == space.id, help: space.name,
                               hasUnread: viewModel.spaceHasUnread(space.id),
                               hasMention: viewModel.spaceHasMention(space.id)) {
                        RoomAvatarView(name: space.name, isDirect: false, size: avatarSize,
                                       avatarURL: space.avatarURL)
                    } action: {
                        Task { await viewModel.selectSpace(space.id) }
                    }
                    .contextMenu {
                        Button("Mark All as Read", systemImage: "envelope.open") {
                            viewModel.markRead(roomIds: viewModel.childRoomIds(of: space.id))
                        }
                        Divider()
                        Button("Leave Space…", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive) {
                            leavingSpace = space
                        }
                    }
                    // Long-press-drag to rearrange; Home and "+" stay pinned.
                    .onDrag {
                        draggingSpaceId = space.id
                        // Payload is never read — the id travels via draggingSpaceId;
                        // only the private type matters.
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(
                            forTypeIdentifier: Self.spaceDragType.identifier,
                            visibility: .ownProcess
                        ) { completion in
                            completion(Data(space.id.utf8), nil)
                            return nil
                        }
                        return provider
                    }
                    .onDrop(of: [Self.spaceDragType], delegate: SpaceReorderDropDelegate(
                        targetId: space.id, draggingId: $draggingSpaceId, viewModel: viewModel))
                }

                railButton(isSelected: false, help: "New Space") {
                    ZStack {
                        Circle().fill(.quaternary.opacity(0.6))
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                    .frame(width: avatarSize, height: avatarSize)
                } action: {
                    appState.newChatSheet = .space
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var accountSwitcher: some View {
        Menu {
            ForEach(appState.accountTokens, id: \.session.userId) { token in
                Button {
                    Task { await appState.switchAccount(to: token.session.userId) }
                } label: {
                    if token.session.userId == appState.activeUserId {
                        Label(token.session.userId, systemImage: "checkmark")
                    } else {
                        Text(token.session.userId)
                    }
                }
            }
            Divider()
            Button("Add Account…", systemImage: "person.badge.plus") {
                appState.isAddAccountPresented = true
            }
            Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right",
                   role: .destructive) {
                // Confirmed by the main window's dialog before dropping the session.
                appState.isSignOutConfirmPresented = true
            }
        } label: {
            RoomAvatarView(name: scope.ownDisplayName ?? localpart(of: scope.userId),
                           isDirect: true, size: 40, avatarURL: scope.ownAvatarURL)
                // Dot when another signed-in account has unread activity.
                .overlay(alignment: .topTrailing) {
                    if appState.otherAccountsHaveUnread {
                        Circle().fill(.red)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().strokeBorder(Color.platformWindowBackground,
                                                           lineWidth: 2.5))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(scope.userId)
        // The avatar is accessibility-hidden, so the menu would otherwise be unlabeled.
        .accessibilityLabel(Text("Account: \(scope.userId)"))
    }

    private func localpart(of userId: String) -> String {
        guard userId.hasPrefix("@") else { return userId }
        return String(userId.dropFirst().prefix(while: { $0 != ":" }))
    }

    /// Slot fits the selection ring too — the ring must stay inside it or the rail
    /// clips it.
    private var avatarSize: CGFloat { 40 }
    private var slotSize: CGFloat { 48 }

    private func railButton(isSelected: Bool, help: String, hasUnread: Bool = false,
                            hasMention: Bool = false,
                            @ViewBuilder label: () -> some View,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: slotSize, height: slotSize)
                // Red mention dot, distinct from the left-edge unread pill.
                .overlay(alignment: .bottomTrailing) {
                    if hasMention {
                        Circle()
                            .fill(.red)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().strokeBorder(Color.platformWindowBackground, lineWidth: 2.5))
                            .offset(x: 2, y: 2)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .animation(prefs.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                           value: hasMention)
                // iPad pointer highlight; defined in SidebarView.swift.
                .pointerHighlight()
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        // Span the rail so the pip overlay's leading edge is the window edge.
        .frame(maxWidth: .infinity)
        // Left-edge indicator: a tall pill when selected, a short pip when unread.
        .overlay(alignment: .leading) {
            let pillHeight: CGFloat = isSelected ? 30 : (hasUnread ? 10 : 0)
            let pip = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                             bottomTrailingRadius: 4, topTrailingRadius: 4)
            Group {
                if pillHeight > 0 {
                    #if os(macOS)
                    // Concrete white + shadow: semantic colors vanish into the sidebar
                    // vibrancy.
                    pip.fill(.white)
                        .frame(width: 5, height: pillHeight)
                        .shadow(color: .black.opacity(0.45), radius: 1)
                    #else
                    pip.fill(.primary)
                        .frame(width: 5, height: pillHeight)
                    #endif
                }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
            .animation(prefs.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                       value: pillHeight)
        }
        .help(help)
        // .help is hover-only; VoiceOver and iOS need the name spoken too.
        .accessibilityLabel(help)
        // The pip, mention dot, and selection ring are purely visual — speak them.
        .accessibilityValue(hasMention ? Text("Mention")
            : (hasUnread && !isSelected ? Text("Unread") : Text(verbatim: "")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if os(macOS)
/// Reports the traffic-light cluster width (zoom button's trailing edge plus a
/// matching right inset) so the rail can line up under it.
struct TrafficLightWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> NSView { Probe(width: $width) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let width: Binding<CGFloat>
        private var observers: [NSObjectProtocol] = []

        init(width: Binding<CGFloat>) {
            self.width = width
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Observers are cleared here on the window == nil pass; a deinit can't touch
        // main-actor state under Swift 6.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // The buttons aren't laid out yet on first landing — measure after the
            // current layout pass, and again whenever the chrome could have moved.
            DispatchQueue.main.async { [weak self] in self?.measure() }
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didEndLiveResizeNotification,
                         NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.measure()
                        // Buttons animate in/out around full-screen transitions;
                        // re-measure once settled so a mid-animation reading doesn't stick.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            self?.measure()
                        }
                    })
            }
        }

        private func measure() {
            guard let window,
                  let close = window.standardWindowButton(.closeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let container = close.superview else { return }
            // Window coordinates, not superview frames: the titlebar container is
            // itself inset, which skews the symmetric-padding math.
            let closeMinX = container.convert(close.frame, to: nil).minX
            let zoomMaxX = container.convert(zoom.frame, to: nil).maxX
            let measured = zoomMaxX + closeMinX
            guard measured > 0, width.wrappedValue != measured else { return }
            width.wrappedValue = measured
        }
    }
}

/// Sidebar vibrancy (behind-window blur) for views that aren't actual split-view
/// sidebar columns.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The window's tinted content background, matching the timeline detail pane,
/// for surfaces that would otherwise paint a flat opaque color.
struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

/// Reorders spaces live as the dragged avatar passes over its neighbors; the
/// arrangement persists via the view model.
private struct SpaceReorderDropDelegate: DropDelegate {
    let targetId: String
    @Binding var draggingId: String?
    let viewModel: RoomListViewModel

    func validateDrop(info: DropInfo) -> Bool { draggingId != nil }

    func dropEntered(info: DropInfo) {
        // Delegate callbacks arrive on the main thread; the view model is main-actor.
        MainActor.assumeIsolated {
            guard let draggingId, draggingId != targetId else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                viewModel.moveSpace(id: draggingId, before: targetId)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}
