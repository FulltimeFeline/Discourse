#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import UserNotifications
import os

private let notifLog = Logger(subsystem: "dev.discourse.push", category: "local-notif")

/// Posts local notifications for incoming messages, suppressing them for the
/// focused room and own messages, and routes clicks back into the app.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Room open in the main window; its notifications are suppressed while
    /// active and its delivered banners cleared when opened.
    var focusedRoomId: String? {
        didSet {
            if let focusedRoomId { clearDelivered(roomId: focusedRoomId) }
        }
    }
    /// Opens a room on click. Handler may need to switch accounts first, since
    /// every warm account's sync notifies.
    var openRoom: ((_ roomId: String, _ eventId: String?, _ accountUserId: String?) -> Void)? {
        didSet { drainPendingActions() }
    }
    var sendReply: ((_ roomId: String, _ text: String, _ accountUserId: String?) -> Void)? {
        didSet { drainPendingActions() }
    }
    var markRoomRead: ((_ roomId: String, _ accountUserId: String?) -> Void)? {
        didSet { drainPendingActions() }
    }

    /// Actions that arrived before the session wired its handlers (cold launch).
    private enum PendingAction {
        case reply(roomId: String, text: String, accountUserId: String?)
        case markRead(roomId: String, accountUserId: String?)
        case open(roomId: String, eventId: String?, accountUserId: String?)
    }
    private var pendingActions: [PendingAction] = []

    private func drainPendingActions() {
        guard !pendingActions.isEmpty else { return }
        let drained = pendingActions
        pendingActions = []
        for action in drained {
            switch action {
            case .reply(let roomId, let text, let accountUserId):
                if let sendReply { sendReply(roomId, text, accountUserId) } else { pendingActions.append(action) }
            case .markRead(let roomId, let accountUserId):
                if let markRoomRead { markRoomRead(roomId, accountUserId) } else { pendingActions.append(action) }
            case .open(let roomId, let eventId, let accountUserId):
                if let openRoom { openRoom(roomId, eventId, accountUserId) } else { pendingActions.append(action) }
            }
        }
    }
    var onIncomingCall: ((RoomSummary) -> Void)?
    var onCallEnded: ((String) -> Void)?
    /// Resolves an avatar (mxc URL) to PNG bytes for the given account, so a
    /// notification can show the room/sender pfp. Set by the app.
    var loadAvatar: ((_ mxcUrl: String, _ accountUserId: String) async -> Data?)?
    /// The label to show for which account a notification is for, or nil to omit
    /// it (e.g. only one account signed in). Set by the app.
    var accountLabel: ((_ accountUserId: String) -> String?)?

    /// Appends the owning account in parentheses after the sender — the format
    /// `SenderName (@account:server)` — so a multi-account user can tell which
    /// account a banner is for. The sender sits in the subtitle for room
    /// notifications and in the title for DMs.
    private func applyAccountLabel(to content: UNMutableNotificationContent, accountUserId: String) {
        guard let label = accountLabel?(accountUserId), !label.isEmpty else { return }
        if !content.subtitle.isEmpty {
            content.subtitle += " (\(label))"
        } else {
            content.title += " (\(label))"
        }
    }

    private var lastNotified: [String: Date] = [:]
    private var lastCallActive: [String: Bool] = [:]
    private var isAuthorized = false

    private static let messageCategoryId = "MESSAGE"
    private static let replyActionId = "REPLY"
    private static let markReadActionId = "MARK_READ"

    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: String(localized: "Reply"),
            options: [],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message"))
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionId,
            title: String(localized: "Mark as Read"),
            options: [])
        let message = UNNotificationCategory(
            identifier: Self.messageCategoryId,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: [])
        center.setNotificationCategories([message])
        Task {
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    func maybeNotify(room: RoomSummary, spaceName: String? = nil,
                     avatarURL: String? = nil, accountUserId: String) {
        #if os(iOS)
        // With remote push on, the notification service extension is the single
        // source for message banners. Posting a local one too would double every
        // message (and the local + push copies race on which title shows).
        if PushConfig.enabled { return }
        #endif
        guard isAuthorized,
              !room.lastMessageIsOwn,
              room.unreadNotifications > 0,
              let timestamp = room.lastActivity,
              let preview = room.lastMessagePreview
        else { return }
        // Don't re-notify for the same message, and skip the room on screen.
        guard timestamp > (lastNotified[room.id] ?? .distantPast) else { return }
        if Platform.isAppActive && focusedRoomId == room.id {
            // Mark handled so a later room-list refresh can't notify for it.
            lastNotified[room.id] = timestamp
            return
        }
        // Ignore stale events delivered during initial sync/backfill.
        guard timestamp.timeIntervalSinceNow > -120 else { return }
        lastNotified[room.id] = timestamp

        // How much of who/what to reveal on the lock screen.
        let previewLevel = Preferences.shared.notificationPreview

        let content = UNMutableNotificationContent()
        switch previewLevel {
        case .full:
            if room.isDirect {
                content.title = room.lastMessageSenderName ?? room.name
            } else {
                content.title = spaceName.map { "\($0) › \(room.name)" } ?? room.name
                if let sender = room.lastMessageSenderName {
                    content.subtitle = sender
                }
            }
            content.body = preview
        case .senderOnly:
            // Who/where, but never the message contents.
            if room.isDirect {
                content.title = room.lastMessageSenderName ?? room.name
            } else {
                content.title = spaceName.map { "\($0) › \(room.name)" } ?? room.name
                if let sender = room.lastMessageSenderName {
                    content.subtitle = sender
                }
            }
            content.body = String(localized: "New message")
        case .none:
            content.title = String(localized: "Discourse")
            content.body = String(localized: "New notification")
        }
        applySound(to: content)
        content.threadIdentifier = room.id
        content.categoryIdentifier = Self.messageCategoryId
        content.userInfo = ["roomId": room.id, "userId": accountUserId]
        applyAccountLabel(to: content, accountUserId: accountUserId)
        deliver(content, identifier: "\(room.id)-\(timestamp.timeIntervalSince1970)",
                avatarURL: avatarURL, accountUserId: accountUserId)
    }

    func maybeNotifyCall(room: RoomSummary, avatarURL: String? = nil, accountUserId: String) {
        let wasActive = lastCallActive[room.id] ?? false
        lastCallActive[room.id] = room.hasActiveCall
        if wasActive && !room.hasActiveCall {
            onCallEnded?(room.id)
            // Otherwise the stale "Call started" banner lingers and, tapped
            // later, lands in a call-less room.
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ["call-\(room.id)"])
        }
        guard room.hasActiveCall, !wasActive else { return }
        // Ring in-app only for 1:1 calls (and not one we started ourselves);
        // group calls are announced by a banner, not a ringtone.
        if room.isDirect, !CallRegistry.localRooms.contains(room.id) {
            onIncomingCall?(room)
        }
        guard isAuthorized else { return }
        if Platform.isAppActive && focusedRoomId == room.id { return }

        let content = UNMutableNotificationContent()
        // A call reveals the room but no message contents; only .none hides it.
        if Preferences.shared.notificationPreview == .none {
            content.title = String(localized: "Discourse")
            content.body = String(localized: "Incoming call")
        } else {
            content.title = room.name
            content.body = String(localized: "Call started — click to join")
        }
        applySound(to: content)
        content.threadIdentifier = room.id
        content.userInfo = ["roomId": room.id, "userId": accountUserId]
        applyAccountLabel(to: content, accountUserId: accountUserId)
        deliver(content, identifier: "call-\(room.id)",
                avatarURL: avatarURL, accountUserId: accountUserId)
    }

    private var invitesNotified: Set<String> = []

    /// One-shot notification when an invite arrives.
    func maybeNotifyInvite(room: RoomSummary, avatarURL: String? = nil, accountUserId: String) {
        guard isAuthorized, room.isInvited, !invitesNotified.contains(room.id) else { return }
        invitesNotified.insert(room.id)

        let content = UNMutableNotificationContent()
        // Inviter and room, but nothing message-like; only .none hides it.
        if Preferences.shared.notificationPreview == .none {
            content.title = String(localized: "Discourse")
            content.body = String(localized: "You've been invited")
        } else {
            content.title = room.name
            content.body = if let inviter = room.inviterName {
                String(localized: "\(inviter) invited you")
            } else {
                String(localized: "You've been invited")
            }
        }
        applySound(to: content)
        content.threadIdentifier = room.id
        content.userInfo = ["roomId": room.id, "userId": accountUserId]
        applyAccountLabel(to: content, accountUserId: accountUserId)
        deliver(content, identifier: "invite-\(room.id)",
                avatarURL: avatarURL, accountUserId: accountUserId)
    }

    private func applySound(to content: UNMutableNotificationContent) {
        if Preferences.shared.notificationSound {
            content.sound = .default
        }
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String,
                         avatarURL: String? = nil, accountUserId: String? = nil) {
        Task {
            // Attach the room/sender/space pfp as the notification's image.
            let loader = self.loadAvatar
            notifLog.info("deliver: avatarURL=\(avatarURL ?? "nil", privacy: .public) account=\(accountUserId ?? "nil", privacy: .public) hasLoader=\(loader != nil)")
            if let avatarURL, let accountUserId, let loadAvatar = loader {
                if let data = await loadAvatar(avatarURL, accountUserId) {
                    notifLog.info("deliver: loaded \(data.count) avatar bytes")
                    if let attachment = Self.avatarAttachment(pngData: data, identifier: identifier) {
                        content.attachments = [attachment]
                        notifLog.info("deliver: attachment built OK")
                    } else {
                        notifLog.error("deliver: attachment build FAILED")
                    }
                } else {
                    notifLog.error("deliver: loadAvatar returned nil")
                }
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
                notifLog.info("deliver: request added (attachments=\(content.attachments.count))")
            } catch {
                notifLog.error("deliver: add failed \(error, privacy: .public)")
            }
        }
    }

    /// Writes avatar PNG bytes to a temp file and wraps it as an attachment.
    private static func avatarAttachment(pngData: Data, identifier: String) -> UNNotificationAttachment? {
        let safeName = identifier.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-\(safeName).png")
        do {
            try pngData.write(to: url)
            return try UNNotificationAttachment(
                identifier: "avatar", url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch {
            return nil
        }
    }

    /// Removes a room's delivered banners once it's been read.
    func clearDelivered(roomId: String) {
        clearDelivered(roomIds: [roomId])
    }

    /// Batch variant: one `deliveredNotifications()` fetch covers every room.
    func clearDelivered(roomIds: Set<String>) {
        guard !roomIds.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered
                .filter { roomIds.contains($0.request.content.threadIdentifier) }
                .map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Completion-handler variants (not the async ones): the delegate itself must
    // stay `nonisolated` to receive the non-Sendable response, but its completion
    // must fire on the MAIN thread — UIKit runs its post-delegate state-restoration
    // snapshot on whatever thread completes, and off-main it aborts with "Call
    // must be made on main thread". So we extract the Sendable values here, hop to
    // the main actor to do the work, and call the completion handler from there.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        // Local banners use camelCase; remote pushes arrive snake_case. Accept both.
        let roomId = (info["roomId"] as? String) ?? (info["room_id"] as? String)
        let eventId = (info["eventId"] as? String) ?? (info["event_id"] as? String)
        let accountUserId = (info["userId"] as? String) ?? (info["user_id"] as? String)
        let actionId = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { completionHandler() }
            switch actionId {
            case Self.replyActionId:
                let text = (replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let roomId, !text.isEmpty else { break }
                if let sendReply {
                    sendReply(roomId, text, accountUserId)
                } else {
                    // Cold launch: handlers wire up after session restore.
                    pendingActions.append(.reply(roomId: roomId, text: text,
                                                 accountUserId: accountUserId))
                }
            case Self.markReadActionId:
                guard let roomId else { break }
                if let markRoomRead {
                    markRoomRead(roomId, accountUserId)
                } else {
                    pendingActions.append(.markRead(roomId: roomId, accountUserId: accountUserId))
                }
            default:
                // Plain click: foreground and open the room.
                Platform.activateApp()
                guard let roomId else { break }
                if let openRoom {
                    openRoom(roomId, eventId, accountUserId)
                } else {
                    pendingActions.append(.open(roomId: roomId, eventId: eventId,
                                                accountUserId: accountUserId))
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        // Remote pushes (room_id) and local ones (roomId) both carry the room.
        let info = notification.request.content.userInfo
        let roomId = (info["room_id"] as? String) ?? (info["roomId"] as? String)
        Task { @MainActor in
            // Don't banner a message for the room already on screen.
            if roomId != nil && roomId == focusedRoomId {
                completionHandler([])
                return
            }
            completionHandler(Preferences.shared.notificationSound
                              ? [.banner, .sound, .list] : [.banner, .list])
        }
    }
}
