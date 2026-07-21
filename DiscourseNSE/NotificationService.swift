import UserNotifications
import os
@preconcurrency import MatrixRustSDK

private let nseLog = Logger(subsystem: "dev.discourse.push", category: "nse")

/// Wakes on each remote push, restores a client from the shared App Group
/// store, and rewrites the notification with the decrypted sender, room, and
/// message. Falls back to the gateway's default payload if anything fails.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        let info = request.content.userInfo
        nseLog.info("NSE woke — keys=\(info.keys.map { "\($0)" }.joined(separator: ","), privacy: .public)")
        guard let roomId = info["room_id"] as? String,
              let eventId = info["event_id"] as? String else {
            nseLog.error("missing room_id/event_id in payload — delivering fallback")
            return deliver()
        }
        let userId = info["user_id"] as? String
        // Group by room and let the app clear/suppress a room's banners when it's
        // opened (NotificationManager keys off threadIdentifier / roomId).
        bestAttempt?.threadIdentifier = roomId

        Task {
            await enrich(userId: userId, roomId: roomId, eventId: eventId)
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        nseLog.error("time expired before decryption — delivering fallback")
        deliver()
    }

    private func deliver() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    private func enrich(userId: String?, roomId: String, eventId: String) async {
        MatrixPlatform.initializeOnce()

        let tokens = SessionStore().loadAll()
        guard let token = userId.flatMap({ id in tokens.first { $0.session.userId == id } })
                ?? tokens.first else {
            nseLog.error("no stored session in shared keychain — App Group/keychain not shared?")
            return
        }

        do {
            let dirs = try SessionStore.currentSessionDirectories(token: token)
            let client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: token.session.homeserverUrl)
                .sqliteStore(config: SqliteStoreBuilder(dataPath: dirs.dataPath, cachePath: dirs.cachePath)
                    .passphrase(passphrase: token.storePassphrase))
                .slidingSyncVersionBuilder(versionBuilder: token.session.slidingSyncVersion == "native" ? .native : .none)
                .build()
            try await client.restoreSession(session: token.session.ffiSession)

            let notificationClient = try await client.notificationClient(processSetup: .multipleProcesses)
            guard case let .event(item) = try await notificationClient.getNotification(roomId: roomId, eventId: eventId) else {
                nseLog.error("getNotification returned no event")
                return
            }
            apply(item, roomId: roomId)
            nseLog.info("decrypted + enriched notification")
        } catch {
            nseLog.error("enrich failed: \(error, privacy: .public)")
        }
    }

    private func apply(_ item: NotificationItem, roomId: String) {
        guard let content = bestAttempt else { return }
        let sender = item.senderInfo.displayName ?? ""
        let room = item.roomInfo.displayName
        let isGroup = item.roomInfo.joinedMembersCount > 2

        if isGroup {
            // "Space › Room" when the app has recorded this room's parent space.
            let space = SpaceNameStore.spaceName(forRoom: roomId)
            content.title = space.map { "\($0) › \(room)" } ?? room
            content.subtitle = sender.isEmpty ? "" : sender
        } else {
            content.title = sender.isEmpty ? room : sender
        }
        if let body = messageBody(from: item.rawEvent) {
            content.body = body
        }
        if item.isNoisy == true {
            content.sound = .default
        }
    }

    /// The decrypted event JSON carries the plaintext message body. Replies are
    /// prefixed with "↩ " and their `> <@user> …` fallback stripped, so a
    /// notification shows the clean reply text instead of the quoted original.
    private func messageBody(from rawEvent: String) -> String? {
        guard let data = rawEvent.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              var body = content["body"] as? String else { return nil }
        let isReply = (content["m.relates_to"] as? [String: Any])?["m.in_reply_to"] != nil
        if isReply, body.hasPrefix(">") {
            var lines = body.components(separatedBy: "\n")
            var i = 0
            while i < lines.count, lines[i].hasPrefix(">") { i += 1 }
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            if i < lines.count { body = "↩ " + lines[i...].joined(separator: "\n") }
        }
        return body.replacingOccurrences(of: "\n", with: " ")
    }
}
