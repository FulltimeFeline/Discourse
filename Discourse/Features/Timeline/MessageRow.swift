import SwiftUI

/// A flat message row: header rows carry avatar + name + timestamp, grouped
/// rows are text-only with a hover timestamp in the avatar gutter.
struct MessageRow: View {
    let message: MessageItem
    let viewModel: TimelineViewModel
    var openThread: (String) -> Void = { _ in }
    var openProfile: (ProfileTarget) -> Void = { _ in }
    var jumpToEvent: (String) -> Void = { _ in }
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var prefs
    @Environment(\.pronounsStore) private var pronounsStore
    @State private var isHovering = false

    private var scope: SessionScope? {
        if case .active(let scope) = appState.phase { return scope }
        return nil
    }

    private var customEmoji: CustomEmojiStore? { scope?.customEmoji }

    /// Own messages show live profile edits at once, before sync echoes the new
    /// member state back into the timeline.
    private var effectiveName: String {
        if message.isOwn, let name = scope?.ownDisplayName, !name.isEmpty { return name }
        return message.displayName
    }

    private var effectiveAvatarURL: String? {
        message.isOwn ? scope?.ownAvatarURL : message.senderAvatarURL
    }

    private var profileTarget: ProfileTarget {
        ProfileTarget(userId: message.sender,
                      displayName: message.isOwn ? scope?.ownDisplayName : message.senderDisplayName,
                      avatarURL: effectiveAvatarURL)
    }

    /// Intercepts taps on `matrix.to` user links (mention pills) to open the
    /// member's profile in-app instead of launching the browser. Other links
    /// fall through to the system.
    private var mentionURLAction: OpenURLAction {
        OpenURLAction { url in
            if let userId = MentionParser.userId(fromMatrixTo: url.absoluteString) {
                let name = message.mentions.first { $0.userId == userId }?.text
                openProfile(ProfileTarget(userId: userId, displayName: name, avatarURL: nil))
                return .handled
            }
            return .systemAction
        }
    }

    private let gutterWidth: CGFloat = 40
    /// Built once; a FormatStyle per hover render hits locale lookup. Locale
    /// am/pm form, used when `use24HourTime` is off.
    static let hourMinuteFormat = Date.FormatStyle.dateTime.hour().minute()
    /// Forced 24-hour form.
    static let hourMinute24Format = Date.FormatStyle.dateTime
        .hour(.twoDigits(amPM: .omitted)).minute()
    private var hourMinuteFormat: Date.FormatStyle {
        prefs.use24HourTime ? Self.hourMinute24Format : Self.hourMinuteFormat
    }
    @State private var showsReactionPicker = false
    @State private var showsShieldInfo = false
    @State private var showsReportPrompt = false
    @State private var reportReason = ""
    @State private var reportResult: ReportResult?
    /// Retry/Delete choices behind the red failure icon.
    @State private var showsFailedSendOptions = false
    /// Gated behind the "Confirm before deleting" preference.
    @State private var showsDeleteConfirm = false

    /// Whether to offer "Delete Message": own messages need redact-own power,
    /// others need redact-other (a moderator deleting someone else's message).
    private var canDelete: Bool {
        message.isOwn ? viewModel.canRedactOwn : viewModel.canRedactOther
    }

    /// Deletes now, or asks first when the preference is on.
    private func requestDelete() {
        if prefs.confirmBeforeDeleting {
            showsDeleteConfirm = true
        } else {
            viewModel.redact(message)
        }
    }

    private struct ReportResult {
        var message: String
        var isSuccess: Bool
    }
    #if os(iOS)
    /// Temp-file URL driving the share sheet for image rows.
    @State private var imageShareFile: ImageShareFile?
    /// Swipe-to-reply: leftward drag offset of the row content.
    @State private var replyDragOffset: CGFloat = 0
    /// Whether the drag is past the reply threshold.
    @State private var replyDragTriggered = false
    /// Latched once a drag is recognised as clearly horizontal.
    @State private var isSwipingToReply = false
    #endif
    /// Learned from usage. Custom-emote keys are excluded at record time, but
    /// filter defensively — the palette only draws unicode emoji.
    private var quickReactions: [String] {
        ReactionUsage.top(5).filter { !$0.hasPrefix("mxc://") }
    }

    /// Fetched lazily (see `loadShieldIfNeeded`); nil until it lands, and for
    /// messages without a warning (the common case).
    private var shield: MessageItem.ShieldWarning? {
        message.eventId.flatMap { viewModel.shields[$0] }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            gutter
            VStack(alignment: .leading, spacing: 2) {
                if message.showsHeader {
                    header
                }
                if let reply = message.replyPreview {
                    Button {
                        jumpToEvent(reply.eventId)
                    } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.tint.opacity(0.85))
                            .frame(width: 2, height: 15)
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !reply.senderName.isEmpty {
                            Text(reply.senderName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Text(RenderedBodyCache.rendered(reply.snippet))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Jump to original message")
                    .padding(.bottom, 1)
                }
                if let shield {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Button {
                            showsShieldInfo = true
                        } label: {
                            Image(systemName: shield.level == .red
                                  ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(shield.level == .red
                                                 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(shield.text)
                        // The glyph alone is just "exclamation mark" to VoiceOver.
                        .accessibilityLabel(shield.text)
                        .popover(isPresented: $showsShieldInfo, arrowEdge: .bottom) {
                            Label(shield.text, systemImage: shield.level == .red
                                  ? "lock.open.trianglebadge.exclamationmark" : "lock.trianglebadge.exclamationmark")
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: 280)
                                // Stay a popover on iPhone, not a full-height sheet.
                                .presentationCompactAdaptation(.popover)
                        }
                        content
                            .environment(\.openURL, mentionURLAction)
                    }
                } else {
                    content
                        .environment(\.openURL, mentionURLAction)
                }
                if prefs.showEventIds, let eventId = message.eventId {
                    Text(eventId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !message.reactions.isEmpty {
                    ReactionChips(reactions: message.reactions,
                                  ownUserId: viewModel.ownUserId,
                                  loader: viewModel.mediaLoader,
                                  largerTapTargets: prefs.largerTapTargets,
                                  emoteLabel: { [weak customEmoji] key in
                                      customEmoji?.byUrl[key]?.token
                                  },
                                  nameFor: { userId in
                                      viewModel.membersById[userId]?.name
                                          ?? String(userId.dropFirst().prefix(while: { $0 != ":" }))
                                  },
                                  toggle: { key in toggleReaction(key) },
                                  onAddReaction: { showsReactionPicker = true })
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                }
                if let threadInfo = message.threadInfo, let eventId = message.eventId {
                    Button {
                        openThread(eventId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                            Text("\(threadInfo.replyCount) \(threadInfo.replyCount == 1 ? "reply" : "replies")")
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            VStack {
                Spacer(minLength: 0)
                if message.sendState == .failed {
                    // Tapping offers Retry/Delete.
                    Button {
                        showsFailedSendOptions = true
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Failed to send")
                    .accessibilityLabel("Failed to send. Retry or delete.")
                    .confirmationDialog("This message failed to send.",
                                        isPresented: $showsFailedSendOptions,
                                        titleVisibility: .visible) {
                        Button("Retry Send") {
                            viewModel.retrySend(message)
                        }
                        Button("Delete Message", role: .destructive) {
                            viewModel.redact(message)
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                } else if prefs.showReadReceipts, !message.readReceiptUserIds.isEmpty {
                    // Readers' avatars sit on the last row they've read.
                    ReadReceiptStack(userIds: message.readReceiptUserIds,
                                     viewModel: viewModel)
                } else if message.isOwn, message.eventId != nil,
                          message.sendState == nil,
                          message.id == viewModel.lastOwnMessageId {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .help("Sent")
                        .accessibilityLabel("Sent")
                }
            }
        }
        // Scoped by value so nothing else in the row animates.
        .animation(prefs.reduceMotion ? nil
                   : .spring(response: 0.28, dampingFraction: 0.75), value: message.reactions)
        // Generous gap above a new sender group, tight within one.
        .padding(.top, message.showsHeader
                 ? prefs.messageDensity.groupTopPadding
                 : prefs.messageDensity.rowVerticalPadding)
        .padding(.bottom, prefs.messageDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .background(
            isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovering = $0 }
        .opacity(message.sendState == .sending ? 0.55 : 1)
        // Keyed on event ID so local echoes fetch their shield once the real
        // ID lands via a `.set` diff (which doesn't refire onAppear).
        .task(id: message.eventId) {
            viewModel.loadShieldIfNeeded(for: message)
        }
        .contextMenu { contextMenuItems }
        .popover(isPresented: $showsReactionPicker, arrowEdge: .top) {
            EmojiPickerView(customPacks: customEmoji?.packs ?? [],
                            loader: viewModel.mediaLoader,
                            insertCustom: { emote in
                                showsReactionPicker = false
                                // Reaction key is the emote's mxc URL.
                                toggleReaction(emote.url)
                            }) { emoji in
                showsReactionPicker = false
                toggleReaction(emoji)
            }
            .task { await customEmoji?.refreshIfStale() }
            // On iPhone the popover adapts to a sheet; give it detents and a grabber.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Delete this message?", isPresented: $showsDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Message", role: .destructive) {
                viewModel.redact(message)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the message for everyone.")
        }
        .alert("Report Message", isPresented: $showsReportPrompt) {
            TextField("Reason (optional)", text: $reportReason)
            Button("Report", role: .destructive) {
                guard let eventId = message.eventId else { return }
                let reason = reportReason.trimmingCharacters(in: .whitespaces)
                reportReason = ""
                Task {
                    if let error = await viewModel.report(
                        eventId: eventId, reason: reason.isEmpty ? nil : reason) {
                        reportResult = ReportResult(message: error, isSuccess: false)
                    } else {
                        reportResult = ReportResult(
                            message: String(localized: "Your report was sent to the homeserver administrators."),
                            isSuccess: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reports this message to your homeserver administrators.")
        }
        .alert(reportResult?.isSuccess == true
               ? Text("Report Sent") : Text("Couldn't Report"),
               isPresented: Binding(
                   get: { reportResult != nil },
                   set: { if !$0 { reportResult = nil } }
               )) {
            Button("OK") { reportResult = nil }
        } message: {
            Text(reportResult?.message ?? "")
        }
        #if os(iOS)
        // Swipe-to-reply: the offset moves only the rendered content; the
        // glyph overlay stays pinned to the row's layout frame.
        .offset(x: replyDragOffset)
        .overlay(alignment: .trailing) {
            if replyDragOffset < 0 {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(replyDragTriggered
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .opacity(min(1, -replyDragOffset / Self.replyThreshold))
                    .padding(.trailing, 6)
            }
        }
        // Simultaneous so vertical scrolling always wins; engages only for
        // horizontal leftward drags. Leftward on purpose: the phone pager owns
        // rightward drags for closing the chat layer.
        .simultaneousGesture(replySwipeGesture)
        // Marks the reply threshold latching mid-drag; fires only on the
        // false→true edge, not on release/reset.
        .sensoryFeedback(.impact(weight: .medium), trigger: replyDragTriggered) { _, isTriggered in
            isTriggered
        }
        // onEnded doesn't fire on system cancellation (scroll takeover, context
        // menu); reset so a later drag's onEnded doesn't consume stale state.
        .onDisappear {
            replyDragOffset = 0
            replyDragTriggered = false
            isSwipingToReply = false
        }
        .sheet(item: $imageShareFile) { file in
            ActivityShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    private func toggleReaction(_ key: String) {
        viewModel.toggleReaction(key, on: message)
    }

    #if os(iOS)
    private static let replyThreshold: CGFloat = 48
    private static let replyCap: CGFloat = 64

    private var replySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if !isSwipingToReply {
                    // Horizontal leftward drags on replyable rows; anything
                    // else stays a scroll.
                    guard message.canBeRepliedTo,
                          value.translation.width < 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5
                    else { return }
                    isSwipingToReply = true
                    // A cancelled earlier drag may have left this latched.
                    replyDragTriggered = false
                }
                let magnitude = max(0, -value.translation.width)
                // Rubber-band past the threshold, hard cap at replyCap.
                let resisted = magnitude <= Self.replyThreshold
                    ? magnitude
                    : Self.replyThreshold + (magnitude - Self.replyThreshold) * 0.25
                replyDragOffset = -min(resisted, Self.replyCap)
                let past = magnitude >= Self.replyThreshold
                if past != replyDragTriggered {
                    replyDragTriggered = past
                }
            }
            .onEnded { _ in
                if replyDragTriggered {
                    viewModel.replyTarget = message
                }
                withAnimation(.pagerSettle) {
                    replyDragOffset = 0
                }
                replyDragTriggered = false
                isSwipingToReply = false
            }
    }

    private func shareImage(_ image: ImageItem) {
        Task {
            guard let url = await InlineImageView.temporaryFile(
                for: image, loader: viewModel.mediaLoader) else { return }
            imageShareFile = ImageShareFile(url: url)
        }
    }

    private func saveImageToPhotos(_ image: ImageItem) {
        Task {
            guard let data = await viewModel.mediaLoader.fullContent(for: image.source),
                  let uiImage = UIImage(data: data) else { return }
            UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
        }
    }
    #endif

    #if os(macOS)
    /// Puts the full-resolution image on the general pasteboard.
    private func copyImage(_ image: ImageItem) {
        Task {
            guard let data = await viewModel.mediaLoader.fullContent(for: image.source),
                  let nsImage = NSImage(data: data) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
    }

    /// NSSavePanel rather than fileExporter: runs straight from an async
    /// context-menu action, no presentation state threaded through the row.
    private func saveImage(_ image: ImageItem) {
        Task {
            guard let data = await viewModel.mediaLoader.fullContent(for: image.source) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = image.filename.isEmpty ? "image.png" : image.filename
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
    #endif

    @ViewBuilder
    private var gutter: some View {
        if message.showsHeader {
            if prefs.showAvatarsInTimeline {
                // A tap, not a Button: a Button stays pressed through a pager
                // swipe starting here and fires on release, opening the profile
                // mid-close. TapGesture fails as soon as the finger moves.
                RoomAvatarView(name: effectiveName, isDirect: true, size: gutterWidth,
                               avatarURL: effectiveAvatarURL)
                    .contentShape(Circle())
                    .onTapGesture { openProfile(profileTarget) }
                    #if os(macOS)
                    .pointerStyle(.link)
                    #endif
                    .help("View profile")
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text("View profile of \(effectiveName)"))
                    .accessibilityAction { openProfile(profileTarget) }
            } else {
                // Avatars hidden: keep the gutter width so rows stay aligned.
                Color.clear
                    .frame(width: gutterWidth, height: 1)
                    .accessibilityHidden(true)
            }
        } else {
            // With `alwaysShowTimestamps` the time shows without hover — the
            // only way touch users see it inline.
            Text(isHovering || prefs.alwaysShowTimestamps
                 ? message.timestamp.formatted(hourMinuteFormat) : "")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                // Hover-only; the timestamp lives in the context menu for a11y.
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Tap, not Button (see gutter): a swipe starting on the name must
            // not open the profile on release.
            Group {
                Text(effectiveName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(senderColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture { openProfile(profileTarget) }
                    #if os(macOS)
                    .pointerStyle(.link)
                    #endif
                    .help("View profile")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openProfile(profileTarget) }
            }
            if let pronouns = pronounsStore?.pronouns(for: message.sender) {
                Text(pronouns)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(message.timestamp, format: timestampFormat)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// Declared emotes plus store-known tokens in the body; the fallback
    /// covers messages whose HTML never reached us (stripped formatted bodies,
    /// sends before the pack loaded, plain-only clients). Declared URLs win.
    private func effectiveEmotes(in body: String) -> [String: String] {
        guard let customEmoji else { return message.inlineEmotes }
        var map = customEmoji.knownEmotes(in: body)
        map.merge(message.inlineEmotes) { _, declared in declared }
        return map
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text(let body):
            let emotes = effectiveEmotes(in: body)
            if body.hasPrefix(">") || body.contains("\n>") {
                // Markdown blockquotes: `>`-prefixed lines render as a quote.
                attributed(QuotedBodyView(rawBody: body, emotes: emotes, loader: viewModel.mediaLoader,
                                          jumboEmoji: prefs.jumboEmoji, fontScale: fontScale,
                                          font: scaledBodyFont), spokenBody: body)
            } else if emotes.isEmpty {
                if prefs.jumboEmoji, Self.isJumboEmoji(body) {
                    attributed(Text(verbatim: body).font(.system(size: jumboFontSize)) + editedSuffix,
                               spokenBody: body)
                } else {
                    attributed(Text(RenderedBodyCache.rendered(body, mentions: message.mentions, ownUserId: viewModel.ownUserId)).font(scaledBodyFont) + editedSuffix,
                               spokenBody: body)
                }
            } else {
                attributed(EmoteBodyText(body_: body, emotes: emotes,
                              loader: viewModel.mediaLoader, suffix: editedSuffix,
                              jumboEmoji: prefs.jumboEmoji, fontScale: fontScale)
                        .font(scaledBodyFont),
                           spokenBody: body)
            }
        case .notice(let body):
            let emotes = effectiveEmotes(in: body)
            if emotes.isEmpty {
                attributed((Text(RenderedBodyCache.rendered(body, mentions: message.mentions, ownUserId: viewModel.ownUserId)).font(scaledBodyFont) + editedSuffix)
                    .foregroundStyle(.secondary), spokenBody: body)
            } else {
                attributed(EmoteBodyText(body_: body, emotes: emotes,
                              loader: viewModel.mediaLoader, suffix: editedSuffix,
                              jumboEmoji: prefs.jumboEmoji, fontScale: fontScale)
                    .font(scaledBodyFont)
                    .foregroundStyle(.secondary), spokenBody: body)
            }
        case .emote(let body):
            let emotes = effectiveEmotes(in: body)
            if emotes.isEmpty {
                Text(RenderedBodyCache.rendered("\(message.displayName) \(body)"))
                    .font(scaledBodyFont)
                    .italic()
            } else {
                EmoteBodyText(body_: "\(message.displayName) \(body)",
                              emotes: emotes,
                              loader: viewModel.mediaLoader,
                              jumboEmoji: prefs.jumboEmoji, fontScale: fontScale)
                    .font(scaledBodyFont)
                    .italic()
            }
        case .image(let image):
            InlineImageView(image: image, loader: viewModel.mediaLoader)
        case .video(let video):
            VideoAttachmentView(video: video, loader: viewModel.mediaLoader)
        case .poll(let poll):
            PollView(poll: poll, message: message, viewModel: viewModel)
        case .audio(let audio):
            VoiceMessageView(itemId: message.id, audio: audio, loader: viewModel.mediaLoader,
                             controller: viewModel.audioPlayback)
        case .location(let body, let geoUri):
            Button {
                let coords = geoUri.dropFirst(4).split(separator: ";").first.map(String.init) ?? ""
                if let url = URL(string: "https://maps.apple.com/?ll=\(coords)&q=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Location")") {
                    Platform.openURL(url)
                }
            } label: {
                Label(body.isEmpty ? String(localized: "Shared location") : body,
                      systemImage: "mappin.and.ellipse")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open in Maps")
        case .media(let label, let systemImage):
            Label(label, systemImage: systemImage)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .redacted:
            Text("Message deleted")
                .italic()
                .foregroundStyle(.tertiary)
        case .unableToDecrypt:
            Label("Waiting for this message to decrypt…", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        case .unsupported(let label):
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func attributed<V: View>(_ view: V, spokenBody: String) -> some View {
        if message.showsHeader {
            view
        } else {
            // Grouped rows have no header and a hidden gutter; VoiceOver needs
            // the sender spoken with the body.
            view
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(message.displayName): \(spokenBody)\(message.isEdited ? ", edited" : "")"))
        }
    }

    /// Clamped copy of the preference; guards out-of-range persisted values.
    private var fontScale: Double { min(max(prefs.chatFontScale, 0.8), 1.4) }

    /// The body font, scaled by `chatFontScale`. At the default 1.0 this is
    /// exactly `.body` (preserving Dynamic Type); off-default it uses a scaled
    /// point size.
    private var scaledBodyFont: Font {
        fontScale == 1.0 ? .body : .system(size: 17 * fontScale, weight: .regular)
    }

    /// Size for the unicode jumbo path, scaled with the body preference.
    private var jumboFontSize: CGFloat { 44 * fontScale }

    /// True for short messages that are nothing but emoji (and whitespace).
    /// Excludes digits/#/* (emoji-adjacent scalars below 0x2380) so "123"
    /// stays text.
    static func isJumboEmoji(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8 else { return false }
        return trimmed.allSatisfy { character in
            if character.isWhitespace { return true }
            guard let first = character.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation
                || character.unicodeScalars.contains { $0.value == 0xFE0F }
                || (first.properties.isEmoji && first.value > 0x2380)
        }
    }

    private var editedSuffix: Text {
        message.isEdited
            ? Text(" (edited)").font(.caption).foregroundStyle(.tertiary)
            : Text(verbatim: "")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Most-used reactions as a palette row. Palette items only render
        // images on macOS, so rasterise the emoji.
        ControlGroup {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    toggleReaction(emoji)
                } label: {
                    Image(platformImage: EmojiImageCache.image(for: emoji))
                }
            }
        }
        .controlGroupStyle(.palette)
        #if os(iOS)
        // The gutter timestamp is hover-only; this is how touch gets it.
        Button("Sent at \(message.timestamp.formatted(timestampFormat))",
               systemImage: "clock") {}
            .disabled(true)
        #endif
        Button("More Reactions…", systemImage: "face.smiling") {
            showsReactionPicker = true
        }
        Divider()
        Button("View Profile", systemImage: "person.crop.circle") {
            openProfile(profileTarget)
        }
        if message.canBeRepliedTo {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                viewModel.replyTarget = message
            }
        }
        if message.isOwn, message.eventId != nil, case .text = message.kind {
            Button("Edit Message", systemImage: "pencil") {
                viewModel.replyTarget = nil
                viewModel.editTarget = message
            }
        }
        if viewModel.mode == .live, let eventId = message.eventId {
            Button("Reply in Thread", systemImage: "bubble.left.and.text.bubble.right") {
                openThread(eventId)
            }
        }
        Divider()
        if case .text(let body) = message.kind {
            Button("Copy Text", systemImage: "doc.on.doc") {
                Platform.copyToClipboard(body)
            }
            ShareLink(item: body) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        #if os(iOS)
        if case .image(let image) = message.kind {
            Button("Share Image…", systemImage: "square.and.arrow.up") {
                shareImage(image)
            }
            Button("Save Image", systemImage: "square.and.arrow.down") {
                saveImageToPhotos(image)
            }
        }
        #endif
        #if os(macOS)
        if case .image(let image) = message.kind {
            Button("Copy Image", systemImage: "doc.on.doc") {
                copyImage(image)
            }
            Button("Save Image…", systemImage: "square.and.arrow.down") {
                saveImage(image)
            }
            ShareLink(item: TimelineImageTransfer(image: image, loader: viewModel.mediaLoader),
                      preview: SharePreview(image.filename.isEmpty
                          ? String(localized: "Image") : image.filename)) {
                Label("Share Image…", systemImage: "square.and.arrow.up")
            }
        }
        #endif
        if let eventId = message.eventId {
            Button("Copy Event ID", systemImage: "number") {
                Platform.copyToClipboard(eventId)
            }
        }
        if message.isOwn {
            Divider()
            if message.sendState == .failed {
                Button("Retry Send", systemImage: "arrow.clockwise") {
                    viewModel.retrySend(message)
                }
            }
            if viewModel.canCancelSend(message) {
                Button("Cancel Upload", systemImage: "xmark.circle") {
                    viewModel.cancelSend(message)
                }
            }
            if canDelete {
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    requestDelete()
                }
            }
        } else if message.eventId != nil {
            Divider()
            // Moderators can delete other people's messages too.
            if canDelete {
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    requestDelete()
                }
            }
            Button("Report Message…", systemImage: "flag", role: .destructive) {
                showsReportPrompt = true
            }
        }
    }

    /// Static: building Calendar/FormatStyle per header render hit locale
    /// lookup on every row.
    private static let calendar = Calendar.current
    private static let earlierTimestampFormat =
        Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
    /// 24-hour variant of the earlier-day format.
    private static let earlierTimestamp24Format =
        Date.FormatStyle.dateTime.month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute()

    private var timestampFormat: Date.FormatStyle {
        if Self.calendar.isDateInToday(message.timestamp) {
            return hourMinuteFormat
        }
        return prefs.use24HourTime ? Self.earlierTimestamp24Format : Self.earlierTimestampFormat
    }

    private var senderColor: Color {
        guard prefs.coloredSenderNames else { return .primary }
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .teal, .green]
        var hash = 0
        for scalar in message.sender.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return palette[abs(hash) % palette.count]
    }
}

/// Renders inline markdown plus bare-URL detection; links come out
/// accent-tinted, underlined, and clickable. Cached per raw body —
/// parsing + link detection ran per row per render otherwise.
@MainActor
enum RenderedBodyCache {
    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func rendered(_ body: String,
                         mentions: [MentionRef] = [],
                         ownUserId: String? = nil) -> AttributedString {
        // Mentions/self-highlight vary the styling, so they're part of the key.
        let key: NSString = mentions.isEmpty
            ? body as NSString
            : "\(body)\u{1}\(ownUserId ?? "")\u{1}\(mentions.map { "\($0.userId)=\($0.text)" }.joined(separator: "\u{2}"))" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var attributed = (try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(body)

        // Turn mention display text (carried plainly in the body by clients that
        // put the matrix.to link only in the HTML) into tappable pill links.
        for mention in mentions {
            guard let url = URL(string: "https://matrix.to/#/\(mention.userId)"),
                  let range = attributed.range(of: mention.text),
                  attributed[range].runs.allSatisfy({ $0.link == nil }) else { continue }
            attributed[range].link = url
        }

        // Bare URLs the markdown pass missed. The rendered characters differ
        // from `body` (syntax stripped), so detect over the rendered text.
        if let linkDetector {
            let plain = String(attributed.characters)
            let length = (plain as NSString).length
            for match in linkDetector.matches(in: plain, range: NSRange(location: 0, length: length)) {
                guard let url = match.url,
                      let range = Range(match.range, in: attributed),
                      attributed[range].runs.allSatisfy({ $0.link == nil }) else { continue }
                attributed[range].link = url
            }
        }

        // One styling pass over every link, authored or detected. Mentions
        // (matrix.to user links) render as tinted pills, not underlined links;
        // a mention of the current user gets a stronger highlight.
        for run in attributed.runs where run.link != nil {
            if let mentionedId = run.link.flatMap({ MentionParser.userId(fromMatrixTo: $0.absoluteString) }) {
                attributed[run.range].foregroundColor = .accentColor
                attributed[run.range].backgroundColor = .accentColor.opacity(
                    mentionedId == ownUserId ? 0.30 : 0.15)
                attributed[run.range].inlinePresentationIntent = .stronglyEmphasized
            } else {
                attributed[run.range].foregroundColor = .accentColor
                attributed[run.range].underlineStyle = .single
            }
        }
        cache.setObject(Box(attributed), forKey: key)
        return attributed
    }
}

/// Rasterises emoji for contexts (menu palettes) that only render images.
@MainActor
enum EmojiImageCache {
    private static var cache: [String: PlatformImage] = [:]

    static func image(for emoji: String, pointSize: CGFloat = 18) -> PlatformImage {
        if let hit = cache[emoji] { return hit }
        #if os(macOS)
        let attributed = NSAttributedString(string: emoji, attributes: [
            // Emoji font explicitly: bare code points without the variation
            // selector otherwise draw in text presentation — a thin monochrome
            // glyph that reads as a blank slot.
            .font: NSFont(name: "AppleColorEmoji", size: pointSize)
                ?? NSFont.systemFont(ofSize: pointSize),
        ])
        // Rasterise eagerly: handler-based NSImages redraw lazily and menu
        // palettes sometimes render them blank.
        let size = CGSize(width: ceil(attributed.size().width),
                          height: ceil(attributed.size().height))
        let image = NSImage(size: size)
        image.lockFocus()
        attributed.draw(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        #else
        let attributed = NSAttributedString(string: emoji, attributes: [
            .font: UIFont(name: "AppleColorEmoji", size: pointSize)
                ?? UIFont.systemFont(ofSize: pointSize),
        ])
        let size = attributed.size()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            attributed.draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
        cache[emoji] = image
        return image
    }
}

/// Up to three overlapping reader avatars (plus an overflow count), pinned to
/// the trailing edge of the last row each user has read.
/// Renders a message body with markdown blockquotes: consecutive `>`-prefixed
/// lines become an indented, bar-accented, secondary block; other lines render
/// normally (with custom emotes). Splits into blocks so quotes and regular text
/// can interleave.
private struct QuotedBodyView: View {
    let rawBody: String
    let emotes: [String: String]
    let loader: MediaLoader
    let jumboEmoji: Bool
    let fontScale: CGFloat
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.isQuote {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tint.opacity(0.6))
                            .frame(width: 3)
                        segment(block.text)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    segment(block.text)
                }
            }
        }
    }

    @ViewBuilder
    private func segment(_ text: String) -> some View {
        let present = emotes.filter { text.contains($0.key) }
        if present.isEmpty {
            Text(RenderedBodyCache.rendered(text)).font(font)
        } else {
            EmoteBodyText(body_: text, emotes: present, loader: loader,
                          jumboEmoji: jumboEmoji, fontScale: fontScale).font(font)
        }
    }

    private var blocks: [(text: String, isQuote: Bool)] {
        var result: [(text: String, isQuote: Bool)] = []
        for line in rawBody.components(separatedBy: "\n") {
            let isQuote = line.hasPrefix(">")
            let text = isQuote ? String(line.drop(while: { $0 == ">" || $0 == " " })) : line
            if !result.isEmpty, result[result.count - 1].isQuote == isQuote {
                result[result.count - 1].text += "\n" + text
            } else {
                result.append((text, isQuote))
            }
        }
        return result
    }
}

struct ReadReceiptStack: View {
    let userIds: [String]
    let viewModel: TimelineViewModel

    @State private var showsPopover = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: -5) {
            ForEach(userIds.prefix(3), id: \.self) { userId in
                let member = viewModel.membersById[userId]
                RoomAvatarView(name: member?.name ?? String(userId.dropFirst()),
                               isDirect: true, size: 15,
                               avatarURL: member?.avatarURL)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1))
            }
            if userIds.count > 3 {
                Text("+\(userIds.count - 3)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
            }
        }
        .contentShape(Rectangle())
        #if os(iOS)
        // No hover on touch: tapping opens the reader list. ≥28pt tap area
        // via padding-in/out, biased downward so it doesn't sit over the
        // message text above.
        .padding(.top, 4)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .padding(.top, -4)
        .padding(.bottom, -10)
        .onTapGesture { showsPopover = true }
        // A sheet, not a popover: the reader list overflows a popover once
        // more than a couple of people have read.
        .sheet(isPresented: $showsPopover) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(userIds, id: \.self) { userId in
                            let member = viewModel.membersById[userId]
                            HStack(spacing: 10) {
                                RoomAvatarView(name: member?.name ?? String(userId.dropFirst()),
                                               isDirect: true, size: 32,
                                               avatarURL: member?.avatarURL)
                                Text(member?.name ?? userId)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .navigationTitle("Read up to here by")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
        #else
        // Delay so a pointer sweep doesn't pop a card per row.
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    showsPopover = true
                }
            } else {
                showsPopover = false
            }
        }
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Read up to here by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(userIds, id: \.self) { userId in
                    let member = viewModel.membersById[userId]
                    HStack(spacing: 6) {
                        RoomAvatarView(name: member?.name ?? String(userId.dropFirst()),
                                       isDirect: true, size: 18,
                                       avatarURL: member?.avatarURL)
                        Text(member?.name ?? userId)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 260, alignment: .leading)
        }
        #endif
        // Avatars are decorative; without a label the stack is a mystery tap target.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Read by \(userIds.count) \(userIds.count == 1 ? "person" : "people")"))
        #if os(iOS)
        .accessibilityAddTraits(.isButton)
        #endif
    }
}

/// Reaction chips under a message; click toggles your reaction.
struct ReactionChips: View {
    let reactions: [MessageReaction]
    let ownUserId: String
    /// Renders `mxc://` reaction keys (custom emoji) as images.
    var loader: MediaLoader?
    /// Accessibility preference: pad the iOS hit target a little more.
    var largerTapTargets: Bool = false
    /// Resolves an `mxc://` key to its `:shortcode:` for labels/hover.
    var emoteLabel: (String) -> String? = { _ in nil }
    /// Resolves a user ID to a display name for the hover card.
    var nameFor: (String) -> String = { $0 }
    let toggle: (String) -> Void
    /// Opens the reaction picker from the trailing "+" chip.
    var onAddReaction: (() -> Void)?

    @State private var hoveredKey: String?

    /// The human-readable form of a reaction key — the key itself for
    /// unicode emoji, the `:shortcode:` for custom-emote keys.
    private func label(for key: String) -> String {
        key.hasPrefix("mxc://") ? (emoteLabel(key) ?? String(localized: "custom emoji")) : key
    }

    @ViewBuilder
    private func keyContent(_ key: String, size: CGFloat) -> some View {
        if key.hasPrefix("mxc://") {
            EmoteImageView(url: key, size: size, loader: loader)
        } else {
            Text(key)
        }
    }

    var body: some View {
        // 8pt gap: hit areas grow ±4 horizontally, so adjacent chips' expanded
        // targets meet without overlapping.
        FlowLayout(spacing: 8, lineSpacing: 6) {
            ForEach(reactions, id: \.key) { reaction in
                let mine = reaction.includesOwn(userId: ownUserId)
                Button {
                    toggle(reaction.key)
                } label: {
                    HStack(spacing: 4) {
                        keyContent(reaction.key, size: 17)
                        Text(String(reaction.count))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        mine ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1))
                    #if os(iOS)
                    // Extended hit target, not a bigger chip. Downward-biased:
                    // symmetric ±9 overlapped the message text above.
                    .padding(.top, 4)
                    .padding(.bottom, largerTapTargets ? 13 : 9)
                    .padding(.horizontal, largerTapTargets ? 7 : 4)
                    .contentShape(Rectangle())
                    .padding(.top, -4)
                    .padding(.bottom, largerTapTargets ? -13 : -9)
                    .padding(.horizontal, largerTapTargets ? -7 : -4)
                    #endif
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
                // Own-reaction state is otherwise only a tint.
                .accessibilityLabel(Text("\(reaction.count) \(reaction.count == 1 ? "reaction" : "reactions"), \(label(for: reaction.key))"))
                .accessibilityValue(mine ? Text("You reacted") : Text(verbatim: ""))
                .accessibilityAddTraits(mine ? .isSelected : [])
                #if os(iOS)
                // Touch can't hover: long-press surfaces the sender list.
                // Chip-scoped so it cleanly overrides the row's context menu
                // instead of fighting its UIContextMenuInteraction.
                .contextMenu {
                    Section("Reacted with \(label(for: reaction.key))") {
                        ForEach(reaction.senders, id: \.self) { userId in
                            Button(nameFor(userId)) {}
                                .disabled(true)
                        }
                    }
                    Button(mine ? "Remove Your Reaction" : "Add Reaction",
                           systemImage: mine ? "minus.circle" : "plus.circle") {
                        toggle(reaction.key)
                    }
                }
                #endif
                .onHover { hovering in
                    if hovering {
                        hoveredKey = reaction.key
                    } else if hoveredKey == reaction.key {
                        hoveredKey = nil
                    }
                }
                .popover(isPresented: Binding(
                    get: { hoveredKey == reaction.key },
                    set: { if !$0 && hoveredKey == reaction.key { hoveredKey = nil } }
                ), arrowEdge: .top) {
                    VStack(spacing: 6) {
                        keyContent(reaction.key, size: 40)
                            .font(.largeTitle)
                        Text(reaction.senders.map(nameFor).joined(separator: ", "))
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .frame(maxWidth: 240)
                }
            }
            if let onAddReaction {
                Button(action: onAddReaction) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(height: 23)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .accessibilityLabel("Add reaction")
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
            }
        }
        .padding(.top, 2)
    }
}

/// Left-aligned layout that wraps subviews onto new lines when they run past
/// the available width; used for reaction chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, maxWidth: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                current.width = max(0, x - spacing)
                rows.append(current)
                y += current.height + lineSpacing
                current = Row()
                current.y = y
                x = 0
            }
            current.items.append((index, x, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty {
            current.width = max(0, x - spacing)
            rows.append(current)
        }
        return rows
    }
}

#if os(iOS)
/// Identifiable temp-file wrapper so a URL can drive the share sheet.
struct ImageShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet; ShareLink can't be triggered from an async
/// context-menu action, so wrap UIActivityViewController.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
