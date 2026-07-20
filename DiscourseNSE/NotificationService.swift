import UserNotifications
@preconcurrency import MatrixRustSDK

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
        guard let roomId = info["room_id"] as? String,
              let eventId = info["event_id"] as? String else {
            return deliver()
        }
        let userId = info["user_id"] as? String

        Task {
            await enrich(userId: userId, roomId: roomId, eventId: eventId)
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
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
                ?? tokens.first else { return }

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
                return
            }
            apply(item)
        } catch {
            // Keep the gateway's default payload.
        }
    }

    private func apply(_ item: NotificationItem) {
        guard let content = bestAttempt else { return }
        let sender = item.senderInfo.displayName ?? ""
        let room = item.roomInfo.displayName
        let isGroup = item.roomInfo.joinedMembersCount > 2

        if isGroup {
            content.title = room
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

    /// The decrypted event JSON carries the plaintext message body.
    private func messageBody(from rawEvent: String) -> String? {
        guard let data = rawEvent.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let body = content["body"] as? String else { return nil }
        return body.replacingOccurrences(of: "\n", with: " ")
    }
}
