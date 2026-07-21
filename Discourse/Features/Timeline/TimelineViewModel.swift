#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreLocation
import Foundation
import ImageIO
import Observation
import os
import UniformTypeIdentifiers
@preconcurrency import MatrixRustSDK

/// Owns one room's live timeline: applies SDK diffs to `entries`, recomputes
/// sender grouping, and drives back-pagination.
@MainActor
@Observable
final class TimelineViewModel {
    enum Mode: Equatable {
        case live
        case thread(rootEventId: String)
        /// Backs the Media tab of the details column.
        case media
    }

    let mode: Mode
    let roomId: String
    private(set) var roomName: String
    private(set) var topic: String?
    private(set) var entries: [TimelineEntry] = []
    private(set) var reachedStart = false
    private(set) var isPaginating = false
    private(set) var error: String?
    /// Set by the view's scroll observer; gates autoscroll and read receipts.
    /// True only when the newest message is on screen, not merely prefetched
    /// into the LazyVStack ahead.
    var isAtBottom = true
    /// SDK read-marker entry ("NEW" divider), if in the loaded window. Cached
    /// per diff batch so jump-to-unread doesn't rescan `entries` per frame.
    private(set) var firstUnreadMarkerId: String?
    /// Whether the "jump to unread" pill should show. A marker auto-dismisses a
    /// few seconds after it appears (you've seen it), stays dismissed across a
    /// park/unpark room switch (this VM is cached), and re-arms only for a
    /// genuinely different marker.
    private(set) var unreadMarkerVisible = false
    @ObservationIgnored private var dismissedMarkerId: String?
    @ObservationIgnored private var unreadDismissTask: Task<Void, Never>?
    /// Per-room composer draft, retained here so switching rooms (which tears
    /// down the composer) doesn't lose half-typed text.
    @ObservationIgnored var draftText = ""
    let audioPlayback = AudioPlaybackController()
    var replyTarget: MessageItem?
    var editTarget: MessageItem?
    private(set) var pendingAttachments: [PendingAttachment] = []

    struct PendingAttachment: Identifiable, Hashable {
        let id = UUID()
        var filename: String
        var data: Data
        var previewImage: PlatformImage?
        /// Bytes still loading off-main; excluded from sends until the read lands.
        var isLoading = false
        /// Last upload failed; the chip is back in the composer for retry.
        var uploadFailed = false
    }

    /// Transient composer failure line; auto-clears after a few seconds.
    private(set) var composerError: String?
    @ObservationIgnored private var composerErrorTask: Task<Void, Never>?

    private func presentComposerError(_ text: String) {
        composerError = text
        composerErrorTask?.cancel()
        composerErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.composerError = nil
        }
    }

    /// Messages accepted before `start()` had a timeline; the composer clears
    /// optimistically, so these are flushed in order once it exists.
    private enum QueuedOutbound {
        case text(String)
        case attachment(PendingAttachment, inReplyTo: String?)
    }
    @ObservationIgnored private var outboundQueue: [QueuedOutbound] = []
    private(set) var typingUsers: [String] = []
    private(set) var hasActiveCall = false
    /// The room is a standing call. Set by the creating scope from
    /// space-listing data — `RoomInfo` doesn't carry the `m.room.create` type.
    var isVideoRoom = false

    /// Rows in the lazy viewport, reported by the view. Lives here (not view
    /// @State) so the anchor can be read at room-switch time, before teardown
    /// drains the row callbacks.
    @ObservationIgnored var visibleEntryIds: Set<String> = []
    /// True while the phone keeps this timeline mounted offscreen behind the
    /// room list. The bottom sentinel still counts as "visible" there, so
    /// receipt-sending must be gated or parked chats silently read messages.
    /// Parking also sheds memory (see `parkTimeline`).
    @ObservationIgnored var isParked = false {
        didSet {
            guard isParked != oldValue else { return }
            if isParked { parkTimeline() } else { unparkTimeline() }
        }
    }

    /// Set when parking detached the diff listener; the unpark re-attach clears it.
    @ObservationIgnored private var parkedListenerDetached = false

    /// Bottom-most visible event captured on park, so after unpark's full
    /// `.reset` re-delivers the timeline the view can land back where it was
    /// instead of drifting up.
    @ObservationIgnored private var pendingUnparkAnchor: String?
    /// The view scrolls here (then clears it) once unpark rebuilds the entries.
    private(set) var unparkScrollTarget: String?
    func clearUnparkScrollTarget() { unparkScrollTarget = nil }

    /// Sheds a parked room's memory: entry models beyond the viewport anchor,
    /// and the member list (reloaded on unpark). The listener is detached
    /// first — positional diffs can't apply to a truncated array; the unpark
    /// re-attach delivers a fresh reset with the full item list instead.
    private func parkTimeline() {
        guard mode == .live, timeline != nil else { return }
        pendingUnparkAnchor = scrollAnchorEventId
        audioPlayback.stopAll()
        streamTask?.cancel()
        streamTask = nil
        ephemeralSyncTask?.cancel()
        ephemeralSyncTask = nil
        timelineListenerRetained = []
        parkedListenerDetached = true
        // Keep the scroll anchor's row plus a tail of recent context.
        let keepTail = 200
        var start = max(0, entries.count - keepTail)
        if let anchor = scrollAnchorEventId {
            let anchorIndex = entries.firstIndex {
                if case .message(let m) = $0 { return m.eventId == anchor }
                return false
            }
            if let anchorIndex { start = min(start, anchorIndex) }
        }
        if start > 0 {
            entries.removeFirst(start)
            // Pagination refills the dropped history after the unpark resync.
            reachedStart = false
        }
        members = []
        membersById = [:]
    }

    /// Re-attaches the diff listener (initial reset restores the full list)
    /// and reloads members. The phone keeps the parked view mounted, so the
    /// view's `.task` never refires — reload here; `members.isEmpty` keeps the
    /// two callers from doubling up.
    private func unparkTimeline() {
        let needsResync = parkedListenerDetached
        parkedListenerDetached = false
        guard needsResync, let timeline else { return }
        Task { [weak self] in
            guard let self else { return }
            // A rapid unpark→park can schedule this and re-park before it
            // runs; attaching then defeats the memory shed and leaks the
            // replaced stream task on the next unpark.
            guard !self.isParked else {
                self.parkedListenerDetached = true
                return
            }
            await self.attachTimelineListener(timeline)
            if self.members.isEmpty { await self.loadMembers() }
        }
    }

    /// Scroll-memory anchor: the bottom-most visible event, nil when at bottom.
    var scrollAnchorEventId: String? {
        guard !isAtBottom else { return nil }
        return entries.last { visibleEntryIds.contains($0.id) }.flatMap { entry in
            if case .message(let m) = entry { return m.eventId }
            return nil
        }
    }
    private(set) var isEncrypted = false
    private(set) var isDirect = false
    private(set) var avatarURL: String?
    private(set) var memberCount: UInt64 = 0
    private(set) var members: [MemberItem] = []
    /// Members keyed by user ID; rows resolve names/avatars per receipt and
    /// reaction, which linear scans made O(members) each.
    private(set) var membersById: [String: MemberItem] = [:]

    /// Per-event crypto shields, fetched lazily as rows appear — computing
    /// them during diff mapping forced eager crypto work for every item.
    private(set) var shields: [String: MessageItem.ShieldWarning] = [:]
    @ObservationIgnored private var shieldsRequested: Set<String> = []

    /// Fetches a row's shield once per event; the row reads the result back
    /// from `shields`. `.set` diffs re-arm the fetch (see `apply`).
    func loadShieldIfNeeded(for message: MessageItem) {
        guard let eventId = message.eventId,
              let provider = message.shieldProvider,
              !shieldsRequested.contains(eventId) else { return }
        shieldsRequested.insert(eventId)
        Task.detached(priority: .utility) { [weak self] in
            let warning = provider.warning()
            await self?.storeShield(warning, for: eventId)
        }
    }

    private func storeShield(_ warning: MessageItem.ShieldWarning?, for eventId: String) {
        guard shields[eventId] != warning else { return }
        shields[eventId] = warning
    }

    /// The other participant in a 1:1 chat, for presence.
    var dmPeerId: String? {
        guard isDirect else { return nil }
        return members.first { $0.id != ownUserId }?.id
    }

    /// Newest own message, but only while nobody has read past it: a receipt
    /// on any later row means this one was read too, so the "sent" tick would
    /// contradict it. Recomputed per diff batch so per-row reads don't rescan.
    private(set) var lastOwnMessageId: String?

    private func updateLastOwnMessageId() {
        // Assigned only on change — @Observable fires on same-value writes,
        // and this runs per diff batch.
        var newValue: String?
        for entry in entries.reversed() {
            if case .message(let message) = entry {
                if message.isOwn {
                    newValue = message.id
                    break
                }
                if !message.readReceiptUserIds.isEmpty {
                    break
                }
            }
        }
        if lastOwnMessageId != newValue {
            lastOwnMessageId = newValue
        }
    }

    /// Newest own editable message (own, real event ID, plain text). Backs the
    /// ↑-in-empty-composer shortcut. Computed on demand, not per diff, since
    /// `lastOwnMessageId` can point at non-text messages.
    func lastOwnEditableMessage() -> MessageItem? {
        for entry in entries.reversed() {
            if case .message(let message) = entry, message.isOwn,
               message.eventId != nil, case .text = message.kind {
                return message
            }
        }
        return nil
    }

    struct MemberItem: Identifiable, Hashable {
        enum Role: Int, Comparable {
            case creator, administrator, moderator, member
            static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let id: String
        var displayName: String? {
            didSet { foldedName = RoomSummary.foldedForSearch(name) }
        }
        var avatarURL: String?
        var role: Role = .member
        var powerLevel: Int = 0
        /// `name` case/diacritic-folded for mention-autocomplete matching.
        var foldedName: String = ""
        var name: String { displayName ?? id }

        init(id: String, displayName: String? = nil, avatarURL: String? = nil,
             role: Role = .member, powerLevel: Int = 0) {
            self.id = id
            self.displayName = displayName
            self.avatarURL = avatarURL
            self.role = role
            self.powerLevel = powerLevel
            self.foldedName = RoomSummary.foldedForSearch(displayName ?? id)
        }
    }

    let ownUserId: String
    let mediaLoader: MediaLoader
    /// Custom emoji (MSC2545) for `:shortcode:` conversion and autocomplete.
    /// Nil in previews/tests.
    let customEmoji: CustomEmojiStore?
    private let service: MatrixService?
    private let room: Room
    private var timeline: Timeline?
    private var retained: [Any] = []
    /// The diff listener's bridge + handle, kept apart from `retained` so
    /// parking can detach and re-attach just this listener.
    private var timelineListenerRetained: [Any] = []
    private var streamTask: Task<Void, Never>?
    private var streamTask2: Task<Void, Never>?
    private var typingStreamTask: Task<Void, Never>?
    private var typingStopTask: Task<Void, Never>?
    /// Clears a stale typing indicator if no refresh arrives — the "stopped
    /// typing" update can get lost, leaving the banner stuck.
    private var typingExpiryTask: Task<Void, Never>?
    private var lastTypingNotice: Date?
    /// Debounce state for `markAsRead`; the bottom sentinel fires it on every
    /// appear/disappear flip.
    @ObservationIgnored private var lastMarkedReadEventId: String?
    @ObservationIgnored private var lastMarkedReadAt: Date?

    init(room: Room, ownUserId: String, mediaLoader: MediaLoader,
         service: MatrixService? = nil, customEmoji: CustomEmojiStore? = nil,
         mode: Mode = .live) {
        self.room = room
        self.mode = mode
        self.roomId = room.id()
        self.roomName = room.displayName() ?? room.id()
        self.topic = room.topic()
        self.ownUserId = ownUserId
        self.mediaLoader = mediaLoader
        self.service = service
        self.customEmoji = customEmoji
        TimelineEntry.currentOwnUserId = ownUserId
    }

    /// A view model for the thread rooted at the given event.
    func threadViewModel(rootEventId: String) -> TimelineViewModel {
        TimelineViewModel(room: room, ownUserId: ownUserId, mediaLoader: mediaLoader,
                          service: service, customEmoji: customEmoji,
                          mode: .thread(rootEventId: rootEventId))
    }

    @ObservationIgnored private var mediaVM: TimelineViewModel?

    /// The Media tab's attachment-only timeline, cached so reopening is instant.
    func mediaViewModel() -> TimelineViewModel {
        if let mediaVM { return mediaVM }
        let vm = TimelineViewModel(room: room, ownUserId: ownUserId, mediaLoader: mediaLoader,
                                   service: service, mode: .media)
        mediaVM = vm
        return vm
    }

    /// Own moderation powers, from the room's power levels; gate the kick/ban
    /// menu items on these instead of failing after the fact.
    private(set) var canKick = false
    private(set) var canBan = false
    private(set) var canInvite = false
    /// Redact permissions, checked against the own user id. `canRedactOwn`
    /// gates deleting your own messages; `canRedactOther` lets a moderator
    /// delete anyone's. Read by `MessageRow` per-message.
    private(set) var canRedactOwn = false
    private(set) var canRedactOther = false

    /// Reports a message to the homeserver admins. Returns an error, or nil on success.
    func report(eventId: String, reason: String?) async -> String? {
        do {
            try await room.reportContent(eventId: eventId, reason: reason)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Recomputes the own user's action powers from the room's current power
    /// levels. Fails closed if they can't be fetched.
    private func refreshPermissions() async {
        guard let levels = try? await room.getPowerLevels() else { return }
        canInvite = levels.canOwnUserInvite()
        canKick = levels.canOwnUserKick()
        canBan = levels.canOwnUserBan()
        canRedactOwn = levels.canOwnUserRedactOwn()
        canRedactOther = levels.canOwnUserRedactOther()
    }

    /// Removes a member (kick). Returns an error message on failure.
    func kick(userId: String) async -> String? {
        do {
            try await room.kickUser(userId: userId, reason: nil)
            await loadMembers(force: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Bans a member. Returns an error message on failure.
    func ban(userId: String) async -> String? {
        do {
            try await room.banUser(userId: userId, reason: nil)
            await loadMembers(force: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Paginates back until the given event is in `entries` (search-hit jumps),
    /// bounded so a miss doesn't walk the whole room.
    func ensureLoaded(eventId: String) async -> Bool {
        func isLoaded() -> Bool {
            entries.contains {
                if case .message(let m) = $0 { return m.eventId == eventId }
                return false
            }
        }
        // A fresh mount races start(): pagination no-ops until the timeline
        // exists, burning the attempt budget. Wait for it first.
        var readiness = 0
        while timeline == nil && readiness < 50 {
            readiness += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        var attempts = 0
        while !isLoaded() && !reachedStart && attempts < 30 {
            attempts += 1
            await paginateBackwards()
            // Let the listener stream's diffs apply.
            try? await Task.sleep(for: .milliseconds(80))
        }
        return isLoaded()
    }

    /// A call session for this room (live timelines only); joins the running
    /// call if one exists, otherwise starts one.
    func callViewModel() -> CallViewModel? {
        guard let service else { return nil }
        return CallViewModel(room: room, client: service.client, ownUserId: ownUserId,
                             joinExisting: hasActiveCall)
    }

    func start() async {
        guard timeline == nil else { return }
        // Two callers can overlap (view's .task and a notification reply);
        // both awaiting FFI setup would build two timelines and leak the
        // first listener task.
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    @ObservationIgnored private var startTask: Task<Void, Never>?

    private func performStart() async {
        guard timeline == nil else { return }
        // Sliding sync only streams a room's ephemeral events (receipts,
        // typing) promptly while subscribed; without this they trickle in on
        // unrelated list refreshes instead of live.
        if mode == .live {
            try? await service?.roomListService?.subscribeToRooms(roomIds: [roomId])
            // This room's own emote packs; one state fetch per room per session.
            Task { [customEmoji, roomId, roomName] in
                await customEmoji?.ensureRoomPack(roomId: roomId, roomName: roomName)
            }
        }
        do {
            let focus: TimelineFocus = switch mode {
            case .live, .media: .live(hideThreadedEvents: mode == .live)
            case .thread(let rootEventId): .thread(rootEventId: rootEventId)
            }
            let filter: TimelineFilter = mode == .media
                ? .onlyMessage(types: [.image, .video, .file, .audio, .gallery])
                : .all
            let prefix: String? = switch mode {
            case .live: nil
            case .thread: "thread"
            case .media: "media"
            }
            let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
                focus: focus,
                filter: filter,
                internalIdPrefix: prefix,
                dateDividerMode: .daily,
                trackReadReceipts: mode == .live ? .messageLikeEvents : .disabled,
                reportUtds: false
            ))
            self.timeline = timeline

            retained = []
            await attachTimelineListener(timeline)
            parkedListenerDetached = false
            if mode == .live {
                let typingBridge = TypingNotificationsBridge()
                retained.append(typingBridge)
                retained.append(room.subscribeToTypingNotifications(listener: typingBridge))
                typingStreamTask = Task { [weak self] in
                    for await userIds in typingBridge.stream {
                        guard let self else { break }
                        Logger(subsystem: "dev.discourse.debug", category: "typing")
                            .notice("typing: [\(userIds.joined(separator: ","), privacy: .public)]")
                        let filtered = userIds.filter { $0 != ownUserId }
                        // @Observable fires on same-value writes, and refresh
                        // notices repeat the same list.
                        if typingUsers != filtered {
                            typingUsers = filtered
                        }
                        typingExpiryTask?.cancel()
                        guard !filtered.isEmpty else { continue }
                        // Active typers refresh every few seconds (observed
                        // ≤6s), but a stopped typer stays listed server-side
                        // until their client's ~30s timeout. Expire shortly
                        // after the last refresh to clear them without cutting
                        // off anyone still typing.
                        typingExpiryTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(10))
                            guard !Task.isCancelled else { return }
                            self?.typingUsers = []
                        }
                    }
                }

                let infoBridge = RoomInfoBridge()
                retained.append(infoBridge)
                retained.append(room.subscribeToRoomInfoUpdates(listener: infoBridge))
                streamTask2 = Task { [weak self] in
                    for await info in infoBridge.stream {
                        self?.hasActiveCall = info.hasRoomCall
                        self?.isEncrypted = info.encryptionState == .encrypted
                        self?.roomName = info.displayName ?? info.id
                        self?.topic = info.topic
                        self?.avatarURL = info.avatarUrl
                        self?.memberCount = info.joinedMembersCount
                        // Power levels can change under us; re-gate actions.
                        Task { await self?.refreshPermissions() }
                    }
                }
                if let info = try? await room.roomInfo() {
                    hasActiveCall = info.hasRoomCall
                    isEncrypted = info.encryptionState == .encrypted
                    isDirect = info.isDm || info.isDirect
                    avatarURL = info.avatarUrl
                    memberCount = info.joinedMembersCount
                }
                markAsRead()
            }
            // Redact/invite gating applies in every mode (threads render the
            // same message rows), so compute it outside the live-only block.
            await refreshPermissions()

            await flushOutboundQueue()

            // Kick the first page ourselves: the view's pagination sentinel
            // appears before the timeline exists, so its trigger is lost.
            await paginateBackwards()
        } catch {
            self.error = "Couldn't open timeline: \(error.localizedDescription)"
        }
    }

    /// Subscribes the diff bridge (the SDK replays the item list as an initial
    /// reset). Shared by `start()` and the unpark resync.
    private func attachTimelineListener(_ timeline: Timeline) async {
        // Replacing the listener must also stop the old drain task, or it
        // leaks suspended on a dropped bridge's stream.
        streamTask?.cancel()
        let bridge = TimelineDiffBridge()
        let handle = await timeline.addListener(listener: bridge)
        timelineListenerRetained = [bridge, handle]
        streamTask = Task { [weak self] in
            for await diffs in bridge.stream {
                // Cancellation-only: a batch racing parkTimeline's cancel must
                // not touch the truncated array. isParked is NOT an exit — the
                // phone mounts chats parked behind the list, and breaking here
                // killed the first open's stream for good.
                guard let self, !Task.isCancelled else { break }
                self.apply(diffs)
            }
        }
        startEphemeralSync()
    }

    private func flushOutboundQueue() async {
        while timeline != nil, !outboundQueue.isEmpty {
            switch outboundQueue.removeFirst() {
            case .text(let text): await sendText(text)
            case .attachment(let attachment, let inReplyTo):
                await sendAttachmentData(attachment, inReplyTo: inReplyTo)
            }
        }
    }

    func stop() {
        audioPlayback.stopAll()
        mediaVM?.stop()
        mediaVM = nil
        streamTask?.cancel()
        streamTask = nil
        streamTask2?.cancel()
        streamTask2 = nil
        typingStreamTask?.cancel()
        typingStreamTask = nil
        typingStopTask?.cancel()
        typingStopTask = nil
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
        ephemeralSyncTask?.cancel()
        ephemeralSyncTask = nil
        retained = []
        timelineListenerRetained = []
        parkedListenerDetached = false
        timeline = nil
    }

    // MARK: Sending

    func sendText(_ text: String) async {
        guard let timeline else {
            // Composer already cleared its field; flush in order once start() has a timeline.
            outboundQueue.append(.text(text))
            return
        }
        // Known `:shortcode:` custom emoji go out as MSC2545 HTML; everything
        // else takes the markdown path.
        let content = if let html = customEmoji?.htmlBody(for: text) {
            messageEventContentFromHtml(body: text, htmlBody: html)
        } else {
            messageEventContentFromMarkdown(md: text)
        }
        sendTypingNotice(false)
        if let target = editTarget, let eventId = target.eventId {
            editTarget = nil
            try? await timeline.edit(eventOrTransactionId: .eventId(eventId: eventId),
                                     newContent: .roomMessage(content: content))
        } else if let target = replyTarget, let eventId = target.eventId {
            replyTarget = nil
            try? await timeline.sendReply(msg: content, eventId: eventId)
        } else {
            _ = try? await timeline.send(msg: content)
        }
    }

    // MARK: Attachments (staged, then sent)

    /// Stages a file for sending as a composer preview chip. The chip appears
    /// immediately; the (possibly multi-MB) read happens off-main.
    func stageAttachment(fileURL: URL) {
        var placeholder = PendingAttachment(filename: fileURL.lastPathComponent,
                                            data: Data(), previewImage: nil)
        placeholder.isLoading = true
        pendingAttachments.append(placeholder)
        let id = placeholder.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try? Data(contentsOf: fileURL)
            await self?.finishStaging(id: id, data: data)
        }
    }

    private func finishStaging(id: PendingAttachment.ID, data: Data?) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        guard let data, !data.isEmpty else {
            let filename = pendingAttachments[index].filename
            pendingAttachments.remove(at: index)
            presentComposerError(String(localized: "Couldn't read \(filename)"))
            return
        }
        pendingAttachments[index].data = data
        pendingAttachments[index].isLoading = false
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let thumb = Self.previewThumbnail(from: data) else { return }
            await self?.attachPreview(thumb, to: id)
        }
    }

    func stageAttachment(data: Data, filename: String) {
        var name = filename
        // Raw image data from drags comes nameless; derive one.
        if name.isEmpty || name == "image" {
            let ext = imageType(of: data)?.preferredFilenameExtension ?? "png"
            name = "image.\(ext)"
        }
        let attachment = PendingAttachment(filename: name, data: data, previewImage: nil)
        pendingAttachments.append(attachment)
        // Chip renders at 64pt; decode a small thumbnail off-main.
        let id = attachment.id
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let thumb = Self.previewThumbnail(from: data) else { return }
            await self?.attachPreview(thumb, to: id)
        }
    }

    /// Reads dimensions and mimetype without touching the bytes — the
    /// "don't strip location" path, so GPS EXIF survives. nil if the bytes
    /// can't be read (caller falls back to a file send).
    nonisolated private static func imageAttributes(data: Data) -> MediaProcessing.ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
        else { return nil }
        let mimetype = UTType(typeId as String)?.preferredMIMEType ?? "application/octet-stream"
        return MediaProcessing.ProcessedImage(data: data, mimetype: mimetype,
                                              width: width, height: height)
    }

    nonisolated private static func previewThumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary)
    }

    private func attachPreview(_ cgImage: CGImage, to id: PendingAttachment.ID) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        #if os(macOS)
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        pendingAttachments[index].previewImage = image
    }

    func removeAttachment(_ id: PendingAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    var hasPendingAttachments: Bool { !pendingAttachments.isEmpty }

    /// Sends staged attachments, then the text (if any).
    func sendComposed(text: String) async {
        // Chips still loading stay staged for the next send.
        let staged = pendingAttachments.filter { !$0.isLoading }
        pendingAttachments.removeAll { !$0.isLoading }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timeline != nil else {
            // Not started — queue in composition order. With no text the reply
            // relation rides the first attachment (sendText is skipped).
            var replyEventId: String?
            if message.isEmpty, let target = replyTarget, let eventId = target.eventId {
                replyTarget = nil
                replyEventId = eventId
            }
            var first = true
            for attachment in staged {
                outboundQueue.append(.attachment(attachment, inReplyTo: first ? replyEventId : nil))
                first = false
            }
            if !message.isEmpty { outboundQueue.append(.text(message)) }
            return
        }
        // With no text, attach the reply relation to the first attachment.
        var replyEventId: String?
        if message.isEmpty, let target = replyTarget, let eventId = target.eventId {
            replyTarget = nil
            replyEventId = eventId
        }
        var first = true
        for attachment in staged {
            await sendAttachmentData(attachment, inReplyTo: first ? replyEventId : nil)
            first = false
        }
        if !message.isEmpty {
            await sendText(message)
        }
    }

    /// Kept for external callers (timeline drops); stages for preview.
    func sendAttachment(fileURL: URL) async {
        stageAttachment(fileURL: fileURL)
    }

    private func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(source) else { return nil }
        return UTType(typeId as String)
    }

    /// Whether the filename describes a video (routes to `sendVideo`).
    private func isVideo(data: Data, filename: String) -> Bool {
        if let ut = UTType(filenameExtension: (filename as NSString).pathExtension),
           ut.conforms(to: .movie) || ut.conforms(to: .video) {
            return true
        }
        return false
    }

    private func sendAttachmentData(_ attachment: PendingAttachment, inReplyTo: String? = nil) async {
        guard let timeline else {
            outboundQueue.append(.attachment(attachment, inReplyTo: inReplyTo))
            return
        }
        let data = attachment.data

        // Reject over the homeserver's cap up front, rather than uploading
        // megabytes only to fail.
        if let maxSize = await service?.maxUploadSize(), UInt64(data.count) > maxSize {
            let limitMB = Double(maxSize) / (1024 * 1024)
            presentComposerError(String(localized: "\(attachment.filename) is too large to send (limit \(String(format: "%.0f", limitMB)) MB)."))
            return
        }

        let imageUT = imageType(of: data)
        let type = imageUT ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
        let mimetype = type?.preferredMIMEType
        let params = UploadParameters(
            source: .data(bytes: data, filename: attachment.filename),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: inReplyTo
        )

        // Videos: send as a playable video with a poster frame, falling back
        // to a file send if the asset can't be read.
        if imageUT == nil, isVideo(data: data, filename: attachment.filename) {
            let attrs = await MediaProcessing.videoAttributes(data: data, filename: attachment.filename)
            if let width = attrs.width, let height = attrs.height, width > 0, height > 0 {
                let thumbSource: UploadSource? = attrs.thumbnail.map {
                    .data(bytes: $0.data, filename: "thumbnail.jpg")
                }
                let info = VideoInfo(
                    duration: attrs.duration,
                    height: height,
                    width: width,
                    mimetype: mimetype ?? "video/mp4",
                    size: UInt64(data.count),
                    thumbnailInfo: attrs.thumbnail.map {
                        ThumbnailInfo(height: $0.height, width: $0.width,
                                      mimetype: $0.mimetype, size: UInt64($0.data.count))
                    },
                    thumbnailSource: nil,
                    blurhash: nil
                )
                fputs("SENDDBG sending video \(attachment.filename) \(width)x\(height) \(data.count)B\n", stderr)
                do {
                    let handle = try timeline.sendVideo(params: params,
                                                        thumbnailSource: thumbSource,
                                                        videoInfo: info)
                    try await handle.join()
                    return
                } catch {
                    fputs("SENDDBG video upload failed: \(error)\n", stderr)
                    restageFailedUpload(attachment)
                    return
                }
            }
            // Couldn't read the asset — drop through to a file send.
        }

        // Images: (optionally) strip location metadata, then send with a
        // thumbnail so encrypted-room recipients preview without the full
        // download. When the strip is off, original bytes go out as-is.
        let stripLocation = Preferences.shared.stripLocationMetadata
        if imageUT != nil {
            let processed = await Task.detached(priority: .userInitiated) {
                () -> (data: Data, mimetype: String, width: UInt64, height: UInt64,
                       blurhash: String?, thumbnail: MediaProcessing.Thumbnail?)? in
                let image: MediaProcessing.ProcessedImage? = stripLocation
                    ? MediaProcessing.sanitizedImage(data: data)
                    : Self.imageAttributes(data: data)
                guard let image else { return nil }
                let blurhash = Blurhash.encode(imageData: image.data)
                let thumbnail = MediaProcessing.thumbnail(from: image.data)
                return (image.data, image.mimetype, image.width,
                        image.height, blurhash, thumbnail)
            }.value

            // The SDK requires width+height+size+mimetype AND a blurhash;
            // anything missing throws InvalidAttachmentData. Fall back to a
            // file send if we can't produce them.
            if let processed, processed.width > 0, processed.height > 0,
               let blurhash = processed.blurhash {
                let imageParams = UploadParameters(
                    source: .data(bytes: processed.data, filename: attachment.filename),
                    caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: inReplyTo)
                let thumbSource: UploadSource? = processed.thumbnail.map {
                    .data(bytes: $0.data, filename: "thumbnail.jpg")
                }
                let info = ImageInfo(
                    height: processed.height,
                    width: processed.width,
                    mimetype: processed.mimetype,
                    size: UInt64(processed.data.count),
                    thumbnailInfo: processed.thumbnail.map {
                        ThumbnailInfo(height: $0.height, width: $0.width,
                                      mimetype: $0.mimetype, size: UInt64($0.data.count))
                    },
                    thumbnailSource: nil,
                    blurhash: blurhash,
                    isAnimated: nil
                )
                fputs("SENDDBG sending image \(attachment.filename) \(processed.width)x\(processed.height) \(processed.mimetype) \(processed.data.count)B\n", stderr)
                do {
                    let handle = try timeline.sendImage(params: imageParams,
                                                        thumbnailSource: thumbSource,
                                                        imageInfo: info)
                    try await handle.join()
                    return
                } catch {
                    fputs("SENDDBG image upload failed: \(error)\n", stderr)
                    restageFailedUpload(attachment)
                    return
                }
            }
        }

        // Everything else: a plain file send.
        let info = FileInfo(
            mimetype: mimetype ?? "application/octet-stream",
            size: UInt64(data.count),
            thumbnailInfo: nil,
            thumbnailSource: nil
        )
        fputs("SENDDBG sending file \(attachment.filename) \(mimetype ?? "octet-stream") \(data.count)B\n", stderr)
        do {
            let handle = try timeline.sendFile(params: params, fileInfo: info)
            try await handle.join()
        } catch {
            fputs("SENDDBG file upload failed: \(error)\n", stderr)
            restageFailedUpload(attachment)
        }
    }

    /// Puts a failed upload back in the composer as an errored chip and
    /// surfaces the failure. A join() that threw because the user cancelled
    /// is not a failure — drop those bytes quietly.
    private func restageFailedUpload(_ attachment: PendingAttachment) {
        if let cancelledAt = lastUploadCancelAt,
           Date().timeIntervalSince(cancelledAt) < 3 {
            lastUploadCancelAt = nil
            presentComposerError(String(localized: "Upload cancelled"))
            return
        }
        var restaged = attachment
        restaged.uploadFailed = true
        pendingAttachments.append(restaged)
        presentComposerError(String(localized: "Couldn't upload \(attachment.filename)"))
    }

    /// Stamped by `cancelSend` so the aborted upload's join() throw reads as
    /// a deliberate cancel, not a re-stageable failure.
    @ObservationIgnored private var lastUploadCancelAt: Date?

    // MARK: Retry / cancel sends

    /// Retries a failed local echo via `SendHandle.tryResend()`; when no
    /// handle survives (queue rebuilt, e.g. after relaunch), redacts the
    /// failed echo and resends the captured text body.
    func retrySend(_ message: MessageItem) {
        guard message.sendState == .failed else { return }
        let provider = message.shieldProvider?.provider
        Task { [weak self] in
            // The failure that marked this echo also disabled the room's send
            // queue; re-enable or the retry sits queued forever.
            await self?.service?.enableAllSendQueues()
            // If a .set diff has since flipped this echo to sent, retrying
            // would redact a real message and duplicate it.
            guard let self, self.currentSendState(of: message) == .failed else { return }
            if let handle = provider?.getSendHandle() {
                do {
                    try await handle.tryResend()
                    return
                } catch {
                    fputs("SENDDBG tryResend failed: \(error)\n", stderr)
                }
            }
            guard case .text(let body) = message.kind else { return }
            if let itemId = message.ffiItemId {
                try? await self.timeline?.redactEvent(eventOrTransactionId: itemId, reason: nil)
            }
            await self.sendText(body)
        }
    }

    /// The live send state of the entry backing `message` — row-captured
    /// values go stale while dialogs are open.
    private func currentSendState(of message: MessageItem) -> MessageItem.SendState? {
        for entry in entries.reversed() {
            if case .message(let m) = entry, m.id == message.id {
                return m.sendState
            }
        }
        return nil
    }

    /// Whether an in-flight send still has an abortable handle; gates the
    /// row's "Cancel Upload" menu item.
    func canCancelSend(_ message: MessageItem) -> Bool {
        message.sendState == .sending
            && message.shieldProvider?.provider.getSendHandle() != nil
    }

    /// Aborts an in-flight send. `SendHandle.abort()` covers text and media
    /// echoes; if the event already left the queue it no-ops.
    func cancelSend(_ message: MessageItem) {
        guard message.sendState == .sending,
              let handle = message.shieldProvider?.provider.getSendHandle() else { return }
        lastUploadCancelAt = Date()
        Task { _ = try? await handle.abort() }
    }

    /// Loads the joined-member list (once per room visit).
    func loadMembers(force: Bool = false) async {
        guard force || members.isEmpty, let iterator = try? await room.members() else { return }
        var all: [MemberItem] = []
        while let chunk = iterator.nextChunk(chunkSize: 500) {
            all.append(contentsOf: chunk
                .filter { $0.membership == .join && !$0.isServiceMember }
                .map {
                    let role: MemberItem.Role = switch $0.suggestedRoleForPowerLevel {
                    case .creator: .creator
                    case .administrator: .administrator
                    case .moderator: .moderator
                    case .user: .member
                    }
                    let level: Int = switch $0.powerLevel {
                    case .infinite: Int.max
                    case .value(let value): Int(value)
                    }
                    return MemberItem(id: $0.userId, displayName: $0.displayName,
                                      avatarURL: $0.avatarUrl, role: role,
                                      powerLevel: level)
                })
        }
        members = all.sorted {
            if $0.powerLevel != $1.powerLevel { return $0.powerLevel > $1.powerLevel }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        membersById = Dictionary(members.map { ($0.id, $0) }) { first, _ in first }
        await loadPowerLevelTags()
    }

    // MARK: Named roles (in.cinny.room.power_level_tags)

    private(set) var powerLevelTags: [Int: PowerLevelTag] = [:]

    private func loadPowerLevelTags() async {
        guard let content = await service?.stateEventContent(
            roomId: roomId, type: PowerLevelTags.eventType) else { return }
        let parsed = PowerLevelTags.parse(content)
        if powerLevelTags != parsed { powerLevelTags = parsed }
    }

    /// The named role for a power level — the room's tag, or a default label.
    func roleTag(forLevel level: Int) -> PowerLevelTag {
        PowerLevelTags.displayTag(forLevel: level, in: powerLevelTags)
    }

    /// Writes the whole tag map. Returns an error message on failure.
    func savePowerLevelTags(_ tags: [Int: PowerLevelTag]) async -> String? {
        do {
            let data = try JSONSerialization.data(withJSONObject: PowerLevelTags.content(from: tags))
            let json = String(data: data, encoding: .utf8) ?? "{}"
            _ = try await room.sendStateEventRaw(
                eventType: PowerLevelTags.eventType, stateKey: "", content: json)
            powerLevelTags = tags
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Opens (or creates) a DM with a member; returns the room ID to select.
    func startDm(userId: String) async -> String? {
        try? await service?.startDm(userId: userId)
    }

    func toggleReaction(_ key: String, on message: MessageItem) {
        guard let timeline, let itemId = message.ffiItemId else { return }
        // Usage feeds the quick-reaction palette, which only rasterises
        // unicode emoji — keep custom-emote keys out.
        if !key.hasPrefix("mxc://") {
            ReactionUsage.record(key)
        }
        Task { _ = try? await timeline.toggleReaction(itemId: itemId, key: key) }
    }

    func redact(_ message: MessageItem) {
        guard let timeline, let itemId = message.ffiItemId else { return }
        Task { try? await timeline.redactEvent(eventOrTransactionId: itemId, reason: nil) }
    }

    // MARK: Polls

    func createPoll(question: String, answers: [String], disclosed: Bool) async {
        guard let timeline else { return }
        try? await timeline.createPoll(question: question, answers: answers,
                                       maxSelections: 1,
                                       pollKind: disclosed ? .disclosed : .undisclosed)
    }

    func votePoll(message: MessageItem, answerId: String) {
        guard let timeline, let eventId = message.eventId else { return }
        Task {
            try? await timeline.sendPollResponse(pollStartEventId: eventId, answers: [answerId])
        }
    }

    func endPoll(message: MessageItem) {
        guard let timeline, let eventId = message.eventId else { return }
        Task {
            try? await timeline.endPoll(pollStartEventId: eventId,
                                        text: String(localized: "The poll has ended."))
        }
    }

    // MARK: Voice messages

    func sendVoiceMessage(_ recording: VoiceRecorder.Recording) async {
        guard let timeline else { return }
        let params = UploadParameters(
            source: .data(bytes: recording.data, filename: "voice-message.m4a"),
            caption: nil,
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )
        let info = AudioInfo(duration: recording.duration,
                             size: UInt64(recording.data.count),
                             mimetype: "audio/mp4")
        do {
            let handle = try timeline.sendVoiceMessage(params: params, audioInfo: info,
                                                       waveform: recording.waveform)
            try await handle.join()
        } catch {
            fputs("SENDDBG voice upload failed: \(error)\n", stderr)
            presentComposerError(String(localized: "Couldn't send voice message"))
        }
    }

    // MARK: Location

    func shareCurrentLocation() async {
        guard let timeline else { return }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                guard let location = update.location else { continue }
                let lat = location.coordinate.latitude
                let lon = location.coordinate.longitude
                try await timeline.sendLocation(
                    body: String(localized: "Shared location"),
                    geoUri: "geo:\(lat),\(lon)",
                    description: nil,
                    zoomLevel: 15,
                    assetType: .sender,
                    repliedToEventId: nil
                )
                break
            }
        } catch {
            fputs("SENDDBG location share failed: \(error)\n", stderr)
            presentComposerError(String(localized: "Couldn't share your location"))
        }
    }

    // MARK: Stickers

    func sendSticker(_ sticker: StickerStore.Sticker) async {
        let content: [String: Any] = [
            "body": sticker.body,
            "url": sticker.url,
            "info": [
                "w": sticker.width,
                "h": sticker.height,
                "mimetype": sticker.mimetype,
                "size": sticker.size,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: content),
              let json = String(data: data, encoding: .utf8) else { return }
        StickerUsage.record(sticker.shortcode)
        try? await room.sendRaw(eventType: "m.sticker", content: json)
    }

    /// Sends a room/space-pack sticker (MSC2545 image).
    func sendSticker(_ emote: CustomEmojiStore.Emote) async {
        var width = emote.width
        var height = emote.height
        // Packs often omit `info`; without w/h receivers guess a frame and
        // crop. Read the real pixel size from the picker's cached bytes.
        if width == nil || height == nil,
           let source = try? MediaSource.fromUrl(url: emote.url),
           let data = await mediaLoader.fullContent(for: MediaSourceBox(source)),
           let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        }
        var info: [String: Any] = [:]
        if let width { info["w"] = width }
        if let height { info["h"] = height }
        if let mimetype = emote.mimetype { info["mimetype"] = mimetype }
        if let size = emote.size { info["size"] = size }
        let content: [String: Any] = [
            "body": emote.body,
            "url": emote.url,
            "info": info,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: content),
              let json = String(data: data, encoding: .utf8) else { return }
        try? await room.sendRaw(eventType: "m.sticker", content: json)
    }

    // MARK: Typing notices (outgoing)

    /// Called on every keystroke; throttled to one notice per 4s, with an
    /// automatic "stopped typing" after 6s idle.
    func composerIsTyping() {
        guard Preferences.shared.sendTypingNotifications else { return }
        typingStopTask?.cancel()
        if lastTypingNotice.map({ Date().timeIntervalSince($0) > 4 }) ?? true {
            lastTypingNotice = Date()
            Task { try? await room.typingNotice(isTyping: true) }
        }
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.sendTypingNotice(false)
        }
    }

    func sendTypingNotice(_ isTyping: Bool) {
        guard Preferences.shared.sendTypingNotifications else { return }
        typingStopTask?.cancel()
        lastTypingNotice = isTyping ? Date() : nil
        Task { try? await room.typingNotice(isTyping: isTyping) }
    }

    /// Consecutive pagination failures, driving the retry backoff below.
    @ObservationIgnored private var paginateFailureCount = 0
    @ObservationIgnored private var lastPaginateFailure: Date?

    func paginateBackwards() async {
        guard let timeline, !isPaginating, !reachedStart, !isParked else { return }
        // The view's sentinel polls every second, hammering the network while
        // offline. Exponential 1,2,4,…30s gate, reset on the first success.
        if paginateFailureCount > 0, let last = lastPaginateFailure {
            let delay = min(30, pow(2, Double(paginateFailureCount - 1)))
            guard Date().timeIntervalSince(last) >= delay else { return }
        }
        isPaginating = true
        defer { isPaginating = false }
        do {
            reachedStart = try await timeline.paginateBackwards(numEvents: 50)
            paginateFailureCount = 0
            lastPaginateFailure = nil
        } catch {
            // Transient (e.g. offline); the sentinel retries after the backoff.
            paginateFailureCount += 1
            lastPaginateFailure = Date()
        }
    }

    /// Event ids whose reply details we've already asked the SDK to load, so a
    /// message that stays pending isn't re-fetched on every diff.
    @ObservationIgnored private var fetchedReplyDetails: Set<String> = []

    /// Loads the replied-to event for any message whose reply preview is still
    /// unresolved. On completion the SDK emits a timeline update with the
    /// details ready, so the snippet fills in instead of showing just "…".
    private func fetchPendingReplyDetails() {
        guard let timeline else { return }
        for entry in entries {
            guard case .message(let message) = entry,
                  let eventId = message.eventId,
                  message.replyPreview?.isPending == true,
                  !fetchedReplyDetails.contains(eventId) else { continue }
            fetchedReplyDetails.insert(eventId)
            Task { try? await timeline.fetchDetailsForEvent(eventId: eventId) }
        }
    }

    /// True `userId -> eventId` read positions, polled from the sliding-sync
    /// receipts extension (the SDK's timeline mis-places receipts on the newest
    /// event). Empty until the first poll lands.
    @ObservationIgnored private var explicitReceipts: [String: String] = [:]
    @ObservationIgnored private var ephemeralSyncTask: Task<Void, Never>?

    /// Overrides each message's receipt list with the true positions, so a
    /// reader shows on the exact event they read — including the newest one,
    /// which the SDK otherwise leaves a message behind. No-op until polled.
    private func applyExplicitReceipts() {
        guard !explicitReceipts.isEmpty else { return }
        for i in entries.indices {
            guard case .message(var m) = entries[i], let eventId = m.eventId else { continue }
            let readers = explicitReceipts
                .filter { $0.value == eventId && $0.key != ownUserId }
                .keys.sorted()
            if m.readReceiptUserIds != Array(readers) {
                m.readReceiptUserIds = Array(readers)
                entries[i] = .message(m)
            }
        }
    }

    /// Streams the open room's ephemerals (receipts + typing) via a parallel
    /// long-poll `/sync`, because the SDK's sliding-sync path mis-places
    /// receipts on the newest event and its ephemeral updates don't surface
    /// live. Initial call snapshots the full state; each subsequent long-poll
    /// blocks until something changes, so updates are effectively instant.
    private func startEphemeralSync() {
        ephemeralSyncTask?.cancel()
        guard mode == .live else { return }
        ephemeralSyncTask = Task { [weak self] in
            var since: String?
            while !Task.isCancelled {
                guard let self, !self.isParked, let service = self.service else { break }
                guard let result = await service.fetchRoomEphemerals(roomId: self.roomId, since: since) else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                since = result.nextBatch
                var receiptsChanged = false
                for (userId, eventId) in result.receipts where self.explicitReceipts[userId] != eventId {
                    self.explicitReceipts[userId] = eventId
                    receiptsChanged = true
                }
                if receiptsChanged { self.applyExplicitReceipts() }

                if let typing = result.typing {
                    let others = typing.filter { $0 != self.ownUserId }
                    if self.typingUsers != others { self.typingUsers = others }
                    self.typingExpiryTask?.cancel()
                    if !others.isEmpty {
                        self.typingExpiryTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(12))
                            self?.typingUsers = []
                        }
                    }
                }
            }
        }
    }

    /// Updates the read-marker and (re)arms the auto-dismissing pill. Only a
    /// marker we haven't already dismissed shows, and only for a few seconds.
    private func setUnreadMarker(_ marker: String?) {
        guard marker != firstUnreadMarkerId else { return }
        firstUnreadMarkerId = marker
        guard let marker else {
            unreadDismissTask?.cancel()
            unreadMarkerVisible = false
            return
        }
        // Already seen this one (e.g. returning to the room): stay hidden.
        guard marker != dismissedMarkerId else {
            unreadMarkerVisible = false
            return
        }
        unreadMarkerVisible = true
        unreadDismissTask?.cancel()
        unreadDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.dismissedMarkerId = marker
            self.unreadMarkerVisible = false
        }
    }

    /// Hides the pill immediately (you've caught up), and remembers it as seen
    /// so it won't reappear when you return to the room.
    private func dismissUnreadMarker() {
        unreadDismissTask?.cancel()
        dismissedMarkerId = firstUnreadMarkerId
        unreadMarkerVisible = false
    }

    func markAsRead() {
        dismissUnreadMarker()
        guard !isParked, mode == .live, let timeline else { return }
        // The bottom sentinel calls this on every scroll flip; re-send only
        // for a newer event than last acknowledged, with a short cool-down
        // when no event ID is available yet.
        var latestEventId: String?
        for entry in entries.reversed() {
            if case .message(let m) = entry, let id = m.eventId {
                latestEventId = id
                break
            }
        }
        let now = Date()
        if let latestEventId, latestEventId == lastMarkedReadEventId { return }
        if latestEventId == nil, let last = lastMarkedReadAt,
           now.timeIntervalSince(last) < 2 { return }
        lastMarkedReadEventId = latestEventId
        lastMarkedReadAt = now
        let sendReceipt = Preferences.shared.sendReadReceipts
        Task { [room, weak self] in
            do {
                // With receipts off, don't tell the server — but still clear
                // the local unread flag so the sidebar pip drops.
                if sendReceipt {
                    try await timeline.markAsRead(receiptType: .read)
                }
                // Also drop the manual "mark unread" flag; the receipt alone
                // doesn't, leaving the sidebar pip lit after reading.
                try? await room.setUnreadFlag(newValue: false)
            } catch {
                // Un-commit the debounce so the next appearance retries;
                // otherwise an offline failure sticks until a newer event.
                self?.resetMarkAsReadDebounce(ifStill: latestEventId)
            }
        }
    }

    private func resetMarkAsReadDebounce(ifStill eventId: String?) {
        if lastMarkedReadEventId == eventId {
            lastMarkedReadEventId = nil
            lastMarkedReadAt = nil
        }
    }

    // MARK: Diff application

    private func apply(_ diffs: [TimelineDiff]) {
        var appendedAtBottom = false
        // Grouping depends only on the entry above, so regroup the smallest
        // neighborhood a batch touched:
        //  • `.set` batches (reactions, receipts, edits) → the set rows.
        //  • pure-append batches (the hot path) → the new tail.
        //  • any other positional diff (indices shift) → full regroup.
        var needsFullRegroup = false
        var appendStart: Int?
        var setIndices: [Int] = []
        for diff in diffs {
            switch diff {
            case .append(let values):
                let start = entries.count
                entries.append(contentsOf: values.map(TimelineEntry.init(ffi:)))
                appendedAtBottom = true
                if appendStart == nil { appendStart = start }
            case .clear:
                entries.removeAll()
                // The SDK sometimes rebuilds down to the sync window; reopen
                // pagination so the sentinel refills the dropped history.
                reachedStart = false
                // Crypto state may have moved; let rows refetch their shields.
                shields.removeAll()
                shieldsRequested.removeAll()
                needsFullRegroup = true
            case .pushFront(let value):
                entries.insert(TimelineEntry(ffi: value), at: 0)
                needsFullRegroup = true
            case .pushBack(let value):
                let start = entries.count
                entries.append(TimelineEntry(ffi: value))
                appendedAtBottom = true
                if appendStart == nil { appendStart = start }
            case .popFront:
                if !entries.isEmpty { entries.removeFirst() }
                needsFullRegroup = true
            case .popBack:
                if !entries.isEmpty { entries.removeLast() }
                needsFullRegroup = true
            case .insert(let index, let value):
                let i = min(max(Int(index), 0), entries.count)
                entries.insert(TimelineEntry(ffi: value), at: i)
                needsFullRegroup = true
            case .set(let index, let value):
                let i = Int(index)
                guard entries.indices.contains(i) else { break }
                entries[i] = TimelineEntry(ffi: value)
                // Re-arm the shield fetch: a .set can follow a verification
                // change. Offscreen rows refetch via task(id:); visible rows
                // won't (same event id), so kick those directly.
                if case .message(let m) = entries[i], let eid = m.eventId {
                    shieldsRequested.remove(eid)
                    if visibleEntryIds.contains(entries[i].id) {
                        loadShieldIfNeeded(for: m)
                    }
                }
                setIndices.append(i)
                #if DEBUG
                if case .message(let m) = entries[i], !m.readReceiptUserIds.isEmpty {
                    Logger(subsystem: "dev.discourse.debug", category: "receipts")
                        .notice("receipts idx \(i): [\(m.readReceiptUserIds.joined(separator: ","), privacy: .public)]")
                }
                #endif
            case .remove(let index):
                let i = Int(index)
                guard entries.indices.contains(i) else { break }
                entries.remove(at: i)
                needsFullRegroup = true
            case .truncate(let length):
                let l = Int(length)
                if entries.count > l { entries.removeSubrange(l...) }
                needsFullRegroup = true
            case .reset(let values):
                let hadMore = entries.count
                entries = values.map(TimelineEntry.init(ffi:))
                // Same window-rebuild case as .clear: don't strand the user
                // with less history than they had loaded.
                if entries.count < hadMore {
                    reachedStart = false
                }
                // Unpark: land back on the pre-park scroll anchor if it's here.
                if let anchor = pendingUnparkAnchor {
                    pendingUnparkAnchor = nil
                    if entries.contains(where: {
                        if case .message(let m) = $0 { return m.eventId == anchor }
                        return false
                    }) {
                        unparkScrollTarget = anchor
                    }
                }
                shields.removeAll()
                shieldsRequested.removeAll()
                needsFullRegroup = true
            }
        }
        if needsFullRegroup {
            regroup()
        } else {
            // Ascending order so each appended row's predecessor is already
            // finalized; each `.set` row also re-checks the row below it
            // (whose predecessor changed).
            var dirty = Set<Int>()
            if let appendStart { for i in appendStart..<entries.count { dirty.insert(i) } }
            for i in setIndices { dirty.insert(i); dirty.insert(i + 1) }
            for i in dirty.sorted() { regroup(at: i) }
        }
        updateLastOwnMessageId()
        let marker = entries.first(where: {
            if case .readMarker = $0 { return true }
            return false
        })?.id
        setUnreadMarker(marker)
        applyExplicitReceipts()
        fetchPendingReplyDetails()
        if appendedAtBottom && isAtBottom {
            markAsRead()
        }
    }

    /// A message shows its header (avatar + name + time) unless it directly
    /// follows another from the same sender within the grouping window.
    private func regroup() {
        let window = Preferences.shared.groupingWindow
        var previous: MessageItem?
        for index in entries.indices {
            guard case .message(var message) = entries[index] else {
                previous = nil
                continue
            }
            let grouped = previous.map {
                $0.sender == message.sender
                    && message.timestamp.timeIntervalSince($0.timestamp) < window
            } ?? false
            if message.showsHeader != !grouped {
                message.showsHeader = !grouped
                entries[index] = .message(message)
            }
            previous = message
        }
    }

    /// Single-index `regroup` for in-place `.set` diffs: a row's header flag
    /// depends only on the entry directly above it.
    private func regroup(at index: Int) {
        guard entries.indices.contains(index),
              case .message(var message) = entries[index] else { return }
        var previous: MessageItem?
        if index > 0, case .message(let p) = entries[index - 1] { previous = p }
        let grouped = previous.map {
            $0.sender == message.sender
                && message.timestamp.timeIntervalSince($0.timestamp) < Preferences.shared.groupingWindow
        } ?? false
        if message.showsHeader != !grouped {
            message.showsHeader = !grouped
            entries[index] = .message(message)
        }
    }
}
