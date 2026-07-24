import SwiftUI
@preconcurrency import MatrixRustSDK
#if os(iOS)
import UIKit
#endif

extension View {
    /// iPad pointer hover highlight; inert on iPhone and macOS.
    @ViewBuilder
    func pointerHighlight() -> some View {
        #if os(iOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var prefs
    let scope: SessionScope
    let viewModel: RoomListViewModel
    @Binding var selection: String?
    @Binding var activeSheet: NewChatSheet?
    @Binding var showsVerification: Bool
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The room list sits beside the timeline only in the three-pane layouts
    /// (macOS, iPad). On iPhone the chat slides over as a full layer, so the
    /// column boundary would just draw a stray line over the header.
    private var showsColumnBoundary: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    /// Invites are account-level, not space-level, so they show in every space.
    private var invites: [RoomSummary] {
        viewModel.rooms.filter(\.isInvited)
    }

    private var visibleRooms: [RoomSummary] {
        let spaceChildren = viewModel.allSpaceChildIds
        let query = RoomSummary.foldedForSearch(debouncedQuery.trimmingCharacters(in: .whitespaces))
        return viewModel.rooms.filter { room in
            guard !room.isSpace, !room.isInvited else { return false }
            if !query.isEmpty && !room.foldedName.contains(query) {
                return false
            }
            if let visible = viewModel.visibleRoomIds {
                return visible.contains(room.id)
            }
            // Home: people always, rooms only if not filed in a space.
            return room.isDirect || !spaceChildren.contains(room.id)
        }
    }

    private func sortedRooms(_ rooms: [RoomSummary]) -> [RoomSummary] {
        rooms.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    private func styledRow(_ room: RoomSummary) -> some View {
        let isSelected = selection == room.id
        // A real Button, not onTapGesture: touch-down highlight and VoiceOver
        // button traits. Selection rendering stays in listRowBackground.
        return Button {
            selection = room.id
        } label: {
            RoomRow(room: room, isSelected: isSelected)
                .contentShape(Rectangle())
                .pointerHighlight()
        }
        .buttonStyle(.plain)
        // Selection identity for the macOS binding: ↑/↓ move through and open rooms.
        .tag(room.id)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selectionFill(isSelected))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        )
        // Prime the invite- and space-move-permission caches for visible rows,
        // so the context menu (built synchronously) can filter without awaiting.
        // Debounced so a fast fling doesn't fire FFI power-level fetches for
        // every row it passes.
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await viewModel.refreshInvitePermission(forRoomId: room.id)
            await viewModel.refreshMovePermission(forRoomId: room.id)
            for space in viewModel.spaces {
                await viewModel.refreshSpaceManagePermission(spaceId: space.id)
            }
        }
    }

    private func selectionFill(_ isSelected: Bool) -> AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(.clear) }
        // Both platforms draw the accent fill themselves; on macOS the
        // NSTableView pill (which follows the OS accent, not the app tint) is
        // switched off by ListSelectionHighlightDisabler.
        return isWindowInactive
            ? AnyShapeStyle(Color.gray.opacity(0.35))
            : AnyShapeStyle(.tint.opacity(0.85))
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    @State private var searchQuery = ""
    /// Trails `searchQuery` by ~150ms to avoid re-filtering the list per keystroke.
    @State private var debouncedQuery = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var leaveTarget: RoomSummary?
    /// One driver for all sidebar sheets: stacking several `.sheet(item:)` on a
    /// single view drops presentations at random (the "invite/settings/search
    /// sheet sometimes doesn't open"). Leave stays a separate dialog.
    @State private var modal: SidebarModal?

    private enum SidebarModal: Identifiable {
        case searchResults
        case settings(SettingsTarget)
        case invite(RoomSummary)
        var id: String {
            switch self {
            case .searchResults: "search"
            case .settings(let target): "settings-\(target.id)"
            case .invite(let room): "invite-\(room.id)"
            }
        }
    }

    /// Whether the current user can invite into the given room. Backed by the
    /// view model's async-filled cache (power levels can't be read synchronously
    /// here); rows and space menus prime it via `.task`. Fail closed.
    private func canInvite(toRoomId roomId: String) -> Bool {
        viewModel.invitableRoomIds.contains(roomId)
    }

    @ViewBuilder
    private func roomContextMenu(_ room: RoomSummary) -> some View {
        Button("Room Settings…", systemImage: "gearshape") {
            modal = .settings(SettingsTarget(roomId: room.id, isSpace: false))
        }
        if canInvite(toRoomId: room.id) {
            Button("Invite People…", systemImage: "person.badge.plus") {
                modal = .invite(room)
            }
        }
        Button("Mark as Read", systemImage: "envelope.open") {
            viewModel.markRead(roomIds: [room.id])
        }
        Divider()
        // Only offer the move at all for rooms you can actually re-parent
        // (needs `m.space.parent` power in the room itself).
        if !room.isDirect && viewModel.moveableRoomIds.contains(room.id) {
            // ...and only into spaces whose child list you can edit.
            let manageableSpaces = viewModel.spaces.filter {
                viewModel.manageableSpaceIds.contains($0.id)
            }
            if manageableSpaces.isEmpty {
                Button(viewModel.spaces.isEmpty ? "No Spaces Yet"
                                                : "No Spaces You Can Edit") {}
                    .disabled(true)
            } else {
                Menu("Spaces", systemImage: "square.grid.2x2") {
                    ForEach(manageableSpaces) { space in
                        let isMember = viewModel.spaceChildIds[space.id]?.contains(room.id) == true
                        Button {
                            Task { await viewModel.toggleRoom(room.id, inSpace: space.id) }
                        } label: {
                            if isMember {
                                Label(space.name, systemImage: "checkmark")
                            } else {
                                Text(space.name)
                            }
                        }
                    }
                }
            }
            Divider()
        }
        Button(room.isDirect ? "Leave Chat…" : "Leave Room…",
               systemImage: "rectangle.portrait.and.arrow.right",
               role: .destructive) {
            leaveTarget = room
        }
    }

    private var selectedSpace: RoomListViewModel.SpaceItem? {
        guard let id = viewModel.selectedSpaceId else { return nil }
        return viewModel.spaces.first { $0.id == id }
    }

    /// Rooms the selected space advertises that we haven't joined yet.
    private var unjoinedSpaceRooms: [RoomListViewModel.SpaceChild] {
        guard let spaceId = viewModel.selectedSpaceId else { return [] }
        // Same folded matching as the joined-room filter.
        let query = RoomSummary.foldedForSearch(debouncedQuery.trimmingCharacters(in: .whitespaces))
        return (viewModel.spaceChildren[spaceId] ?? []).filter { child in
            !child.isSpace && !child.isJoined
                && (query.isEmpty || RoomSummary.foldedForSearch(child.name).contains(query))
        }
    }

    /// Spaces whose names match the filter; selecting one jumps to it.
    private var matchingSpaces: [RoomListViewModel.SpaceItem] {
        let query = RoomSummary.foldedForSearch(debouncedQuery.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return [] }
        return viewModel.orderedSpaces.filter {
            RoomSummary.foldedForSearch($0.name).contains(query)
        }
    }

    private func debounceSearch(_ query: String) {
        searchDebounce?.cancel()
        // Clearing skips the debounce so the clear button doesn't leave a stale list.
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            debouncedQuery = query
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
    }

    var body: some View {
        roomList
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 4) {
                    // macOS puts the space switcher and + in the window toolbar.
                    #if !os(macOS)
                    headerRow
                    #endif
                    // Search only in Home; a space's room list is short enough
                    // that a second search bar is redundant.
                    if viewModel.selectedSpaceId == nil {
                        searchField
                    }
                }
                .padding(.bottom, 2)
                // Backed so the list doesn't scroll visibly under the
                // title/search/＋. macOS uses the window material so it takes the
                // same tint as the timeline detail pane.
                .background {
                    #if os(macOS)
                    ZStack { WindowMaterial(); prefs.windowWash }
                        .ignoresSafeArea(edges: .top)
                    #else
                    ZStack { Color.platformWindowBackground; prefs.windowWash }
                        .ignoresSafeArea(edges: .top)
                    #endif
                }
            }
            .task(id: viewModel.selectedSpaceId) {
                spaceBannerURL = nil
                if let spaceId = viewModel.selectedSpaceId {
                    await viewModel.refreshInvitePermission(forRoomId: spaceId)
                    spaceBannerURL = await viewModel.spaceBannerURL(forSpace: spaceId)
                }
            }
            .sheet(isPresented: $showsSpaceHome) {
                if let space = selectedSpace {
                    SpaceHomeView(space: space, bannerURL: spaceBannerURL, scope: scope)
                }
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsSpaceMenu.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Text(selectedSpace?.name ?? String(localized: "Home"))
                                .font(.headline)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsSpaceMenu, arrowEdge: .bottom) {
                        spaceMenuContent
                            .padding(6)
                            .frame(minWidth: 220, alignment: .leading)
                    }
                    .contextMenu {
                        spaceMenuItems
                    }
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.flexible, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        newMenuItems
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help(selectedSpace.map { "New room in \($0.name)" } ?? "New message or room")
                }
            }
            #endif
            .sheet(item: $modal) { modal in
                switch modal {
                case .searchResults:
                    SearchResultsSheet(scope: scope, query: searchQuery)
                case .settings(let target):
                    RoomSettingsSheet(scope: scope, target: target)
                case .invite(let room):
                    InviteSheet(scope: scope, roomId: room.id, roomName: room.name)
                }
            }
            .confirmationDialog(
                leaveTarget.map { Text("Leave “\($0.name)”?") } ?? Text("Leave?"),
                isPresented: Binding(get: { leaveTarget != nil },
                                     set: { if !$0 { leaveTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button(leaveTarget?.isSpace == true ? "Leave Space"
                       : leaveTarget?.isDirect == true ? "Leave Chat" : "Leave Room",
                       role: .destructive) {
                    if let target = leaveTarget {
                        if selection == target.id { selection = nil }
                        Task { await viewModel.leave(roomId: target.id) }
                    }
                    leaveTarget = nil
                }
            } message: {
                if leaveTarget?.isSpace == true {
                    Text("Rooms in the space stay joined. You'll need an invite to rejoin a private space.")
                } else if leaveTarget?.isDirect == true {
                    Text("The conversation will be removed from your list.")
                } else {
                    Text("You'll need an invite to rejoin a private room.")
                }
            }
            // Column boundary against the chat (three-pane layouts only).
            .overlay(alignment: .trailing) {
                if showsColumnBoundary {
                    Rectangle()
                        .fill(columnDividerColor)
                        .frame(width: 0.5)
                        .ignoresSafeArea()
                }
            }
            // View ▸ Filter Rooms (⌘⇧F).
            .onChange(of: appState.sidebarFilterFocusRequest) {
                isSearchFocused = true
            }
    }

    /// macOS needs a dark hairline against the chat chrome; iOS uses the
    /// system separator so Light Mode gets a light one.
    private var columnDividerColor: Color {
        #if os(iOS)
        Color(UIColor.separator)
        #else
        Color.black.opacity(0.55)
        #endif
    }

    @State private var showsSpaceMenu = false
    @State private var spaceBannerURL: String?
    @State private var showsSpaceHome = false

    /// Sync status for the header title; nil once caught up.
    private var headerStatus: String? {
        if viewModel.isReconnecting { return String(localized: "Reconnecting…") }
        if viewModel.isCatchingUp { return String(localized: "Updating…") }
        return nil
    }

    /// Space switcher and "new" menu atop the room list. iOS only; macOS puts
    /// both in the window toolbar.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Menu {
                spaceMenuItems
            } label: {
                HStack(spacing: 5) {
                    // Sync status stacks under the title; content stays browsable.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedSpace?.name ?? String(localized: "Home"))
                            .font(.headline)
                            .lineLimit(1)
                        if let status = headerStatus {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Menu {
                newMenuItems
            } label: {
                // Hit area extends past the 36pt visual to 44pt.
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .glassEffect()
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .pointerHighlight()
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(selectedSpace.map { "New room in \($0.name)" } ?? "New message or room")
            .accessibilityLabel(selectedSpace.map { "New room in \($0.name)" } ?? "New message or room")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// Shared by the macOS toolbar menu and the iOS in-content header.
    @ViewBuilder
    private var newMenuItems: some View {
        if let space = selectedSpace {
            Button("New Room…", systemImage: "number") {
                activeSheet = .room(spaceId: space.id)
            }
            Button("New Video Room…", systemImage: "video") {
                activeSheet = .videoRoom(spaceId: space.id)
            }
        } else {
            Button("New Message…", systemImage: "square.and.pencil") {
                activeSheet = .directMessage
            }
            Button("New Room…", systemImage: "number") {
                activeSheet = .room(spaceId: nil)
            }
            Button("New Video Room…", systemImage: "video") {
                activeSheet = .videoRoom(spaceId: nil)
            }
        }
    }

    /// Space actions as native menu items (iOS header Menu).
    @ViewBuilder
    private var spaceMenuItems: some View {
        if let space = selectedSpace {
            Button("Join Room…", systemImage: "arrow.right.circle") {
                activeSheet = .join
            }
            if canInvite(toRoomId: space.id) {
                Button("Invite People…", systemImage: "person.badge.plus") {
                    if let summary = viewModel.rooms.first(where: { $0.id == space.id }) {
                        modal = .invite(summary)
                    }
                }
            }
            Divider()
            Button("Space Settings…", systemImage: "gearshape") {
                modal = .settings(SettingsTarget(roomId: space.id, isSpace: true))
            }
            Button("Refresh Rooms", systemImage: "arrow.clockwise") {
                Task { await viewModel.selectSpace(space.id) }
            }
            Button("Mark All as Read", systemImage: "envelope.open") {
                viewModel.markRead(roomIds: viewModel.childRoomIds(of: space.id))
            }
            Divider()
            Button("Leave Space…", systemImage: "rectangle.portrait.and.arrow.right",
                   role: .destructive) {
                if let summary = viewModel.rooms.first(where: { $0.id == space.id }) {
                    leaveTarget = summary
                }
            }
        } else {
            Button("Join Room…", systemImage: "arrow.right.circle") {
                activeSheet = .join
            }
            Button("Mark All as Read", systemImage: "envelope.open") {
                viewModel.markRead(roomIds: viewModel.homeRoomIds)
            }
        }
    }

    /// Space actions shown in the macOS header popover.
    @ViewBuilder
    private var spaceMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let space = selectedSpace {
                spaceMenuButton("Join Room…", systemImage: "arrow.right.circle") {
                    activeSheet = .join
                }
                if canInvite(toRoomId: space.id) {
                    spaceMenuButton("Invite People…", systemImage: "person.badge.plus") {
                        if let summary = viewModel.rooms.first(where: { $0.id == space.id }) {
                            modal = .invite(summary)
                        }
                    }
                }
                Divider()
                spaceMenuButton("Space Settings…", systemImage: "gearshape") {
                    modal = .settings(SettingsTarget(roomId: space.id, isSpace: true))
                }
                spaceMenuButton("Refresh Rooms", systemImage: "arrow.clockwise") {
                    Task { await viewModel.selectSpace(space.id) }
                }
                spaceMenuButton("Mark All as Read", systemImage: "envelope.open") {
                    viewModel.markRead(roomIds: viewModel.childRoomIds(of: space.id))
                }
                Divider()
                spaceMenuButton("Leave Space…", systemImage: "rectangle.portrait.and.arrow.right",
                                role: .destructive) {
                    if let summary = viewModel.rooms.first(where: { $0.id == space.id }) {
                        leaveTarget = summary
                    }
                }
            } else {
                spaceMenuButton("Join Room…", systemImage: "arrow.right.circle") {
                    activeSheet = .join
                }
                spaceMenuButton("Mark All as Read", systemImage: "envelope.open") {
                    viewModel.markRead(roomIds: viewModel.homeRoomIds)
                }
            }
        }
    }

    private func spaceMenuButton(_ title: LocalizedStringKey, systemImage: String,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role) {
            showsSpaceMenu = false
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Filters rooms as you type; Enter searches message content.
    private var searchField: some View {
        searchFieldRow
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect()
            // 16pt outer gutter lines the pill's edge up with the row content.
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private var searchFieldRow: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onChange(of: searchQuery) { _, newValue in
                    debounceSearch(newValue)
                }
                .onSubmit {
                    if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        modal = .searchResults
                    }
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                #endif
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    #if os(iOS)
                    // Bigger hit area; the shape insets outward so taps land
                    // across the pill's full height.
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle().inset(by: -6))
                        .hoverEffect(.highlight)
                    #else
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                    #endif
                }
                .buttonStyle(.plain)
            }
        }
        #if os(iOS)
        // Constant pill height whether or not the clear button is showing.
        return row.frame(minHeight: 32)
        #else
        return row
        #endif
    }

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    private var isWindowInactive: Bool { controlActiveState == .inactive }

    /// Stages a drop's payload into the room's composer and opens the room,
    /// via the same staging path the composer's own drop uses.
    private func stageDrop(_ items: [ComposerDropItem], into room: RoomSummary) -> Bool {
        guard !items.isEmpty,
              let timeline = scope.timeline(forRoomId: room.id) else { return false }
        for item in items {
            switch item {
            case .file(let data, let filename):
                timeline.stageAttachment(data: data, filename: filename)
            case .image(let data):
                timeline.stageAttachment(data: data, filename: "image")
            }
        }
        selection = room.id
        return true
    }
    #else
    private var isWindowInactive: Bool { false }
    #endif

    private var roomList: some View {
        // Filter and sort once per evaluation, not once per row.
        let visible = visibleRooms
        let sorted = sortedRooms(visible)
        // macOS binds selection so ↑/↓ move through and open rooms; iOS keeps
        // the untracked list.
        #if os(macOS)
        let list = List(selection: $selection) { listContent(sorted) }
        #else
        let list = List { listContent(sorted) }
        #endif
        return list
        .listStyle(.plain)
        #if os(macOS)
        // The table's own selection pill follows the OS accent; the rows draw
        // an app-accent fill instead (see selectionFill).
        .background(ListSelectionHighlightDisabler())
        #endif
        // Show the sidebar's platformWindowBackground instead of the list's own
        // fill, so the rows sit on the same color as the header above them.
        .scrollContentBackground(.hidden)
        .overlay {
            // Only when the list is truly empty: during a name filter the
            // "Search messages…" row is the no-matches affordance, and pending
            // invites must stay visible.
            if visible.isEmpty,
               debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty,
               invites.isEmpty {
                if viewModel.isLoaded {
                    ContentUnavailableView("No Rooms", systemImage: "tray",
                                           description: Text(viewModel.selectedSpaceId == nil
                                               ? "Join a room to get started."
                                               : "This space has no rooms you've joined."))
                } else {
                    ProgressView("Syncing…")
                }
            }
        }
        #if os(iOS)
        // In a space, mirror "Refresh Rooms". On Home, selectSpace(nil) is a
        // no-op, so crawl every space to refresh the filed-room exclusions.
        .refreshable {
            if let id = viewModel.selectedSpaceId {
                await viewModel.selectSpace(id)
            } else {
                await viewModel.refreshAllSpaceChildren()
            }
        }
        #endif
    }

    @ViewBuilder
    private func listContent(_ sorted: [RoomSummary]) -> some View {
            if let banner = spaceBannerURL {
                Button {
                    showsSpaceHome = true
                } label: {
                    BannerImageView(mxcUrl: banner)
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.4))
                                .padding(6)
                        }
                }
                .buttonStyle(.plain)
                .help("Space home")
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            if scope.needsVerification {
                Button {
                    showsVerification = true
                } label: {
                    Label("Verify this session", systemImage: "lock.shield.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help("Encrypted messages stay locked until this Mac is verified.")
                .selectionDisabled()
                #if os(iOS)
                .accessibilityHint("Encrypted messages stay locked until this device is verified.")
                #endif
            }
            if let banner = viewModel.syncBanner {
                Label(banner, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectionDisabled()
            }
            // One-off action failures (join/leave/invite); auto-cleared.
            if let error = viewModel.actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectionDisabled()
            }
            #if os(macOS)
            // iOS surfaces this in the header title; the Mac title is in the
            // window toolbar, so use a quiet row instead.
            if viewModel.syncBanner == nil, viewModel.isCatchingUp {
                Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            #endif
            // Name filtering only; this row reaches message content.
            if !debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = debouncedQuery.trimmingCharacters(in: .whitespaces)
                Button {
                    modal = .searchResults
                } label: {
                    Label("Search messages for “\(trimmed)”",
                          systemImage: "text.magnifyingglass")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .pointerHighlight()
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
            // The room list excludes spaces, so match them separately here.
            if !matchingSpaces.isEmpty {
                Section {
                    ForEach(matchingSpaces) { space in
                        Button {
                            searchQuery = ""
                            debouncedQuery = ""
                            Task { await viewModel.selectSpace(space.id) }
                        } label: {
                            HStack(spacing: 10) {
                                RoomAvatarView(name: space.name, isDirect: false, size: 28,
                                               avatarURL: space.avatarURL)
                                Text(space.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .pointerHighlight()
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                    }
                } header: {
                    sectionHeader("Spaces")
                }
            }
            if !invites.isEmpty {
                Section {
                    ForEach(invites) { room in
                        InviteRow(room: room,
                                  isJoining: viewModel.joiningInviteIds.contains(room.id)) {
                            Task {
                                await viewModel.acceptInvite(roomId: room.id)
                                if !room.isSpace { selection = room.id }
                            }
                        } decline: {
                            Task { await viewModel.leave(roomId: room.id) }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        // Accept/decline only; not an arrow-key selection stop.
                        .selectionDisabled()
                    }
                } header: {
                    sectionHeader("Invites")
                }
            }

            // Rooms and DMs in one list, most recent activity first.
            ForEach(sorted) { room in
                #if os(iOS)
                // No swipe actions: horizontal swipes belong to the chat pager.
                styledRow(room)
                    .contextMenu { roomContextMenu(room) }
                #else
                styledRow(room)
                    .contextMenu { roomContextMenu(room) }
                    // Dropping a file stages it in the room and opens it.
                    .dropDestination(for: ComposerDropItem.self) { items, _ in
                        stageDrop(items, into: room)
                    }
                #endif
            }

            // Everything else the space advertises, one click from joining.
            if !unjoinedSpaceRooms.isEmpty {
                Section {
                    ForEach(unjoinedSpaceRooms) { child in
                        SpaceDirectoryRow(child: child,
                                          isJoining: viewModel.joiningRoomIds.contains(child.id)) {
                            Task {
                                await viewModel.joinSpaceChild(child)
                                selection = child.id
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        // Joinable listing, not a joined room; keep ↑/↓ out.
                        .selectionDisabled()
                    }
                } header: {
                    sectionHeader("More Rooms")
                }
            }
    }
}

/// A room advertised by the selected space but not yet joined.
struct SpaceDirectoryRow: View {
    let child: RoomListViewModel.SpaceChild
    let isJoining: Bool
    let join: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoomAvatarView(name: child.name, isDirect: false, avatarURL: child.avatarURL)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(child.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if child.isVideoRoom {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Video room")
                            .accessibilityLabel("Video room")
                    }
                }
                Text(child.topic ?? String(localized: "\(child.memberCount) members"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Name + topic as one summary; Join stays its own stop.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Group {
                if isJoining {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                } else {
                    Button(action: join) {
                        Text("Join")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    #if os(iOS)
                    .controlSize(.regular)
                    #else
                    .controlSize(.small)
                    #endif
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isJoining)
        }
        .padding(.vertical, 4)
    }
}

/// A pending invite: who it's from, what it is, accept/decline.
struct InviteRow: View {
    let room: RoomSummary
    /// Accept in flight: the badge becomes a spinner and both buttons disable
    /// so the invite can't be double-actioned.
    var isJoining = false
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoomAvatarView(name: room.name, isDirect: room.isDirect, avatarURL: room.avatarURL)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(room.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if room.isSpace {
                        Text("Space")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(room.inviterName.map { String(localized: "\($0) invited you") }
                     ?? String(localized: "You've been invited"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Name, badge, and inviter as one element; Accept/Decline stay separate.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(action: decline) {
                badge("xmark", Color.red)
            }
            .buttonStyle(.plain)
            .disabled(isJoining)
            .help("Decline")
            .accessibilityLabel("Decline")
            Button(action: accept) {
                if isJoining {
                    joiningBadge
                } else {
                    badge("checkmark", Color.green)
                }
            }
            .buttonStyle(.plain)
            .disabled(isJoining)
            .help("Accept")
            .accessibilityLabel("Accept")
        }
        .padding(.vertical, 6)
    }

    /// 24pt visual circle; on iOS the hit area extends to 44pt.
    private func badge(_ systemImage: String, _ fill: some ShapeStyle) -> some View {
        let circle = Image(systemName: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(fill, in: Circle())
        #if os(iOS)
        return circle
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
        #else
        return circle
        #endif
    }

    /// Accept-in-flight spinner in the badge's footprint so the row doesn't shift.
    private var joiningBadge: some View {
        let spinner = ProgressView()
            .controlSize(.small)
            .frame(width: 24, height: 24)
        #if os(iOS)
        return spinner
            .frame(width: 44, height: 44)
        #else
        return spinner
        #endif
    }
}

struct RoomRow: View {
    let room: RoomSummary
    var isSelected = false
    @Environment(Preferences.self) private var prefs

    /// Bright while there's something new, dimmed once read. Selected rows
    /// stay bright.
    private var isUnread: Bool { isSelected || room.hasAnyUnread }

    /// White text on the accent selection fill (both platforms draw it);
    /// semantic .primary would be black-on-accent in Light Mode.
    private var titleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        return isUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var subtitleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.8)) }
        return isUnread ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }

    private var detailStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.8)) }
        return AnyShapeStyle(.tertiary)
    }

    /// "You: hi" / "Alice: hi". Previews with no sender (invitations) stay bare.
    private var previewText: String? {
        guard let preview = room.lastMessagePreview else { return nil }
        if room.lastMessageIsOwn {
            return String(localized: "You: \(preview)")
        }
        if let sender = room.lastMessageSenderName {
            return "\(sender): \(preview)"
        }
        return preview
    }

    var body: some View {
        HStack(spacing: 8) {
            RoomAvatarView(name: room.name, isDirect: room.isDirect, avatarURL: room.avatarURL)
                .presenceIndicator(userId: room.dmUserId, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(room.name)
                        .font(.body.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(titleStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .animation(prefs.reduceMotion ? nil : .easeOut(duration: 0.15),
                                   value: isUnread)
                    if room.isVideoRoom {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                            .foregroundStyle(room.hasActiveCall ? AnyShapeStyle(.green) : detailStyle)
                            .help(room.hasActiveCall ? "Video room — call in progress" : "Video room")
                            .accessibilityLabel(room.hasActiveCall ? "Video room — call in progress" : "Video room")
                    }
                    if room.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(detailStyle)
                            .help("End-to-end encrypted")
                            .accessibilityLabel("End-to-end encrypted")
                    }
                    Spacer(minLength: 4)
                    if let date = room.lastActivity {
                        Text(date, format: relativeFormat(for: date))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(detailStyle)
                            // Cap growth so the timestamp can't crowd out the
                            // room name at accessibility sizes.
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                if room.hasActiveCall, !room.callParticipantIds.isEmpty {
                    CallParticipantsStrip(userIds: room.callParticipantIds)
                }
                HStack(spacing: 4) {
                    if let preview = previewText {
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(subtitleStyle)
                            .lineLimit(2, reservesSpace: false)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if room.hasUnread {
                        Text(String(room.badgeCount))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            // Red for a real mention, otherwise the accent capsule.
                            .background(room.isMentioned ? AnyShapeStyle(.red) : AnyShapeStyle(.tint),
                                        in: Capsule())
                            // The row's accessibility value announces the count instead.
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .fixedSize()
                            .layoutPriority(1)
                            .accessibilityHidden(true)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        // Scoped to badgeCount so unrelated row updates don't animate.
        .animation(prefs.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                   value: room.badgeCount)
        // Name, glyphs, timestamp, and preview read as one summary.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(accessibilityUnreadValue))
    }

    /// Unread state is otherwise conveyed only by font weight, which
    /// VoiceOver can't see.
    private var accessibilityUnreadValue: String {
        if room.isMentioned {
            return String(localized: "\(room.unreadMentions) mentions")
        }
        if room.badgeCount > 0 {
            return String(localized: "\(room.badgeCount) unread")
        }
        if room.hasAnyUnread {
            return String(localized: "Unread")
        }
        return ""
    }

    // Immutable and reused per render; building them per row is measurable
    // across a long sidebar.
    private static let calendar = Calendar.current
    private static let todayFormat = Date.FormatStyle.dateTime.hour().minute()
    private static let earlierFormat = Date.FormatStyle.dateTime.month(.abbreviated).day()

    private func relativeFormat(for date: Date) -> Date.FormatStyle {
        Self.calendar.isDateInToday(date) ? Self.todayFormat : Self.earlierFormat
    }
}

/// Discord-style overlapping avatars of who's currently in a room's call.
/// Real profile pictures via the shared profile cache (falls back to colored
/// initials until each fetch lands).
private struct CallParticipantsStrip: View {
    let userIds: [String]
    @Environment(\.pronounsStore) private var profiles
    private let maxShown = 5

    var body: some View {
        HStack(spacing: -6) {
            ForEach(userIds.prefix(maxShown), id: \.self) { userId in
                RoomAvatarView(name: profiles?.displayName(for: userId) ?? Self.localpart(userId),
                               isDirect: true, size: 18,
                               avatarURL: profiles?.avatarURL(for: userId))
                    .overlay(Circle().stroke(Color.platformWindowBackground, lineWidth: 1.5))
            }
            if userIds.count > maxShown {
                Text("+\(userIds.count - maxShown)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private static func localpart(_ userId: String) -> String {
        guard userId.hasPrefix("@") else { return userId }
        return String(userId.dropFirst().prefix { $0 != ":" })
    }
}

/// Circular avatar loaded through the session's media loader, falling back
/// to colored initials.
struct RoomAvatarView: View {
    let name: String
    let isDirect: Bool
    var size: CGFloat = 28
    var avatarURL: String?

    @Environment(\.mediaLoader) private var mediaLoader
    @State private var image: PlatformImage?

    /// Synchronous cache hit so recycled rows show the avatar on their first
    /// frame instead of flashing initials.
    private var cachedImage: PlatformImage? {
        guard let avatarURL, let mediaLoader,
              let source = RoomSummary.avatarSource(mxcUrl: avatarURL) else { return nil }
        return mediaLoader.cachedThumbnail(for: source, pixelSize: size * 2)
    }

    var body: some View {
        ZStack {
            if let image = image ?? cachedImage {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(backgroundColor.gradient)
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Decorative: the adjacent name carries the info. Otherwise VoiceOver
        // reads the initials as a stray fragment.
        .accessibilityHidden(true)
        .task(id: avatarURL) {
            guard let avatarURL, let mediaLoader else {
                image = nil
                return
            }
            image = await mediaLoader.avatar(mxcUrl: avatarURL, pixelSize: size * 2)
        }
    }

    private var initials: String {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "#@!+ "))
        let words = cleaned.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var backgroundColor: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .green]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}

#if os(macOS)
/// Turns off the NSTableView selection pill behind the room list. The system
/// draws it in the OS accent color, which fights the app-accent fill the rows
/// draw themselves (selectionFill); selection state and ↑/↓ keyboard movement
/// are unaffected.
private struct ListSelectionHighlightDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The table doesn't exist until after the current layout pass.
        DispatchQueue.main.async { Self.disable(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.disable(from: nsView) }
    }

    /// The probe sits as a background sibling of the List, so walk up a level
    /// at a time and search descendants — the first table found is the list's.
    private static func disable(from view: NSView) {
        var current: NSView? = view.superview
        while let level = current {
            if let table = findTable(in: level) {
                table.selectionHighlightStyle = .none
                return
            }
            current = level.superview
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = findTable(in: subview) { return table }
        }
        return nil
    }
}
#endif
