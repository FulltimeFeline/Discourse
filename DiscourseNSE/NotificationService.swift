import ImageIO
import UniformTypeIdentifiers
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
        // Normalize the gateway's snake_case payload to the keys the app's tap
        // handler reads (roomId/eventId/userId) — same shape as local banners.
        // Without this, tapping a remote push resolved a nil roomId and never
        // navigated to the chat.
        bestAttempt?.userInfo["roomId"] = roomId
        bestAttempt?.userInfo["eventId"] = eventId
        if let userId { bestAttempt?.userInfo["userId"] = userId }

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
            // Label which account this is for (full @user:server), but only when
            // more than one is signed in on this device.
            let accountLabel = tokens.count > 1 ? token.session.userId : nil
            apply(item, roomId: roomId, accountLabel: accountLabel)
            await attachAvatar(client: client, item: item, roomId: roomId)
            nseLog.info("decrypted + enriched notification")
        } catch {
            nseLog.error("enrich failed: \(error, privacy: .public)")
        }
    }

    /// Downloads the pfp and attaches it as the push's image: a 1:1 shows the
    /// other person, a room inside a space shows the space, a plain room shows
    /// the room. Silently no-ops if there's no avatar or the download fails.
    private func attachAvatar(client: Client, item: NotificationItem, roomId: String) async {
        guard let content = bestAttempt else { return }
        let isGroup = item.roomInfo.joinedMembersCount > 2
        // Prefer the app-provided avatar (resolves the DM/room/space rule and is
        // reliable); fall back to the push item's own fields.
        let mxc: String?
        if let appProvided = SpaceNameStore.roomAvatar(forRoom: roomId) {
            mxc = appProvided
        } else if !isGroup {
            // 1:1 — the other party is the sender.
            mxc = item.senderInfo.avatarUrl ?? item.roomInfo.avatarUrl
        } else if let spaceAvatar = SpaceNameStore.spaceAvatar(forRoom: roomId) {
            mxc = spaceAvatar
        } else {
            mxc = item.roomInfo.avatarUrl
        }
        guard let mxc, let source = try? MediaSource.fromUrl(url: mxc) else {
            nseLog.info("no avatar mxc for room")
            return
        }
        // Thumbnail first; fall back to full content (authenticated-media servers
        // can 404 the thumbnail path for some sources).
        let data: Data?
        if let thumb = try? await client.getMediaThumbnail(mediaSource: source, width: 128, height: 128) {
            data = thumb
        } else {
            data = try? await client.getMediaContent(mediaSource: source)
        }
        guard let data, let png = Self.encodePNG(data) else {
            nseLog.error("avatar fetch/encode failed for \(mxc, privacy: .public)")
            return
        }
        let name = roomId.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-avatar-\(name).png")
        guard (try? png.write(to: url)) != nil,
              let attachment = try? UNNotificationAttachment(
                identifier: "avatar", url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        else {
            nseLog.error("avatar attachment build failed")
            return
        }
        content.attachments = [attachment]
        nseLog.info("attached avatar")
    }

    /// Re-encodes downloaded avatar bytes to PNG so the attachment's type is
    /// unambiguous (raw server bytes may be JPEG/WebP and fail attachment
    /// validation against a fixed extension).
    private static func encodePNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private func apply(_ item: NotificationItem, roomId: String, accountLabel: String?) {
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
        // Which account this notification is for (multi-account only), in the
        // format `SenderName (@account:server)`. The sender is in the subtitle
        // for rooms and in the title for DMs.
        if let accountLabel {
            if !content.subtitle.isEmpty {
                content.subtitle += " (\(accountLabel))"
            } else {
                content.title += " (\(accountLabel))"
            }
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
