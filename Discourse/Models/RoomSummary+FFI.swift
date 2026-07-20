import Foundation
@preconcurrency import MatrixRustSDK

// Maps FFI types to plain models; the only place outside Core importing MatrixRustSDK.

extension RoomSummary {
    /// Cheap synchronous snapshot from a `Room`'s cached accessors; unreads and
    /// last-message preview are filled in asynchronously afterwards.
    init(basicsOf room: Room) {
        let id = room.id()
        self.init(
            id: id,
            name: room.displayName() ?? id,
            avatarURL: room.avatarUrl(),
            topic: room.topic(),
            isDirect: false,
            lastMessagePreview: nil,
            lastActivity: nil,
            unreadMessages: 0,
            unreadNotifications: 0,
            unreadMentions: 0,
            isMarkedUnread: false
        )
        foldedName = Self.foldedForSearch(name)
    }

    mutating func update(from info: RoomInfo) {
        name = info.displayName ?? info.canonicalAlias ?? id
        avatarURL = info.avatarUrl
        topic = info.topic
        isDirect = info.isDm || info.isDirect
        isSpace = info.isSpace
        isEncrypted = info.encryptionState == .encrypted
        unreadMessages = info.numUnreadMessages
        unreadNotifications = info.numUnreadNotifications
        unreadMentions = info.numUnreadMentions
        isMarkedUnread = info.isMarkedUnread
        isMuted = info.cachedUserDefinedNotificationMode == .mute
        isFavourite = info.isFavourite
        isLowPriority = info.isLowPriority
        hasActiveCall = info.hasRoomCall
        dmUserId = isDirect ? info.heroes.first?.userId : nil
        isInvited = info.membership == .invited
    }

    mutating func update(from latest: LatestEventValue) {
        switch latest {
        case .remote(let timestamp, let sender, let isOwn, let profile, let content):
            lastActivity = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            lastMessagePreview = Self.previewText(from: content)
            lastMessageIsOwn = isOwn
            lastMessageSenderName = Self.displayName(profile) ?? Self.localpart(sender)
        case .local(let timestamp, _, _, let content, _):
            lastActivity = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            lastMessagePreview = Self.previewText(from: content)
            lastMessageIsOwn = true
        case .remoteInvite(let timestamp, _, _):
            lastActivity = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            lastMessagePreview = "Invitation"
            lastMessageIsOwn = false
            lastMessageSenderName = nil
        case .none:
            break
        }
    }

    /// Video and call rooms, by `m.room.create` type.
    static func isVideoRoomType(_ type: RoomType) -> Bool {
        if case .custom(let value) = type {
            return value == "io.element.video" || value == "org.matrix.msc3417.call"
        }
        return false
    }

    private static func displayName(_ profile: ProfileDetails) -> String? {
        if case .ready(let displayName, _, _) = profile { return displayName }
        return nil
    }

    private static func localpart(_ userId: String) -> String {
        guard userId.hasPrefix("@") else { return userId }
        return String(userId.dropFirst().prefix(while: { $0 != ":" }))
    }

    /// Mirrors `MediaLoader.avatar`'s conversion so synchronous cache lookups
    /// hit the same key.
    static func avatarSource(mxcUrl: String) -> MediaSourceBox? {
        guard let source = try? MediaSource.fromUrl(url: mxcUrl) else { return nil }
        return MediaSourceBox(source)
    }

    static func previewText(from content: TimelineItemContent) -> String? {
        switch content {
        case .msgLike(let msgLike):
            switch msgLike.kind {
            case .message(let message):
                return message.body.replacingOccurrences(of: "\n", with: " ")
            case .sticker(let body, _, _):
                return "Sticker: \(body)"
            case .poll(let question, _, _, _, _, _, _):
                return "Poll: \(question)"
            case .redacted:
                return "Message deleted"
            default:
                return "Encrypted message"
            }
        case .roomMembership, .profileChange, .state:
            return nil
        default:
            return nil
        }
    }
}
