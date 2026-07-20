#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UserNotifications

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
    var openRoom: ((_ roomId: String, _ accountUserId: String?) -> Void)? {
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
        case open(roomId: String, accountUserId: String?)
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
            case .open(let roomId, let accountUserId):
                if let openRoom { openRoom(roomId, accountUserId) } else { pendingActions.append(action) }
            }
        }
    }
    var onIncomingCall: ((RoomSummary) -> Void)?
    var onCallEnded: ((String) -> Void)?

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

    func maybeNotify(room: RoomSummary, spaceName: String? = nil, accountUserId: String) {
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
        deliver(content, identifier: "\(room.id)-\(timestamp.timeIntervalSince1970)")
    }

    func maybeNotifyCall(room: RoomSummary, accountUserId: String) {
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
        // Ring in-app unless we started this call ourselves.
        if !CallRegistry.localRooms.contains(room.id) {
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
        deliver(content, identifier: "call-\(room.id)")
    }

    private var invitesNotified: Set<String> = []

    /// One-shot notification when an invite arrives.
    func maybeNotifyInvite(room: RoomSummary, accountUserId: String) {
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
        deliver(content, identifier: "invite-\(room.id)")
    }

    private func applySound(to content: UNMutableNotificationContent) {
        if Preferences.shared.notificationSound {
            content.sound = .default
        }
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let roomId = response.notification.request.content.userInfo["roomId"] as? String
        // Account that produced the notification (may be absent on older banners).
        let accountUserId = response.notification.request.content.userInfo["userId"] as? String
        let actionId = response.actionIdentifier
        // Extract off-actor: the response object isn't Sendable.
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
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
                    openRoom(roomId, accountUserId)
                } else {
                    pendingActions.append(.open(roomId: roomId, accountUserId: accountUserId))
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let playSound = await MainActor.run { Preferences.shared.notificationSound }
        return playSound ? [.banner, .sound, .list] : [.banner, .list]
    }
}
