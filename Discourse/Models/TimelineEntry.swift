import Foundation

/// One row in the conversation, index-aligned 1:1 with the SDK's timeline
/// items; even "hidden" items get an entry so positional diffs stay valid.
enum TimelineEntry: Identifiable, Hashable {
    case message(MessageItem)
    case system(id: String, text: String)
    case dayDivider(id: String, date: Date)
    case readMarker(id: String)
    case timelineStart(id: String)
    /// Items we never render (unknown virtual items, filtered event types).
    case hidden(id: String)

    var id: String {
        switch self {
        case .message(let item): item.id
        case .system(let id, _): id
        case .dayDivider(let id, _): id
        case .readMarker(let id): id
        case .timelineStart(let id): id
        case .hidden(let id): id
        }
    }
}

struct MessageItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(String)
        case notice(String)
        case emote(String)
        case image(ImageItem)
        case video(VideoItem)
        case poll(PollItem)
        case audio(AudioItem)
        case location(body: String, geoUri: String)
        /// Non-image attachments render as a labeled chip.
        case media(label: String, systemImage: String)
        case redacted
        case unableToDecrypt
        case unsupported(String)
    }

    enum SendState: Hashable {
        case sending
        case failed
    }

    struct ThreadInfo: Hashable {
        var replyCount: UInt64
    }

    struct ReplyPreview: Hashable {
        var eventId: String
        var senderName: String
        var snippet: String
        /// The replied-to event's details aren't loaded yet (the SDK resolves
        /// them lazily); the view model fetches them so the snippet fills in.
        var isPending: Bool = false
    }

    /// Per-message encryption warning (e.g. sent unencrypted in an E2EE room,
    /// unverified sender).
    struct ShieldWarning: Hashable {
        enum Level: Hashable { case red, grey }
        var level: Level
        var text: String
    }

    let id: String
    var eventId: String?
    var transactionId: String?
    var sender: String
    var senderDisplayName: String?
    var senderAvatarURL: String?
    /// Present when this message is the root of a thread.
    var threadInfo: ThreadInfo?
    /// Present when this message replies to another.
    var replyPreview: ReplyPreview?
    var isOwn: Bool
    var timestamp: Date
    var kind: Kind
    var isEdited: Bool
    var reactions: [MessageReaction]
    /// MSC2545 custom emoji in this message's formatted body, as
    /// `":shortcode:" → mxc URL`. Rendering swaps the plain-body tokens for images.
    var inlineEmotes: [String: String] = [:]
    var sendState: SendState?
    var canBeRepliedTo: Bool
    /// Other users whose latest read receipt sits on this event; their avatars
    /// ride this row and move down as they read.
    var readReceiptUserIds: [String] = []
    /// Fetches the encryption shield lazily (on appear). Computing it during
    /// diff mapping forced crypto work for every item on every diff.
    var shieldProvider: ShieldProviderBox?
    /// First message of a sender group shows avatar + name + timestamp.
    var showsHeader: Bool = true

    var displayName: String { senderDisplayName ?? sender }
}

struct PollItem: Hashable {
    struct Answer: Hashable, Identifiable {
        let id: String
        var text: String
        var voteCount: Int
        var votedByMe: Bool
    }

    var question: String
    var answers: [Answer]
    var maxSelections: Int
    /// Disclosed polls show live results; undisclosed only at the end.
    var isDisclosed: Bool
    var isEnded: Bool
    var totalVotes: Int { answers.reduce(0) { $0 + $1.voteCount } }
    var votedByMe: Bool { answers.contains(where: \.votedByMe) }
}

struct MessageReaction: Hashable {
    var key: String
    var senders: [String]

    var count: Int { senders.count }
    func includesOwn(userId: String) -> Bool { senders.contains(userId) }
}
