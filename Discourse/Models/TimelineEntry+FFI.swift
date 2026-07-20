import Foundation
@preconcurrency import MatrixRustSDK

/// Hashable wrapper for the FFI `MediaSource` class so plain models can carry it.
struct MediaSourceBox: Hashable {
    let source: MediaSource
    let url: String

    init(_ source: MediaSource) {
        self.source = source
        self.url = source.url()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Hashable wrapper retaining the FFI provider so the shield can be computed
/// lazily (per row, on appear). Identity is the owning timeline item.
struct ShieldProviderBox: Hashable {
    let provider: LazyTimelineItemProvider
    private let itemId: String

    init(provider: LazyTimelineItemProvider, itemId: String) {
        self.provider = provider
        self.itemId = itemId
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.itemId == rhs.itemId }
    func hash(into hasher: inout Hasher) { hasher.combine(itemId) }

    /// Runs the shield computation; the FFI provider is Sendable, so this is
    /// safe off the main actor.
    func warning() -> MessageItem.ShieldWarning? {
        TimelineEntry.shieldWarning(from: provider.getShields(strict: false))
    }
}

struct AudioItem: Hashable {
    var filename: String
    var duration: TimeInterval?
    var isVoiceMessage: Bool
    /// 0…1 normalised waveform, when the sender provided one.
    var waveform: [Float]
    var source: MediaSourceBox
}

struct ImageItem: Hashable {
    var filename: String
    var caption: String?
    var width: Double?
    var height: Double?
    var source: MediaSourceBox
    /// Stickers render smaller and without the open-externally affordance.
    var isSticker: Bool = false
    /// Blurhash from the event's `ImageInfo`, decoded as a placeholder while
    /// the thumbnail loads.
    var blurhash: String?

    /// The event declared usable pixel dimensions.
    var hasKnownSize: Bool {
        if let width, let height, width >= 1, height >= 1 { return true }
        return false
    }

    /// Display size clamped to an inline footprint.
    var displaySize: CGSize {
        let maxWidth = isSticker ? 160.0 : 360.0
        let maxHeight = isSticker ? 160.0 : 280.0
        // >= 1 also guards against degenerate metadata.
        guard let width, let height, width >= 1, height >= 1 else {
            // Unknown dimensions: square placeholder for stickers; the view
            // letterboxes rather than crops.
            return isSticker ? CGSize(width: 160, height: 160)
                             : CGSize(width: 240, height: 180)
        }
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return CGSize(width: max(40, width * scale), height: max(40, height * scale))
    }
}

extension MessageItem {
    var ffiItemId: EventOrTransactionId? {
        if let eventId { return .eventId(eventId: eventId) }
        if let transactionId { return .transactionId(transactionId: transactionId) }
        return nil
    }
}

extension TimelineEntry {
    /// The signed-in user, for marking own poll votes. Written only from the
    /// main actor, before mapping.
    nonisolated(unsafe) static var currentOwnUserId = ""

    /// Maps every SDK item to exactly one entry (never drops items) so the
    /// array stays index-aligned with the diff stream.
    init(ffi item: TimelineItem) {
        let uid = item.uniqueId().id
        if let event = item.asEvent() {
            self.init(uid: uid, event: event)
        } else if let virtualItem = item.asVirtual() {
            switch virtualItem {
            case .dateDivider(let ts):
                self = .dayDivider(id: uid, date: Date(timeIntervalSince1970: Double(ts) / 1000))
            case .readMarker:
                self = .readMarker(id: uid)
            case .timelineStart:
                self = .timelineStart(id: uid)
            default:
                self = .hidden(id: uid)
            }
        } else {
            self = .hidden(id: uid)
        }
    }

    private init(uid: String, event: EventTimelineItem) {
        var senderName: String?
        var senderAvatar: String?
        if case .ready(let displayName, _, let avatarUrl) = event.senderProfile {
            senderName = displayName
            senderAvatar = avatarUrl
        }

        switch event.content {
        case .msgLike(let msgLike):
            var eventId: String?
            var transactionId: String?
            switch event.eventOrTransactionId {
            case .eventId(let id): eventId = id
            case .transactionId(let id): transactionId = id
            }

            let sendState: MessageItem.SendState? = switch event.localSendState {
            case .notSentYet: .sending
            case .sendingFailed: .failed
            default: nil
            }

            let kind = Self.kind(of: msgLike)
            self = .message(MessageItem(
                id: uid,
                eventId: eventId,
                transactionId: transactionId,
                sender: event.sender,
                senderDisplayName: senderName,
                senderAvatarURL: senderAvatar,
                threadInfo: msgLike.threadSummary.map {
                    MessageItem.ThreadInfo(replyCount: $0.numReplies())
                },
                replyPreview: msgLike.inReplyTo.map { Self.replyPreview(from: $0) },
                isOwn: event.isOwn,
                timestamp: Date(timeIntervalSince1970: Double(event.timestamp) / 1000),
                kind: kind,
                isEdited: Self.isEdited(msgLike),
                reactions: msgLike.reactions.map {
                    MessageReaction(key: $0.key, senders: $0.senders.map(\.senderId))
                },
                inlineEmotes: Self.inlineEmotes(of: msgLike),
                sendState: sendState,
                canBeRepliedTo: event.canBeRepliedTo,
                readReceiptUserIds: event.readReceipts.keys
                    .filter { $0 != Self.currentOwnUserId }
                    .sorted(),
                shieldProvider: ShieldProviderBox(provider: event.lazyProvider, itemId: uid)
            ))

        case .roomMembership(let userId, let userDisplayName, let change, _):
            let name = userDisplayName ?? userId
            self = .system(id: uid, text: Self.membershipText(name: name, change: change))

        case .profileChange(let displayName, let prevDisplayName, _, _):
            let text = if let displayName, let prevDisplayName, displayName != prevDisplayName {
                "\(prevDisplayName) is now known as \(displayName)"
            } else {
                "\(displayName ?? senderName ?? "Someone") updated their profile"
            }
            self = .system(id: uid, text: text)

        case .state:
            self = .system(id: uid, text: "\(senderName ?? "Someone") updated the room")

        case .callInvite, .rtcNotification:
            self = .system(id: uid, text: "\(senderName ?? "Someone") started a call")

        case .failedToParseMessageLike, .failedToParseState:
            self = .hidden(id: uid)
        }
    }

    fileprivate static func shieldWarning(from state: ShieldState) -> MessageItem.ShieldWarning? {
        let (level, code): (MessageItem.ShieldWarning.Level, TimelineEventShieldStateCode)
        switch state {
        case .red(let c): (level, code) = (.red, c)
        case .grey(let c):
            // Keys restored from backup or forwarded between own sessions carry
            // this harmlessly; flagging it would train users to ignore the
            // shields that matter.
            if c == .authenticityNotGuaranteed { return nil }
            (level, code) = (.grey, c)
        case .none: return nil
        }
        let text = switch code {
        case .sentInClear:
            String(localized: "Not encrypted")
        case .unverifiedIdentity:
            String(localized: "Encrypted by an unverified user")
        case .unsignedDevice:
            String(localized: "Encrypted by a device not verified by its owner")
        case .unknownDevice:
            String(localized: "Encrypted by an unknown or deleted device")
        case .authenticityNotGuaranteed:
            String(localized: "The authenticity of this encrypted message can't be guaranteed on this device")
        case .verificationViolation:
            String(localized: "The sender's verified identity has changed")
        case .mismatchedSender:
            String(localized: "The sender doesn't match the device that encrypted this message")
        }
        return MessageItem.ShieldWarning(level: level, text: text)
    }

    private static func replyPreview(from details: InReplyToDetails) -> MessageItem.ReplyPreview {
        let eventId = details.eventId()
        switch details.event() {
        case .ready(let content, let sender, let senderProfile, _, _):
            var name = sender
            if case .ready(let displayName, _, _) = senderProfile, let displayName {
                name = displayName
            }
            return MessageItem.ReplyPreview(
                eventId: eventId,
                senderName: name,
                snippet: RoomSummary.previewText(from: content) ?? "…"
            )
        case .pending, .unavailable:
            return MessageItem.ReplyPreview(eventId: eventId, senderName: "", snippet: "…")
        case .error:
            return MessageItem.ReplyPreview(eventId: eventId, senderName: "",
                                            snippet: String(localized: "Message unavailable"))
        }
    }

    private static func kind(of msgLike: MsgLikeContent) -> MessageItem.Kind {
        switch msgLike.kind {
        case .message(let message):
            switch message.msgType {
            case .text: .text(message.body)
            case .notice: .notice(message.body)
            case .emote: .emote(message.body)
            case .image(let content): .image(ImageItem(
                filename: content.filename,
                caption: content.caption,
                // Explicit closure: `.map(Double.init)` resolves to the UInt64
                // bit-pattern initializer and produces garbage.
                width: content.info?.width.map { Double($0) },
                height: content.info?.height.map { Double($0) },
                source: MediaSourceBox(content.source),
                blurhash: content.info?.blurhash
            ))
            case .video(let content): .media(label: content.filename, systemImage: "video")
            case .audio(let content): .audio(AudioItem(
                filename: content.filename,
                duration: content.info?.duration ?? content.audio?.duration,
                isVoiceMessage: content.voice != nil,
                waveform: (content.audio?.waveform ?? []).map { Float($0) / 1024 },
                source: MediaSourceBox(content.source)
            ))
            case .file(let content): .media(label: content.filename, systemImage: "doc")
            case .gallery: .media(label: "Gallery", systemImage: "photo.on.rectangle")
            case .location(let content): .location(body: content.body, geoUri: content.geoUri)
            case .other(_, let body): .text(body)
            }
        case .sticker(let body, let info, let source):
            .image(ImageItem(
                filename: body,
                caption: nil,
                width: info.width.map { Double($0) },
                height: info.height.map { Double($0) },
                source: MediaSourceBox(source),
                isSticker: true
            ))
        case .poll(let question, let pollKind, let maxSelections, let answers, let votes, let endTime, _):
            .poll(PollItem(
                question: question,
                answers: answers.map { answer in
                    let voters = votes[answer.id] ?? []
                    return PollItem.Answer(id: answer.id,
                                           text: answer.text,
                                           voteCount: voters.count,
                                           votedByMe: voters.contains(Self.currentOwnUserId))
                },
                maxSelections: Int(maxSelections),
                isDisclosed: pollKind == .disclosed,
                isEnded: endTime != nil
            ))
        case .redacted:
            .redacted
        case .unableToDecrypt:
            .unableToDecrypt
        case .other:
            .unsupported("Unsupported event")
        case .liveLocation:
            .media(label: "Live location", systemImage: "location.fill")
        }
    }

    /// Custom emoji (MSC2545 `<img data-mx-emoticon>`) as a `":shortcode:" →
    /// mxc URL` map. Only text-ish messages carry HTML.
    private static func inlineEmotes(of msgLike: MsgLikeContent) -> [String: String] {
        guard case .message(let message) = msgLike.kind else { return [:] }
        let formatted: FormattedBody? = switch message.msgType {
        case .text(let content): content.formatted
        case .notice(let content): content.formatted
        case .emote(let content): content.formatted
        default: nil
        }
        guard let formatted, formatted.format == .html else { return [:] }
        return InlineEmotes.parse(html: formatted.body)
    }

    private static func isEdited(_ msgLike: MsgLikeContent) -> Bool {
        if case .message(let message) = msgLike.kind { return message.isEdited }
        return false
    }

    private static func membershipText(name: String, change: MembershipChange?) -> String {
        switch change {
        case .joined: String(localized: "\(name) joined the room")
        case .left: String(localized: "\(name) left the room")
        case .invited: String(localized: "\(name) was invited")
        case .invitationAccepted: String(localized: "\(name) accepted the invitation")
        case .invitationRejected: String(localized: "\(name) declined the invitation")
        case .banned, .kickedAndBanned: String(localized: "\(name) was banned")
        case .unbanned: String(localized: "\(name) was unbanned")
        case .kicked: String(localized: "\(name) was removed")
        case .knocked: String(localized: "\(name) requested to join")
        default: String(localized: "\(name)'s membership changed")
        }
    }
}
