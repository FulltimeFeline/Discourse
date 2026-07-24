#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
@preconcurrency import MatrixRustSDK

/// Drives the sidebar: applies SDK room-list diffs and keeps unread counts current.
@MainActor
@Observable
final class RoomListViewModel {
    struct SpaceItem: Identifiable, Hashable {
        let id: String
        var name: String
        var avatarURL: String?
        var topic: String?
    }

    struct SpaceChild: Hashable, Identifiable {
        let id: String
        let name: String
        let isSpace: Bool
        let isVideoRoom: Bool
        let avatarURL: String?
        let topic: String?
        let memberCount: UInt64
        let isJoined: Bool
        let via: [String]
    }

    private(set) var rooms: [RoomSummary] = []
    private(set) var isLoaded = false
    private(set) var syncBanner: String?
    /// One-off action failures, auto-cleared after a few seconds. Separate from
    /// `syncBanner`, which republishes sync state each tick and would clobber it.
    private(set) var actionError: String?
    @ObservationIgnored private var actionErrorTask: Task<Void, Never>?
    /// The sync service reports offline/error, as opposed to a one-off action failure.
    private(set) var isReconnecting = false
    /// Restored content is on screen but this launch's first sync hasn't caught up.
    var isCatchingUp: Bool { !isLoaded && !rooms.isEmpty }
    /// SDK-ordered: the space diff stream is positional, so this stays index-aligned
    /// with it. Display order lives in `orderedSpaces`.
    private(set) var spaces: [SpaceItem] = []
    /// `spaces` in the user's drag-arranged order, persisted per account. Unknown
    /// spaces go to the end.
    private(set) var orderedSpaces: [SpaceItem] = []
    private(set) var selectedSpaceId: String?
    /// Room IDs visible for the selected space; nil = Home.
    private(set) var visibleRoomIds: Set<String>?
    /// Direct children of every joined top-level space, by space ID. Also keeps
    /// Home to space-less rooms only.
    private(set) var spaceChildIds: [String: Set<String>] = [:]
    /// Full child listings per space, including rooms not yet joined.
    private(set) var spaceChildren: [String: [SpaceChild]] = [:]
    private(set) var videoRoomIds: Set<String> = []
    private(set) var joiningRoomIds: Set<String> = []
    private(set) var joiningInviteIds: Set<String> = []

    /// Union of all space children — anything here is hidden from Home. Memoized:
    /// hot paths read it per render, so it's rebuilt only where `spaceChildIds` mutates.
    private(set) var allSpaceChildIds: Set<String> = []

    private func rebuildAllSpaceChildIds() {
        let union = spaceChildIds.values.reduce(into: Set()) { $0.formUnion($1) }
        if allSpaceChildIds != union { allSpaceChildIds = union }
        recomputeUnreadFlags()
    }

    /// Rail unread state, stored rather than derived to avoid a per-space O(rooms)
    /// scan on every rail render. Equality-guarded so the rail only re-renders when
    /// a flag actually flips.
    private(set) var unreadSpaceIds: Set<String> = []
    private(set) var homeHasUnreadFlag = false
    /// Spaces (and Home) with a real mention waiting — a red rail badge, distinct
    /// from a plain unread pip.
    private(set) var mentionSpaceIds: Set<String> = []
    private(set) var homeHasMentionFlag = false

    private func recomputeUnreadFlags() {
        var spaceIds: Set<String> = []
        var mentionIds: Set<String> = []
        var homeUnread = false
        var homeMention = false
        for room in rooms where room.hasAnyUnread {
            let isHomeRoom = !room.isSpace && (room.isDirect || !allSpaceChildIds.contains(room.id))
            if isHomeRoom {
                homeUnread = true
                if room.isMentioned { homeMention = true }
            }
            for (spaceId, children) in spaceChildIds where children.contains(room.id) {
                spaceIds.insert(spaceId)
                if room.isMentioned { mentionIds.insert(spaceId) }
            }
        }
        if unreadSpaceIds != spaceIds { unreadSpaceIds = spaceIds }
        if homeHasUnreadFlag != homeUnread { homeHasUnreadFlag = homeUnread }
        if mentionSpaceIds != mentionIds { mentionSpaceIds = mentionIds }
        if homeHasMentionFlag != homeMention { homeHasMentionFlag = homeMention }
    }

    func spaceHasUnread(_ spaceId: String) -> Bool {
        unreadSpaceIds.contains(spaceId)
    }

    func spaceHasMention(_ spaceId: String) -> Bool {
        mentionSpaceIds.contains(spaceId)
    }

    /// Publishes an action failure and clears it ~6s later. Cancel-and-replace
    /// so a second failure gets its full display window.
    private func reportActionError(_ message: String) {
        actionError = message
        actionErrorTask?.cancel()
        actionErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionError = nil
        }
    }

    /// Leaving the selected space falls back to Home.
    func leave(roomId: String) async {
        guard let room = ffiRoom(withId: roomId) else { return }
        do {
            try await room.leave()
        } catch {
            let name = roomIndexById[roomId].map { rooms[$0].name } ?? roomId
            reportActionError(String(localized: "Couldn't leave \(name): \(error.localizedDescription)"))
            return
        }
        if selectedSpaceId == roomId {
            await selectSpace(nil)
        }
    }

    var homeHasUnread: Bool { homeHasUnreadFlag }
    var homeHasMention: Bool { homeHasMentionFlag }

    // MARK: Go-menu navigation

    /// Rooms visible in the sidebar for the current space, most-recent-activity
    /// first — the same order the sidebar renders. Drives the Go menu's Next/Previous.
    var orderedVisibleRoomIds: [String] {
        let filed = allSpaceChildIds
        return rooms.filter { room in
            guard !room.isSpace, !room.isInvited else { return false }
            if let visible = visibleRoomIds { return visible.contains(room.id) }
            return room.isDirect || !filed.contains(room.id)
        }
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        .map(\.id)
    }

    /// The room `delta` steps away in sidebar order, clamped to the ends. With no
    /// current room, steps in from the nearest end.
    func roomId(offsetBy delta: Int, from currentId: String?) -> String? {
        let ids = orderedVisibleRoomIds
        guard !ids.isEmpty else { return nil }
        guard let currentId, let index = ids.firstIndex(of: currentId) else {
            return delta > 0 ? ids.first : ids.last
        }
        let target = min(max(index + delta, 0), ids.count - 1)
        guard target != index else { return nil }
        return ids[target]
    }

    /// The next/previous unread room in sidebar order, wrapping around.
    func nextUnreadRoomId(from currentId: String?, forward: Bool) -> String? {
        let ids = orderedVisibleRoomIds
        guard !ids.isEmpty else { return nil }
        let unread = Set(rooms.filter { $0.hasAnyUnread }.map(\.id))
        guard !unread.isEmpty else { return nil }
        let start = currentId.flatMap { ids.firstIndex(of: $0) } ?? (forward ? -1 : ids.count)
        let step = forward ? 1 : -1
        for offset in 1...ids.count {
            let index = ((start + step * offset) % ids.count + ids.count) % ids.count
            let id = ids[index]
            if id != currentId, unread.contains(id) { return id }
        }
        return nil
    }

    /// The room open in the main window. Its unreads clear locally the moment it's
    /// selected and stay cleared while it's on screen — waiting for the server echo
    /// makes pips and badges lag or flicker.
    var activeRoomId: String? {
        didSet {
            if let activeRoomId { clearUnreadLocally(roomIds: [activeRoomId]) }
        }
    }

    private let service: MatrixService
    /// FFI rooms, index-aligned with `rooms`. Diffs are positional, so both arrays
    /// mutate in lockstep.
    private var ffiRooms: [Room] = []
    /// Room ID → index into `rooms`/`ffiRooms`, rebuilt after every diff batch so
    /// lookups skip O(n) scans.
    private var roomIndexById: [String: Int] = [:]
    /// Bridges/controllers/TaskHandles that must stay alive for subscriptions to fire.
    private var retained: [Any] = []
    private var streamTasks: [Task<Void, Never>] = []
    private var spaceService: SpaceService?
    /// Retains the SpaceRoomList (and its updates subscription) per visited space.
    private var spaceRoomLists: [String: Any] = [:]

    init(service: MatrixService) {
        self.service = service
    }

    /// Synchronous re-entrancy guard. `retained` isn't populated until after several
    /// awaits, so two callers racing into `start()` at launch would both pass a
    /// `retained`-based check and double-subscribe. Set before the first suspension;
    /// reset on failure so the retry path can run again.
    @ObservationIgnored private var hasStarted = false

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        // Paint the last run's sidebar before sync produces anything; the first
        // diff batch supersedes it.
        await restoreSnapshot()
        do {
            try await service.startSync()
            guard let roomListService = service.roomListService else { return }
            let roomList = try await roomListService.allRooms()

            let entriesBridge = RoomListEntriesBridge()
            let result = roomList.entriesWithDynamicAdapters(pageSize: 200, listener: entriesBridge)
            let controller = result.controller()
            // deduplicateVersions: after a room upgrade, hide the tombstoned room and
            // show only its replacement.
            _ = controller.setFilter(kind: .all(filters: [.nonLeft, .deduplicateVersions]))

            let loadingBridge = RoomListLoadingStateBridge()
            let loadingResult = try roomList.loadingState(listener: loadingBridge)

            retained = [roomList, entriesBridge, result, controller,
                        result.entriesStream(), loadingBridge, loadingResult]

            // `guard let self else break`, not `self?.`: the latter keeps iterating
            // (holding the bridge alive) after the VM is gone.
            streamTasks.append(Task { [weak self] in
                for await diffs in entriesBridge.stream {
                    guard let self else { break }
                    self.apply(diffs)
                }
            })
            streamTasks.append(Task { [weak self] in
                for await state in loadingBridge.stream {
                    guard let self else { break }
                    if case .loaded = state { self.isLoaded = true }
                }
            })
            let syncStates = service.syncStateStream
            streamTasks.append(Task { [weak self] in
                for await state in syncStates {
                    guard let self else { break }
                    let banner: String? = switch state {
                    case .running, .idle, .terminated: nil
                    case .offline: "Offline — reconnecting…"
                    case .error: "Sync error — retrying…"
                    }
                    // Fires on every sync tick — don't republish the same value.
                    if self.syncBanner != banner { self.syncBanner = banner }
                    let reconnecting = banner != nil
                    if self.isReconnecting != reconnecting {
                        self.isReconnecting = reconnecting
                        // Send failures while offline disable the affected rooms'
                        // send queues; re-enable them on reconnect.
                        if !reconnecting {
                            let service = self.service
                            Task { await service.enableAllSendQueues() }
                        }
                    }
                }
            })
            await startSpaces()
        } catch {
            syncBanner = "Failed to start sync: \(error.localizedDescription)"
            // This attempt never established `retained`; let the retry (and any
            // later caller) past the guard.
            hasStarted = false
            // Tracked so stop() can cancel it. Each failed attempt reschedules,
            // making the guard-and-retry a de-facto backoff loop.
            startRetryTask?.cancel()
            startRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.retained.isEmpty else { return }
                await self.start()
            }
        }
    }

    @ObservationIgnored private var startRetryTask: Task<Void, Never>?

    // MARK: Spaces

    private func startSpaces() async {
        let service = await self.service.client.spaceService()
        spaceService = service
        let bridge = JoinedSpacesBridge()
        retained.append(bridge)
        retained.append(await service.subscribeToTopLevelJoinedSpaces(listener: bridge))
        streamTasks.append(Task { [weak self] in
            for await diffs in bridge.stream {
                guard let self else { break }
                self.applySpaceDiffs(diffs)
            }
        })
        spaces = (await service.topLevelJoinedSpaces()).map(Self.spaceItem(from:))
        rebuildOrderedSpaces()
        await refreshAllSpaceChildren()
    }

    // MARK: Rail arrangement

    private var spaceOrderKey: String { "spaceOrder|\(service.userId)" }

    private func rebuildOrderedSpaces() {
        let saved = UserDefaults.standard.stringArray(forKey: spaceOrderKey) ?? []
        guard !saved.isEmpty else {
            if orderedSpaces != spaces { orderedSpaces = spaces }
            return
        }
        let position = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
        let ordered = spaces.enumerated()
            .sorted { a, b in
                let ia = position[a.element.id] ?? (saved.count + a.offset)
                let ib = position[b.element.id] ?? (saved.count + b.offset)
                return ia < ib
            }
            .map(\.element)
        if orderedSpaces != ordered { orderedSpaces = ordered }
    }

    /// Moves a space to just before `targetId` (or the end when nil) and persists
    /// the arrangement per account.
    func moveSpace(id spaceId: String, before targetId: String?) {
        guard spaceId != targetId,
              let from = orderedSpaces.firstIndex(where: { $0.id == spaceId }) else { return }
        var arranged = orderedSpaces
        let item = arranged.remove(at: from)
        if let targetId, let to = arranged.firstIndex(where: { $0.id == targetId }) {
            arranged.insert(item, at: to)
        } else {
            arranged.append(item)
        }
        orderedSpaces = arranged
        UserDefaults.standard.set(arranged.map(\.id), forKey: spaceOrderKey)
    }

    /// Selects a space (nil = Home) and resolves which rooms it contains.
    func selectSpace(_ spaceId: String?) async {
        selectedSpaceId = spaceId
        guard let spaceId else {
            visibleRoomIds = nil
            return
        }
        // Show the cached (or empty) set until the fetch resolves, not the previous
        // space's rooms.
        visibleRoomIds = spaceChildIds[spaceId] ?? []
        let children = await loadSpaceChildren(spaceId: spaceId)
        guard selectedSpaceId == spaceId else { return }
        // A failed load keeps the cached/empty set rather than blanking a
        // snapshot-restored space.
        if let children {
            visibleRoomIds = Set(children.filter { !$0.isSpace }.map(\.id))
        } else {
            visibleRoomIds = spaceChildIds[spaceId] ?? []
        }
    }

    /// Fetches (and caches) the direct children of one space.
    private func loadSpaceChildren(spaceId: String) async -> [SpaceChild]? {
        guard let spaceService else { return nil }
        do {
            let list = try await spaceService.spaceRoomList(spaceId: spaceId)
            spaceRoomLists[spaceId] = list
            // Drive pagination to completion. The list starts out .loading, so wait
            // through that rather than bailing early.
            var guardCounter = 0
            paging: while guardCounter < 200 {
                guardCounter += 1
                switch list.paginationState() {
                case .idle(let endReached):
                    if endReached { break paging }
                    try await list.paginate()
                case .loading:
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let ffiChildren = await list.rooms()
            // The space listing reports plain `room` even for video rooms; the
            // hierarchy endpoint is the only source of the type.
            let hierarchyVideoIds = await service.videoRoomIds(inSpace: spaceId)
            let children = ffiChildren.map {
                SpaceChild(id: $0.roomId,
                           name: $0.displayName,
                           isSpace: $0.roomType == .space,
                           isVideoRoom: RoomSummary.isVideoRoomType($0.roomType)
                               || hierarchyVideoIds.contains($0.roomId),
                           avatarURL: $0.avatarUrl,
                           topic: $0.topic,
                           memberCount: $0.numJoinedMembers,
                           isJoined: $0.state == .joined,
                           via: $0.via)
            }
            // Equality-guarded: these refresh on every space diff, and a no-op write
            // still invalidates every sidebar view.
            let ids = Set(children.map(\.id))
            if spaceChildIds[spaceId] != ids {
                spaceChildIds[spaceId] = ids
                rebuildAllSpaceChildIds()
            }
            if spaceChildren[spaceId] != children { spaceChildren[spaceId] = children }
            // At cold start the restored space can be selected before sync delivers
            // any children; refresh it so it doesn't sit empty until reselected.
            if selectedSpaceId == spaceId {
                let visible = Set(children.filter { !$0.isSpace }.map(\.id))
                if visibleRoomIds != visible { visibleRoomIds = visible }
            }
            let videoIds = Set(children.filter(\.isVideoRoom).map(\.id))
            if !videoIds.isSubset(of: videoRoomIds) {
                videoRoomIds.formUnion(videoIds)
                // Flag already-loaded rows; new ones pick it up in refreshDetails.
                for index in rooms.indices
                where videoRoomIds.contains(rooms[index].id) && !rooms[index].isVideoRoom {
                    rooms[index].isVideoRoom = true
                }
            }
            return children
        } catch {
            return nil
        }
    }

    /// Refreshes every space's child list so Home can exclude them. Deduped: an
    /// in-flight run covers the same ground.
    func refreshAllSpaceChildren() async {
        guard !isRefreshingSpaceChildren else { return }
        isRefreshingSpaceChildren = true
        defer { isRefreshingSpaceChildren = false }
        for space in spaces {
            _ = await loadSpaceChildren(spaceId: space.id)
        }
    }

    @ObservationIgnored private var isRefreshingSpaceChildren = false
    @ObservationIgnored private var spaceRefreshTask: Task<Void, Never>?

    /// Space diffs arrive in bursts and each refresh is a full crawl (a round-trip
    /// per space), so coalesce to one trailing run ~2s after the last diff.
    private func scheduleSpaceChildrenRefresh() {
        spaceRefreshTask?.cancel()
        spaceRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refreshAllSpaceChildren()
        }
    }

    func toggleRoom(_ roomId: String, inSpace spaceId: String) async {
        if spaceChildIds[spaceId]?.contains(roomId) == true {
            guard let spaceService else { return }
            do {
                try await spaceService.removeChildFromSpace(childId: roomId, spaceId: spaceId)
                spaceChildIds[spaceId]?.remove(roomId)
                rebuildAllSpaceChildIds()
                if selectedSpaceId == spaceId {
                    visibleRoomIds = spaceChildIds[spaceId]
                }
            } catch {
                // Likely missing power level; leave state unchanged but say so.
                reportActionError(String(localized: "Couldn't remove from space: \(error.localizedDescription)"))
            }
        } else {
            await fileRoom(roomId, intoSpace: spaceId)
        }
    }

    /// Files a room into a space. Retries because a just-created room takes a sync
    /// round-trip to exist locally, and filing before that throws.
    func fileRoom(_ roomId: String, intoSpace spaceId: String) async {
        guard let spaceService else { return }
        for attempt in 0..<10 {
            do {
                try await spaceService.addChildToSpace(childId: roomId, spaceId: spaceId)
                spaceChildIds[spaceId, default: []].insert(roomId)
                rebuildAllSpaceChildIds()
                if selectedSpaceId == spaceId {
                    await selectSpace(spaceId)
                }
                return
            } catch {
                if attempt == 9 {
                    reportActionError(String(localized: "Couldn't add to space: \(error.localizedDescription)"))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func applySpaceDiffs(_ diffs: [SpaceListUpdate]) {
        for diff in diffs {
            switch diff {
            case .append(let values):
                spaces.append(contentsOf: values.map(Self.spaceItem(from:)))
            case .clear:
                spaces.removeAll()
            case .pushFront(let value):
                spaces.insert(Self.spaceItem(from: value), at: 0)
            case .pushBack(let value):
                spaces.append(Self.spaceItem(from: value))
            case .popFront:
                if !spaces.isEmpty { spaces.removeFirst() }
            case .popBack:
                if !spaces.isEmpty { spaces.removeLast() }
            case .insert(let index, let value):
                spaces.insert(Self.spaceItem(from: value), at: min(Int(index), spaces.count))
            case .set(let index, let value):
                if spaces.indices.contains(Int(index)) { spaces[Int(index)] = Self.spaceItem(from: value) }
            case .remove(let index):
                if spaces.indices.contains(Int(index)) { spaces.remove(at: Int(index)) }
            case .truncate(let length):
                if spaces.count > Int(length) { spaces.removeSubrange(Int(length)...) }
            case .reset(let values):
                spaces = values.map(Self.spaceItem(from:))
            }
        }
        rebuildOrderedSpaces()
        if let selectedSpaceId, !spaces.contains(where: { $0.id == selectedSpaceId }) {
            Task { await selectSpace(nil) }
        }
        scheduleSpaceChildrenRefresh()
    }

    private static func spaceItem(from room: SpaceRoom) -> SpaceItem {
        SpaceItem(id: room.roomId, name: room.displayName, avatarURL: room.avatarUrl,
                  topic: room.topic)
    }

    /// The space banner mxc (Commet's `page.codeberg.everypizza.room.banner`
    /// state event), fetched lazily when a space is opened.
    func spaceBannerURL(forSpace spaceId: String) async -> String? {
        let content = await service.stateEventContent(
            roomId: spaceId, type: "page.codeberg.everypizza.room.banner")
        return content?["url"] as? String
    }

    func stop() {
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        retained = []
        hasStarted = false
        previewSubscribedRoomIds = []
        invitableRoomIds = []
        invitePermissionChecked = []
        manageableSpaceIds = []
        spaceManageChecked = []
        moveableRoomIds = []
        movePermissionChecked = []
        spaceRefreshTask?.cancel()
        spaceRefreshTask = nil
        startRetryTask?.cancel()
        startRetryTask = nil
        actionErrorTask?.cancel()
        actionErrorTask = nil
        // Logout deletes the snapshot right after stopping — a pending debounced
        // write must not fire afterward.
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    func ffiRoom(withId id: String) -> Room? {
        guard let index = roomIndexById[id], ffiRooms.indices.contains(index) else { return nil }
        return ffiRooms[index]
    }

    private func rebuildRoomIndex() {
        // First occurrence wins, matching the firstIndex(where:) it replaces.
        roomIndexById = Dictionary(rooms.enumerated().map { ($1.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: Diff application

    private func apply(_ diffs: [RoomListEntriesUpdate]) {
        // Snapshot placeholders have no FFI backing, so positional diffs can't apply
        // to them. A leading .reset replaces the array wholesale (and carries
        // restored summaries into the fresh rows); anything else must start from an
        // empty baseline, or `rooms` and `ffiRooms` diverge.
        if isShowingRestoredSnapshot {
            isShowingRestoredSnapshot = false
            if case .some(.reset) = diffs.first {} else {
                rooms.removeAll()
                rebuildRoomIndex()
            }
        }
        for diff in diffs {
            switch diff {
            case .append(let values):
                values.forEach { add($0, at: rooms.count) }
            case .clear:
                ffiRooms.removeAll()
                rooms.removeAll()
            case .pushFront(let value):
                add(value, at: 0)
            case .pushBack(let value):
                add(value, at: rooms.count)
            case .popFront:
                guard !rooms.isEmpty, !ffiRooms.isEmpty else { break }
                ffiRooms.removeFirst()
                rooms.removeFirst()
            case .popBack:
                guard !rooms.isEmpty, !ffiRooms.isEmpty else { break }
                ffiRooms.removeLast()
                rooms.removeLast()
            case .insert(let index, let value):
                add(value, at: Int(index))
            case .set(let index, let value):
                let i = Int(index)
                // Both arrays are checked: a restored snapshot fills `rooms` but
                // not `ffiRooms`, so during that window they can differ in length
                // and an ffiRooms[i] on a rooms-valid index would crash.
                guard rooms.indices.contains(i), ffiRooms.indices.contains(i) else { break }
                ffiRooms[i] = value
                // Same room: keep the populated summary. Resetting to basics blanks
                // unreads/preview for a beat, flickering and re-sorting the row.
                if rooms[i].id != value.id() {
                    rooms[i] = RoomSummary(basicsOf: value)
                }
                refreshDetails(of: value)
            case .remove(let index):
                let i = Int(index)
                guard rooms.indices.contains(i), ffiRooms.indices.contains(i) else { break }
                ffiRooms.remove(at: i)
                rooms.remove(at: i)
            case .truncate(let length):
                let l = Int(length)
                guard rooms.count > l, ffiRooms.count >= l else { break }
                ffiRooms.removeSubrange(l...)
                rooms.removeSubrange(l...)
            case .reset(let values):
                // Carry known summaries over so the list doesn't blank and reshuffle
                // while details reload.
                let known = Dictionary(rooms.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
                ffiRooms = values
                rooms = values.map { known[$0.id()] ?? RoomSummary(basicsOf: $0) }
                values.forEach(refreshDetails(of:))
            }
        }
        rebuildRoomIndex()
        updateDockBadge()
        recomputeUnreadFlags()
        subscribeForPreviews()
        scheduleSnapshotWrite()
    }

    /// Rooms already handed to `subscribeToRooms`, so each is subscribed once.
    @ObservationIgnored private var previewSubscribedRoomIds: Set<String> = []

    /// Subscribes every room to sliding sync so the server delivers each room's
    /// latest event. Without this, `room.latestEvent()` stays empty until a room's
    /// timeline is opened, so the sidebar shows no preview for unvisited rooms. Each
    /// subscription makes the SDK emit a `.set` that `refreshDetails` turns into the
    /// preview. Only newly-seen rooms are sent.
    private func subscribeForPreviews() {
        // Previews now come from the room-list sync's own timeline limit
        // (`withRoomListTimelineLimit`), so we no longer blanket-subscribe every
        // room. Subscribing hundreds of rooms produced a huge per-sync request
        // and suppressed the live receipts/typing extensions (which only stream
        // for subscribed rooms). Only the open room is subscribed now (by the
        // timeline), which keeps those ephemeral updates flowing.
    }

    /// Rooms and spaces the current user may invite to. Filled lazily by the
    /// sidebar as rows/menus appear — power levels are async, but context menus
    /// build synchronously. Fail closed: a room stays absent until confirmed.
    private(set) var invitableRoomIds: Set<String> = []
    @ObservationIgnored private var invitePermissionChecked: Set<String> = []

    func refreshInvitePermission(forRoomId roomId: String) async {
        guard !invitePermissionChecked.contains(roomId) else { return }
        invitePermissionChecked.insert(roomId)
        let room = ffiRoom(withId: roomId) ?? (try? service.client.getRoom(roomId: roomId)) ?? nil
        guard let room, let levels = try? await room.getPowerLevels() else {
            // A cancelled row `.task` (fast fling) must not poison the
            // fail-closed cache for the rest of the session.
            if Task.isCancelled { invitePermissionChecked.remove(roomId) }
            return
        }
        if levels.canOwnUserInvite() { invitableRoomIds.insert(roomId) }
    }

    /// Spaces whose child list this user may edit (send `m.space.child`) — i.e.
    /// spaces a room can actually be moved in/out of. Filled lazily like
    /// `invitableRoomIds`; a space stays absent until confirmed (fail closed), so
    /// the Spaces menu only offers spaces the move would actually succeed in.
    private(set) var manageableSpaceIds: Set<String> = []
    @ObservationIgnored private var spaceManageChecked: Set<String> = []

    func refreshSpaceManagePermission(spaceId: String) async {
        guard !spaceManageChecked.contains(spaceId) else { return }
        spaceManageChecked.insert(spaceId)
        let room = ffiRoom(withId: spaceId) ?? (try? service.client.getRoom(roomId: spaceId)) ?? nil
        guard let room, let levels = try? await room.getPowerLevels() else {
            if Task.isCancelled { spaceManageChecked.remove(spaceId) }
            return
        }
        if levels.canOwnUserSendState(stateEvent: .spaceChild) {
            manageableSpaceIds.insert(spaceId)
        }
    }

    /// Rooms this user may move into/out of a space at all — filing a room sets
    /// `m.space.parent` in the room, so it needs power in the *room*, not just
    /// the space. Without it the Spaces menu is hidden (fail closed) rather than
    /// offering a move that would fail on a room you don't administer.
    private(set) var moveableRoomIds: Set<String> = []
    @ObservationIgnored private var movePermissionChecked: Set<String> = []

    func refreshMovePermission(forRoomId roomId: String) async {
        guard !movePermissionChecked.contains(roomId) else { return }
        movePermissionChecked.insert(roomId)
        let room = ffiRoom(withId: roomId) ?? (try? service.client.getRoom(roomId: roomId)) ?? nil
        guard let room, let levels = try? await room.getPowerLevels() else {
            if Task.isCancelled { movePermissionChecked.remove(roomId) }
            return
        }
        if levels.canOwnUserSendState(stateEvent: .spaceParent) {
            moveableRoomIds.insert(roomId)
        }
    }

    private func add(_ room: Room, at index: Int) {
        let i = min(max(index, 0), rooms.count)
        // Clamp each array to its own count: a restored snapshot leaves `ffiRooms`
        // shorter than `rooms`, and inserting past ffiRooms.count would crash.
        ffiRooms.insert(room, at: min(i, ffiRooms.count))
        rooms.insert(RoomSummary(basicsOf: room), at: i)
        refreshDetails(of: room)
    }

    /// Fills in the async parts of a summary (unreads, last message) and queues it
    /// for a batched write by room ID, since the row may have moved by then.
    private func refreshDetails(of room: Room) {
        Task { [weak self] in
            let info = try? await room.roomInfo()
            let latest = await room.latestEvent()
            let id = room.id()
            guard let self, let index = roomIndexById[id],
                  rooms.indices.contains(index) else { return }
            var summary = pendingSummaries[id] ?? rooms[index]
            if let info { summary.update(from: info) }
            summary.update(from: latest)
            summary.isVideoRoom = videoRoomIds.contains(summary.id)
            if summary.isInvited, summary.inviterName == nil,
               let inviter = try? await room.inviter() {
                summary.inviterName = inviter.displayName ?? inviter.userId
            }
            // The room on screen stays read: the server echo would re-light the pip
            // for a beat between a new message and the timeline receipting it.
            if summary.id == activeRoomId, Platform.isAppActive {
                summary.unreadMessages = 0
                summary.unreadNotifications = 0
                summary.unreadMentions = 0
                summary.isMarkedUnread = false
            }
            enqueue(summary)
        }
    }

    // MARK: Batched summary publication

    /// Refreshed summaries awaiting a single batched write into `rooms`. Publishing
    /// them one at a time re-rendered the whole sidebar once per room.
    private var pendingSummaries: [String: RoomSummary] = [:]
    private var flushTask: Task<Void, Never>?

    private func enqueue(_ summary: RoomSummary) {
        // Only queue real changes: every flush invalidates the whole sidebar, and
        // busy rooms refresh constantly — the churn was rebuilding views mid-click
        // and swallowing header-menu presses.
        if pendingSummaries[summary.id] == nil,
           let index = roomIndexById[summary.id], rooms.indices.contains(index),
           rooms[index] == summary {
            return
        }
        pendingSummaries[summary.id] = summary
        guard flushTask == nil else { return }
        // One drain task per burst: flush ~every 100ms while work exists.
        flushTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                flushPendingSummaries()
                if pendingSummaries.isEmpty {
                    flushTask = nil
                    return
                }
            }
        }
    }

    /// Applies every pending summary in one `rooms` mutation. Indexes are re-resolved
    /// by ID — the row may have moved since the refresh ran.
    private func flushPendingSummaries() {
        guard !pendingSummaries.isEmpty else { return }
        var updated = rooms
        var changed: [RoomSummary] = []
        for (id, summary) in pendingSummaries {
            guard let index = roomIndexById[id], updated.indices.contains(index),
                  updated[index] != summary else { continue }
            updated[index] = summary
            changed.append(summary)
        }
        pendingSummaries.removeAll()
        guard !changed.isEmpty else { return }
        rooms = updated
        updateDockBadge()
        recomputeUnreadFlags()
        scheduleSnapshotWrite()
        #if os(iOS)
        persistSpaceNamesForPush()
        #endif
        // Respect this account's per-account notification toggle. (Calls still
        // ring in-app; only banners are gated.)
        let notify = Preferences.shared.notificationsEnabled(forUserId: service.userId)
        for summary in changed {
            let avatarURL = notificationAvatarURL(for: summary)
            if notify {
                NotificationManager.shared.maybeNotify(room: summary,
                                                       spaceName: spaceName(ofRoom: summary.id),
                                                       avatarURL: avatarURL,
                                                       accountUserId: service.userId)
                NotificationManager.shared.maybeNotifyInvite(room: summary, avatarURL: avatarURL,
                                                             accountUserId: service.userId)
            }
            NotificationManager.shared.maybeNotifyCall(room: summary, avatarURL: avatarURL,
                                                       accountUserId: service.userId)
        }
    }

    /// The first space containing this room, for notification titles/avatars.
    func space(ofRoom roomId: String) -> SpaceItem? {
        guard let spaceId = spaceChildIds.first(where: { $0.value.contains(roomId) })?.key
        else { return nil }
        return spaces.first { $0.id == spaceId }
    }

    /// The first space containing this room, for notification titles.
    func spaceName(ofRoom roomId: String) -> String? {
        space(ofRoom: roomId)?.name
    }

    /// Avatar to show on a room's notification: a DM shows the other person, a
    /// room inside a space shows the space, a plain room shows the room itself.
    func notificationAvatarURL(for room: RoomSummary) -> String? {
        if room.isDirect { return room.avatarURL }
        if let spaceAvatar = space(ofRoom: room.id)?.avatarURL { return spaceAvatar }
        return room.avatarURL
    }

    #if os(iOS)
    /// Mirror the room→space names to the App Group so the notification service
    /// extension can title pushes "Space › Room" (it can't resolve the space
    /// hierarchy cheaply itself). No-op unless remote push is on.
    private func persistSpaceNamesForPush() {
        guard PushConfig.enabled else { return }
        var names: [String: String] = [:]
        var avatars: [String: String] = [:]
        for (spaceId, childIds) in spaceChildIds {
            guard let space = spaces.first(where: { $0.id == spaceId }) else { continue }
            for roomId in childIds where names[roomId] == nil {
                names[roomId] = space.name
                if let avatar = space.avatarURL { avatars[roomId] = avatar }
            }
        }
        SpaceNameStore.save(names)
        SpaceNameStore.saveAvatars(avatars)

        // The exact avatar each room's push should show (DM → other person,
        // room-in-space → space, else the room). The NSE reads this rather than
        // the push item's own (often-empty) avatar fields.
        var roomAvatars: [String: String] = [:]
        for room in rooms {
            if let mxc = notificationAvatarURL(for: room) { roomAvatars[room.id] = mxc }
        }
        SpaceNameStore.saveRoomAvatars(roomAvatars)
    }
    #endif

    /// Zeroes the local unread state so pips, badges, and banners react immediately
    /// instead of after the server round-trip.
    private func clearUnreadLocally(roomIds: [String]) {
        for id in roomIds {
            if let index = roomIndexById[id], rooms.indices.contains(index) {
                rooms[index].unreadMessages = 0
                rooms[index].unreadNotifications = 0
                rooms[index].unreadMentions = 0
                rooms[index].isMarkedUnread = false
            }
            // A refresh queued before the clear must not re-light the pip on flush.
            if pendingSummaries[id] != nil {
                pendingSummaries[id]?.unreadMessages = 0
                pendingSummaries[id]?.unreadNotifications = 0
                pendingSummaries[id]?.unreadMentions = 0
                pendingSummaries[id]?.isMarkedUnread = false
            }
        }
        // One batched fetch, not one per room — Mark All as Read clears dozens.
        NotificationManager.shared.clearDelivered(roomIds: Set(roomIds))
        updateDockBadge()
        // The direct `rooms` mutation above bypasses the flush, so clear the rail
        // pips now rather than on the next batched publish.
        recomputeUnreadFlags()
    }

    /// Sends read receipts and clears unread flags for the given rooms.
    func markRead(roomIds: [String]) {
        clearUnreadLocally(roomIds: roomIds)
        Task {
            for id in roomIds {
                guard let room = ffiRoom(withId: id) else { continue }
                try? await room.markAsRead(receiptType: .read)
                try? await room.setUnreadFlag(newValue: false)
            }
        }
    }

    /// Every room filed in the space, for Mark All as Read.
    func childRoomIds(of spaceId: String) -> [String] {
        Array(spaceChildIds[spaceId] ?? [])
    }

    /// Everything visible on Home: DMs plus unfiled rooms.
    var homeRoomIds: [String] {
        let filed = allSpaceChildIds
        return rooms.filter { !$0.isSpace && ($0.isDirect || !filed.contains($0.id)) }.map(\.id)
    }

    /// Records a room known to be a video room before any space listing says so
    /// (e.g. one just created here).
    func noteVideoRoom(_ roomId: String) {
        videoRoomIds.insert(roomId)
        if let index = roomIndexById[roomId], rooms.indices.contains(index) {
            rooms[index].isVideoRoom = true
        }
        pendingSummaries[roomId]?.isVideoRoom = true
    }

    /// Joins a room discovered in a space's listing; the diff stream adds the row
    /// once sync delivers it.
    func joinSpaceChild(_ child: SpaceChild) async {
        guard !joiningRoomIds.contains(child.id) else { return }
        joiningRoomIds.insert(child.id)
        defer { joiningRoomIds.remove(child.id) }
        do {
            _ = try await service.client.joinRoomByIdOrAlias(roomIdOrAlias: child.id,
                                                            serverNames: child.via)
            // Reload so the row moves from "join" to joined.
            if let spaceId = selectedSpaceId {
                let children = await loadSpaceChildren(spaceId: spaceId)
                if selectedSpaceId == spaceId, let children {
                    visibleRoomIds = Set(children.filter { !$0.isSpace }.map(\.id))
                }
            }
        } catch {
            reportActionError(String(localized: "Couldn't join \(child.name): \(error.localizedDescription)"))
        }
    }

    /// The diff stream flips the row to joined.
    func acceptInvite(roomId: String) async {
        guard let room = ffiRoom(withId: roomId) else { return }
        guard !joiningInviteIds.contains(roomId) else { return }
        joiningInviteIds.insert(roomId)
        defer { joiningInviteIds.remove(roomId) }
        do {
            try await room.join()
        } catch {
            let name = roomIndexById[roomId].map { rooms[$0].name } ?? roomId
            reportActionError(String(localized: "Couldn't accept the invite to \(name): \(error.localizedDescription)"))
        }
    }

    /// This account's unread-notification total. AppState owns the app badge and
    /// sums every warm scope's total, so this must stay per-scope.
    private(set) var unreadTotal = 0
    /// Set by AppState; fires whenever `unreadTotal` changes.
    @ObservationIgnored var onUnreadTotalChanged: (() -> Void)?

    private func updateDockBadge() {
        // Muted rooms contribute only real mentions.
        let total = rooms.reduce(0) { $0 + Int($1.badgeCount) }
        guard total != unreadTotal else { return }
        unreadTotal = total
        onUnreadTotalChanged?()
    }

    // MARK: Cold-launch snapshot

    /// True while `rooms` holds disk-restored rows with no FFI backing. Cleared by
    /// the first diff batch, which replaces them wholesale.
    private var isShowingRestoredSnapshot = false
    /// Trailing-debounced snapshot writer.
    private var snapshotTask: Task<Void, Never>?

    /// Application Support/<account>/roomlist-snapshot.json, keyed by the
    /// filesystem-sanitized Matrix user ID.
    nonisolated static func snapshotURL(forUserId userId: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first
        else { return nil }
        let safe = String(userId.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return support.appending(path: "\(safe)/roomlist-snapshot.json", directoryHint: .notDirectory)
    }

    /// Deletes an account's snapshot and its per-account directory, which holds
    /// nothing else (SDK stores live under Sessions/).
    nonisolated static func removeSnapshot(forUserId userId: String) {
        guard let url = snapshotURL(forUserId: userId) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Set by the owning scope: bulk-loads disk-cached avatar thumbnails into memory
    /// so the restored sidebar's first frame has them.
    @ObservationIgnored var prewarmAvatars: (([String]) async -> Void)?

    /// Paints the cached sidebar before the window mounts, so the first `MainWindow`
    /// frame shows chats instead of an empty list. Idempotent — `restoreSnapshot`
    /// guards on `rooms.isEmpty`, so the later `start()` call is a no-op.
    func primeSnapshotForLaunch() async {
        await restoreSnapshot()
    }

    private func restoreSnapshot() async {
        guard rooms.isEmpty,
              let url = Self.snapshotURL(forUserId: service.userId),
              let snapshot = await Self.readSnapshot(at: url),
              rooms.isEmpty, !snapshot.rooms.isEmpty
        else { return }
        // Paint the rows now; don't block the first frame on avatar disk I/O. Avatars
        // warm in the background (their per-row async load also covers them).
        isShowingRestoredSnapshot = true
        rooms = snapshot.rooms
        if spaces.isEmpty {
            spaces = snapshot.spaces.map { SpaceItem(id: $0.id, name: $0.name, avatarURL: $0.avatarURL) }
            rebuildOrderedSpaces()
        }
        if spaceChildIds.isEmpty {
            spaceChildIds = snapshot.spaceChildIds
            rebuildAllSpaceChildIds()
        }
        rebuildRoomIndex()
        recomputeUnreadFlags()
        let avatarURLs = (snapshot.rooms.compactMap(\.avatarURL)
                          + snapshot.spaces.compactMap(\.avatarURL))
        if !avatarURLs.isEmpty {
            Task { await prewarmAvatars?(avatarURLs) }
        }
    }

    /// When the last write was kicked off; caps latency under continuous churn,
    /// which the trailing debounce alone would starve.
    private var lastSnapshotWriteAt = Date()

    /// Persists the sidebar ~2s (trailing) after it last changed, capped at 30s under
    /// continuous churn. Skipped while showing restored rows — they came from this file.
    private func scheduleSnapshotWrite() {
        guard !isShowingRestoredSnapshot else { return }
        if Date().timeIntervalSince(lastSnapshotWriteAt) > 30 {
            snapshotTask?.cancel()
            snapshotTask = nil
            writeSnapshot()
            return
        }
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot()
        }
    }

    private func writeSnapshot() {
        guard let url = Self.snapshotURL(forUserId: service.userId) else { return }
        lastSnapshotWriteAt = Date()
        let snapshot = RoomListSnapshot(
            rooms: rooms,
            spaces: spaces.map { RoomListSnapshot.Space(id: $0.id, name: $0.name, avatarURL: $0.avatarURL) },
            spaceChildIds: spaceChildIds)
        // Build the Codable value on-main; encode (the part that scales with sidebar
        // size) and write off-main.
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            Self.writeSnapshotData(data, to: url)
        }
    }

    /// Reads and decodes off-main; only the decoded value hops actors.
    nonisolated private static func readSnapshot(at url: URL) async -> RoomListSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RoomListSnapshot.self, from: data)
    }

    nonisolated private static func writeSnapshotData(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        #if os(macOS)
        let options: Data.WritingOptions = [.atomic]
        #else
        // Preview lines of encrypted rooms are plaintext metadata; keep them
        // protected until first unlock.
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
        guard (try? data.write(to: url, options: options)) != nil else { return }
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
}

/// On-disk shape of the sidebar snapshot. File-scoped so no main-actor inference
/// reaches its Codable synthesis. Holds only state RoomSummary already has, never
/// decrypted timeline content.
private struct RoomListSnapshot: Codable {
    struct Space: Codable {
        var id: String
        var name: String
        var avatarURL: String?
    }

    var rooms: [RoomSummary]
    var spaces: [Space]
    var spaceChildIds: [String: Set<String>]
}
