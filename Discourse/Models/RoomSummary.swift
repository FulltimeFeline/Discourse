import Foundation

/// Plain, Sendable snapshot of a room for the sidebar, mapped from FFI `Room`/`RoomInfo`.
struct RoomSummary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String {
        didSet { foldedName = Self.foldedForSearch(name) }
    }
    /// `name` folded for search. `didSet` maintains it; initializers must seed
    /// it by hand since observers don't fire in init.
    var foldedName: String = ""
    var avatarURL: String?
    var topic: String?
    var isDirect: Bool
    var isSpace: Bool = false
    /// Video room (`io.element.video` / MSC3417): a standing call rather than
    /// a text timeline.
    var isVideoRoom: Bool = false
    var isEncrypted: Bool = false
    var lastMessagePreview: String?
    var lastMessageIsOwn: Bool = false
    var lastMessageSenderName: String?
    var lastActivity: Date?
    var unreadMessages: UInt64
    var unreadNotifications: UInt64
    var unreadMentions: UInt64
    var isMarkedUnread: Bool
    /// Notification mode set to Mute: surfaces only real mentions, no unread
    /// pip, capsule, or dock contribution otherwise.
    var isMuted: Bool = false
    var isFavourite: Bool = false
    var isLowPriority: Bool = false
    var hasActiveCall: Bool = false
    /// User ids currently in the room's call (MatrixRTC members), for Discord-
    /// style participant avatars in the list. Live-only; not persisted.
    var callParticipantIds: [String] = []
    /// The other party in a DM (first room hero), for presence.
    var dmUserId: String?
    /// Pending invite awaiting accept/decline.
    var isInvited: Bool = false
    var inviterName: String?

    /// Notification-level unread (bold name + count capsule). A muted room
    /// reaches this only via a real mention.
    var hasUnread: Bool {
        if isMuted { return unreadMentions > 0 }
        return unreadNotifications > 0 || unreadMentions > 0 || isMarkedUnread
    }

    /// Any unread indication for aggregation, including the dim "unread
    /// messages, no notification" state; never for a muted room without a mention.
    var hasAnyUnread: Bool {
        hasUnread || (!isMuted && unreadMessages > 0)
    }

    /// A real mention is waiting; shown even when the room is muted.
    var isMentioned: Bool { unreadMentions > 0 }

    /// Unread capsule count, summed into the dock badge. Muted rooms contribute
    /// only their mention count.
    var badgeCount: UInt64 { isMuted ? unreadMentions : unreadNotifications }

    /// Fold queries with this too so comparisons against `foldedName` line up.
    static func foldedForSearch(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// Codable for the sidebar's cold-launch snapshot. `foldedName` is left out
/// and recomputed on decode: folding is locale-sensitive, so a persisted value
/// could go stale and break search.
extension RoomSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, avatarURL, topic, isDirect, isSpace, isVideoRoom,
             isEncrypted, lastMessagePreview, lastMessageIsOwn,
             lastMessageSenderName, lastActivity, unreadMessages,
             unreadNotifications, unreadMentions, isMarkedUnread,
             isMuted, isFavourite, isLowPriority,
             hasActiveCall, dmUserId, isInvited, inviterName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        isDirect = try container.decode(Bool.self, forKey: .isDirect)
        isSpace = try container.decode(Bool.self, forKey: .isSpace)
        isVideoRoom = try container.decode(Bool.self, forKey: .isVideoRoom)
        isEncrypted = try container.decode(Bool.self, forKey: .isEncrypted)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastMessageIsOwn = try container.decode(Bool.self, forKey: .lastMessageIsOwn)
        lastMessageSenderName = try container.decodeIfPresent(String.self, forKey: .lastMessageSenderName)
        lastActivity = try container.decodeIfPresent(Date.self, forKey: .lastActivity)
        unreadMessages = try container.decode(UInt64.self, forKey: .unreadMessages)
        unreadNotifications = try container.decode(UInt64.self, forKey: .unreadNotifications)
        unreadMentions = try container.decode(UInt64.self, forKey: .unreadMentions)
        isMarkedUnread = try container.decode(Bool.self, forKey: .isMarkedUnread)
        // Tolerate snapshots predating these fields.
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isFavourite = try container.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        isLowPriority = try container.decodeIfPresent(Bool.self, forKey: .isLowPriority) ?? false
        hasActiveCall = try container.decode(Bool.self, forKey: .hasActiveCall)
        dmUserId = try container.decodeIfPresent(String.self, forKey: .dmUserId)
        isInvited = try container.decode(Bool.self, forKey: .isInvited)
        inviterName = try container.decodeIfPresent(String.self, forKey: .inviterName)
        foldedName = Self.foldedForSearch(name)
    }
}
