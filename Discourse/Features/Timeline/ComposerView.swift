import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Drop payload for Finder files (imported as a sandbox-readable copy) and
/// data-only drags (Photos).
enum ComposerDropItem: Transferable {
    case file(data: Data, filename: String)
    case image(data: Data)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let data = try Data(contentsOf: received.file)
            return .file(data: data, filename: received.file.lastPathComponent)
        }
        DataRepresentation(importedContentType: .image) { data in
            .image(data: data)
        }
    }
}

/// Touch-down feedback; plain iOS buttons give none.
struct PressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ComposerView: View {
    @Bindable var viewModel: TimelineViewModel
    /// Home-indicator inset, so the expression panel can reach the bottom edge.
    var bottomSafeInset: CGFloat = 0
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var prefs
    @State private var text = ""
    /// In-progress draft, stashed while an edit occupies the field so a
    /// cancelled edit restores it.
    @State private var stashedDraft = ""
    @State private var showsFilePicker = false
    @State private var showsPollSheet = false
    @State private var showsLocationShareConfirm = false
    @State private var showsEmojiPicker = false
    @State private var showsExpressionPanel = false
    /// Panel's search field is focused: the keyboard is up FOR the panel, so
    /// the will-show handler must not retire it; bar+panel lift together.
    @State private var panelSearchActive = false
    @State private var recorder = VoiceRecorder()
    @FocusState private var isFocused: Bool
    /// Active "@partial" token at the end of the field, sans the @.
    @State private var mentionQuery: String?
    @State private var mentionSuggestions: [TimelineViewModel.MemberItem] = []
    /// Mentions the user picked from the autocomplete, so the plain `@Name`
    /// tokens shown in the field can be turned into real matrix.to links + an
    /// intentional-mention list at send time.
    @State private var chosenMentions: [ChosenMention] = []
    /// One row of the `:token:` autocomplete: a custom emote or a unicode
    /// emoji matched by its derived shortcode.
    private enum EmojiSuggestion: Identifiable, Hashable {
        case custom(CustomEmojiStore.Emote)
        case unicode(emoji: String, shortcode: String)

        var id: String {
            switch self {
            case .custom(let emote): "custom/\(emote.id)"
            case .unicode(_, let shortcode): "unicode/\(shortcode)"
            }
        }

        var label: String {
            switch self {
            case .custom(let emote): emote.token
            case .unicode(_, let shortcode): ":\(shortcode):"
            }
        }
    }

    /// Matches for a trailing ":partial" token.
    @State private var emoteSuggestions: [EmojiSuggestion] = []
    @State private var selectedSuggestion = 0
    #if os(iOS)
    /// Photo Library attach flow (Files stays in the fileImporter).
    @State private var showsPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var sendCount = 0
    /// Drives the send haptic; advanced only while `sendMessageHaptic` is on,
    /// so an off pref keeps the trigger unchanged and silent.
    @State private var hapticTick = 0
    /// True while the finger is down on the mic.
    @State private var voiceHoldActive = false
    /// Slid up to the lock; recording continues hands-free until sent or
    /// discarded from the bar.
    @State private var isVoiceLocked = false
    /// Live hold translation, for the slide-to-cancel/lock feedback.
    @State private var voiceDrag: CGSize = .zero
    /// Set once a slide-to-cancel discards; swallows the rest of the gesture.
    @State private var voiceDragCancelled = false
    @State private var voiceHint: String?
    @State private var voiceHintTask: Task<Void, Never>?

    private static let voiceCancelThreshold: CGFloat = -80
    private static let voiceLockThreshold: CGFloat = -60
    /// Live keyboard height (0 while hidden), tracked manually: the timeline
    /// opts out of automatic keyboard avoidance so the keyboard lift and the
    /// panel move on one animation clock. Mixing the system's safe-area
    /// animation with ours jumped the bar on every swap.
    @State private var keyboardHeight: CGFloat = 0
    /// Last real keyboard height; sizes the panel to the same space.
    @State private var lastKeyboardHeight: CGFloat = 330
    /// Home-indicator inset, latched to the last real value: `bottomSafeInset`
    /// can momentarily read 0 while the panel resizes the composer, which
    /// opened the panel ~34pt too tall then snapped down.
    @State private var latchedBottomInset: CGFloat = 0
    /// Extra panel height pulled out via the grabber (0 = keyboard-sized).
    @State private var panelExtraHeight: CGFloat = 0
    @State private var panelDragBase: CGFloat = 0
    @State private var isDraggingPanel = false

    /// Panel can grow to ~three quarters of the window.
    private var maxPanelExtraHeight: CGFloat {
        let windowHeight = hostWindow?.bounds.height ?? 800
        return max(0, windowHeight * 0.75 - expressionPanelHeight)
    }

    private var panelExpandGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if !isDraggingPanel {
                    isDraggingPanel = true
                    panelDragBase = panelExtraHeight
                }
                let proposed = panelDragBase - value.translation.height
                panelExtraHeight = min(max(0, proposed), maxPanelExtraHeight)
            }
            .onEnded { value in
                isDraggingPanel = false
                // Two detents: keyboard-sized or full. Release snaps by
                // projected position.
                let projected = panelExtraHeight - value.predictedEndTranslation.height
                    + value.translation.height
                if panelDragBase == 0, panelExtraHeight == 0, value.translation.height > 60 {
                    // Downward fling at rest closes the panel.
                    withAnimation(.easeOut(duration: 0.25)) {
                        showsExpressionPanel = false
                    }
                    return
                }
                let target: CGFloat = projected > maxPanelExtraHeight / 2
                    ? maxPanelExtraHeight : 0
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    panelExtraHeight = target
                }
            }
    }
    /// Hosting window, captured so app-global keyboard notifications can be
    /// gated to this composer's own scene.
    @State private var hostWindow: UIWindow?

    private var expressionPanelHeight: CGFloat {
        // Latched inset (not the raw one, which can flash 0) so the height
        // isn't briefly inflated on open. Keyboard frames include the
        // home-indicator band the panel background already covers.
        max(240, lastKeyboardHeight - latchedBottomInset)
    }

    /// Bar lift: above the keyboard while it's up, above the panel (whose own
    /// height provides the lift) while that's up, else hugging the home
    /// indicator. Keyboard/panel flip in one transaction with identical lift
    /// totals, so swaps don't move the bar. During panel search the whole
    /// stack rides above the keyboard so results stay visible while typing.
    private var manualBottomPadding: CGFloat {
        // Latched inset keeps the lift stable (raw bottomSafeInset can flash 0).
        if showsExpressionPanel {
            // Ride the keyboard only when the panel's own search field raised
            // it; otherwise the departing keyboard is briefly counted on top
            // of the panel height, lifting the bar too high before it settles.
            return panelSearchActive && keyboardHeight > 0
                ? keyboardHeight - latchedBottomInset + 8 : 0
        }
        if keyboardHeight > 0 { return keyboardHeight - latchedBottomInset + 8 }
        return 2
    }

    private func keyboardAnimation(_ note: Notification) -> Animation {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        return .easeOut(duration: (duration ?? 0) > 0 ? duration! : 0.25)
    }

    /// Keyboard notifications are app-global: on iPad a sibling scene (e.g. the
    /// detached call window) can raise the keyboard and lift this composer.
    /// `keyboardIsLocalUserInfoKey` is false only for a *different app* (Split
    /// View) — sibling scenes still report local — so also require this scene
    /// to be foreground-active, which iPadOS grants only to the focused scene.
    /// On iPhone both checks always pass, so behavior is unchanged.
    private func keyboardTargetsThisScene(_ note: Notification) -> Bool {
        if let isLocal = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool,
           !isLocal {
            return false
        }
        // Window not captured yet (first frames): fall back.
        guard let scene = hostWindow?.windowScene else { return true }
        return scene.activationState == .foregroundActive
    }

    /// How much of the composer's window the keyboard's end frame covers.
    /// Window-space so it's correct in Stage Manager / Split View (window
    /// bottom above the screen bottom); a keyboard narrower than the window is
    /// floating/undocked and contributes no overlap. Falls back to a
    /// screen-based estimate while the window isn't captured yet.
    private func keyboardOverlap(of frame: CGRect) -> CGFloat {
        guard let hostWindow else {
            return max(0, UIScreen.main.bounds.height - frame.minY)
        }
        let converted = hostWindow.convert(frame, from: nil)
        guard converted.width >= hostWindow.bounds.width else { return 0 }
        return max(0, hostWindow.bounds.maxY - converted.minY)
    }
    #endif

    private var scope: SessionScope? {
        if case .active(let scope) = appState.phase { return scope }
        return nil
    }

    #if os(macOS)
    /// Stages pasted files or raw image data (screenshots, copied images) as
    /// attachment chips.
    private func stagePasteboardContents() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
            for url in urls {
                viewModel.stageAttachment(fileURL: url)
            }
            return
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            viewModel.stageAttachment(data: data, filename: "image")
        }
    }
    #endif

    // MARK: Mention autocomplete

    /// A trailing "@token" (@ at a word start) opens the list. Refreshes
    /// `mentionSuggestions`, cached so body/key handlers don't refilter.
    private func updateMentionQuery() {
        selectedSuggestion = 0
        guard let atIndex = text.lastIndex(of: "@") else {
            mentionQuery = nil
            mentionSuggestions = []
            return
        }
        let token = text[text.index(after: atIndex)...]
        guard !token.contains(where: \.isWhitespace),
              atIndex == text.startIndex || text[text.index(before: atIndex)].isWhitespace
        else {
            mentionQuery = nil
            mentionSuggestions = []
            return
        }
        let query = String(token)
        mentionQuery = query
        // Fold once and compare against members' precomputed foldedName;
        // localizedCaseInsensitiveContains per member per keystroke was the
        // hot path. Only 6 are shown, so stop at 6.
        let foldedQuery = RoomSummary.foldedForSearch(query)
        let loweredQuery = query.lowercased()
        var matches: [TimelineViewModel.MemberItem] = []
        for member in viewModel.members where member.id != viewModel.ownUserId {
            if query.isEmpty
                || member.foldedName.contains(foldedQuery)
                || member.id.lowercased().contains(loweredQuery) {
                matches.append(member)
                if matches.count == 6 { break }
            }
        }
        mentionSuggestions = matches
    }

    /// A picked mention: the `@user:server` token shown in the field, which is
    /// also the id it resolves to. `send()` turns the token into a real mention.
    struct ChosenMention {
        let token: String
        let userId: String
    }

    /// Replaces the trailing "@token" with the member's full `@user:server`
    /// and records it; the send path turns the token into a mention anchor.
    private func insertMention(_ member: TimelineViewModel.MemberItem) {
        guard let atIndex = text.lastIndex(of: "@") else { return }
        text.replaceSubrange(atIndex..., with: "\(member.id) ")
        chosenMentions.append(ChosenMention(token: member.id, userId: member.id))
        mentionQuery = nil
        mentionSuggestions = []
        isFocused = true
    }

    /// Mentions whose `@user:server` token is still present in the composed
    /// text (some may have been edited away), as `MentionRef`s for the send path.
    private func resolvedMentions(in text: String) -> [MentionRef] {
        var result: [MentionRef] = []
        for mention in chosenMentions where text.contains(mention.token) {
            if !result.contains(where: { $0.userId == mention.userId }) {
                result.append(MentionRef(userId: mention.userId, text: mention.token))
            }
        }
        return result
    }

    // MARK: Custom-emoji autocomplete

    /// A trailing ":token" (colon at a word start, ≥2 shortcode chars)
    /// suggests custom emotes and unicode emoji. Suppressed while a mention
    /// query is active so "@user:server" doesn't read as an emote query.
    private func updateEmoteQuery() {
        emoteSuggestions = []
        guard mentionQuery == nil,
              let colonIndex = text.lastIndex(of: ":") else { return }
        let token = text[text.index(after: colonIndex)...]
        guard token.count >= 2,
              token.allSatisfy(CustomEmojiStore.isShortcodeCharacter) else { return }
        if colonIndex > text.startIndex,
           !text[text.index(before: colonIndex)].isWhitespace {
            return
        }
        let needle = token.lowercased()
        // Custom emotes first (prefix, then contains), then unicode emoji.
        var prefix: [EmojiSuggestion] = []
        var contains: [EmojiSuggestion] = []
        if let store = scope?.customEmoji {
            for emote in store.byShortcode.values.sorted(by: { $0.shortcode < $1.shortcode }) {
                let shortcode = emote.shortcode.lowercased()
                if shortcode.hasPrefix(needle) {
                    prefix.append(.custom(emote))
                    if prefix.count == 6 { break }
                } else if contains.count < 6, shortcode.contains(needle) {
                    contains.append(.custom(emote))
                }
            }
        }
        let unicode = EmojiShortcodes.matches(needle, limit: 6)
            .map { EmojiSuggestion.unicode(emoji: $0.emoji, shortcode: $0.shortcode) }
        emoteSuggestions = Array((prefix + unicode + contains).prefix(8))
        selectedSuggestion = 0
    }

    /// Replaces the trailing ":token": custom emotes keep their `:shortcode:`
    /// (converted at send time); unicode becomes the character.
    private func insertEmote(_ suggestion: EmojiSuggestion) {
        guard let colonIndex = text.lastIndex(of: ":") else { return }
        switch suggestion {
        case .custom(let emote):
            text.replaceSubrange(colonIndex..., with: emote.token + " ")
        case .unicode(let emoji, _):
            text.replaceSubrange(colonIndex..., with: emoji)
        }
        emoteSuggestions = []
        isFocused = true
    }

    /// Typing the closing colon of an exact unicode shortcode
    /// (":pleading_face:") swaps it for the emoji. Custom emotes stay as
    /// tokens. Returns nil when the tail isn't a complete known token.
    private static func autoReplacingTrailingShortcode(in text: String) -> String? {
        guard text.hasSuffix(":"), text.count >= 4 else { return nil }
        let closing = text.index(before: text.endIndex)
        var start = closing
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard CustomEmojiStore.isShortcodeCharacter(text[previous]) else { break }
            start = previous
        }
        guard start < closing, start > text.startIndex,
              text[text.index(before: start)] == ":" else { return nil }
        let opening = text.index(before: start)
        // Word start only — "10:30:" must survive.
        if opening > text.startIndex, !text[text.index(before: opening)].isWhitespace {
            return nil
        }
        guard let emoji = EmojiShortcodes.byShortcode[String(text[start..<closing]).lowercased()]
        else { return nil }
        return text.replacingCharacters(in: opening...closing, with: emoji)
    }

    private var emoteSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(emoteSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    insertEmote(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        switch suggestion {
                        case .custom(let emote):
                            EmoteImageView(url: emote.url, size: 22, loader: scope?.mediaLoader)
                        case .unicode(let emoji, _):
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 22, height: 22)
                        }
                        Text(suggestion.label)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(index == selectedSuggestion
                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                        : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { selectedSuggestion = index } }
            }
        }
        .padding(6)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 4)
    }

    private var mentionSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(mentionSuggestions.enumerated()), id: \.element.id) { index, member in
                Button {
                    insertMention(member)
                } label: {
                    HStack(spacing: 8) {
                        RoomAvatarView(name: member.name, isDirect: true, size: 22,
                                       avatarURL: member.avatarURL)
                        Text(member.name)
                            .font(.callout)
                            .lineLimit(1)
                        Text(member.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(index == selectedSuggestion
                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                        : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { selectedSuggestion = index } }
            }
        }
        .padding(6)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !mentionSuggestions.isEmpty {
                mentionSuggestionsView
            } else if !emoteSuggestions.isEmpty {
                emoteSuggestionsView
            }
            // Glass tags that spring out of the composer's top edge for
            // typing/reply/edit/error states.
            VStack(alignment: .leading, spacing: 4) {
                if !viewModel.isEncrypted && prefs.warnUnencrypted {
                    unencryptedBanner
                }
                if prefs.showTypingIndicators, !viewModel.typingUsers.isEmpty {
                    typingIndicator
                        .transition(.appendix)
                }
                if let composerError = viewModel.composerError {
                    errorBanner(composerError)
                        .transition(.appendix)
                }
                if viewModel.editTarget != nil {
                    editBanner
                        .transition(.appendix)
                } else if let target = viewModel.replyTarget {
                    replyBanner(target)
                        .transition(.appendix)
                }
            }
            .padding(.leading, 2)
            .padding(.bottom, 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: viewModel.typingUsers.isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: viewModel.composerError == nil)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: viewModel.editTarget?.id)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: viewModel.replyTarget?.id)
            if viewModel.hasPendingAttachments {
                attachmentStrip
            }
            Group {
            #if os(iOS)
            touchBar
            #else
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    attachMenuItems
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Attach, sticker, or poll")
                // Single-line-field height so the icon centers on the text row.
                .frame(height: 33)
                .padding(.leading, 8)

                if recorder.isRecording {
                    recordingBar
                } else {
                    messageField
                }

                if !recorder.isRecording {
                    Button {
                        showsEmojiPicker = true
                    } label: {
                        Image(systemName: "face.smiling")
                            // Matches the attach and send/mic neighbors.
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Emoji & Stickers")
                    .frame(height: 33)
                    .popover(isPresented: $showsEmojiPicker, arrowEdge: .top) {
                        expressionPicker
                    }
                }

                if recorder.isRecording {
                    Button {
                        _ = recorder.stop(cancelled: true)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(height: 33)
                    Button {
                        if let recording = recorder.stop() {
                            Task { await viewModel.sendVoiceMessage(recording) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .frame(height: 33)
                    .padding(.trailing, 8)
                } else if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .frame(height: 33)
                    .padding(.trailing, 8)
                } else {
                    // Empty composer: voice message.
                    Button {
                        Task { _ = await recorder.start() }
                    } label: {
                        Image(systemName: "mic.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Record a voice message")
                    .frame(height: 33)
                    .padding(.trailing, 8)
                }
            }
            .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            #endif
            }
            .dropDestination(for: ComposerDropItem.self) { items, _ in
                guard !items.isEmpty else { return false }
                for item in items {
                    switch item {
                    case .file(let data, let filename):
                        viewModel.stageAttachment(data: data, filename: filename)
                    case .image(let data):
                        viewModel.stageAttachment(data: data, filename: "image")
                    }
                }
                return true
            }

            #if os(iOS)
            // Keyboard-replacement expression panel: sits where the keyboard
            // would. The grabber expands it past keyboard height; dragging
            // down at rest closes it.
            if showsExpressionPanel {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 36, height: 5)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(panelExpandGesture)
                        .accessibilityHidden(true)
                    expressionPicker
                        .frame(maxWidth: .infinity)
                }
                    .frame(height: expressionPanelHeight + panelExtraHeight)
                    .background {
                        // Rounded top corners, stretched by the measured inset
                        // to the bottom edge (ignoresSafeArea is inert here).
                        UnevenRoundedRectangle(topLeadingRadius: 24,
                                               topTrailingRadius: 24,
                                               style: .continuous)
                            .fill(.regularMaterial)
                            .padding(.bottom, -latchedBottomInset)
                    }
                    // Matches the 8pt keyboard gap so the bar's resting height
                    // is identical in both states.
                    .padding(.top, 8)
                    // Cancel the composer's horizontal inset; the panel is
                    // full-bleed like the keyboard.
                    .padding(.horizontal, -12)
                    // Slide, no fade (the keyboard doesn't fade either).
                    .transition(.move(edge: .bottom))
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        #if os(macOS)
        .padding(.bottom, 8)
        #else
        .padding(.bottom, manualBottomPadding)
        #endif
        #if os(iOS)
        // Latch the home-indicator inset, ignoring transient 0s, so the
        // panel's height is stable when it opens.
        .onChange(of: bottomSafeInset, initial: true) { _, new in
            if new > 0, new < 60 { latchedBottomInset = new }
        }
        #endif
        #if os(macOS)
        // Auto-focus; on iOS this would raise the keyboard over every chat.
        .onAppear {
            isFocused = true
            // Restore the room's draft (the composer is torn down on switch,
            // so @State text starts empty).
            if text.isEmpty, viewModel.editTarget == nil {
                text = viewModel.draftText
            }
        }
        // Persist the draft, but not while an edit occupies the field (the
        // real draft is stashed in `stashedDraft`).
        .onChange(of: text) { _, newValue in
            if viewModel.editTarget == nil { viewModel.draftText = newValue }
        }
        #else
        .background(WindowCapture { hostWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { note in
            guard keyboardTargetsThisScene(note),
                  let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue)?.cgRectValue else { return }
            let overlap = keyboardOverlap(of: frame)
            withAnimation(keyboardAnimation(note)) {
                keyboardHeight = overlap
                // Keyboard reclaims the panel's space in the same transaction
                // so total lift stays constant — unless the keyboard was
                // raised by the panel's own search field, which rides above it.
                if !panelSearchActive {
                    showsExpressionPanel = false
                }
            }
            if overlap > 200 { lastKeyboardHeight = overlap }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { note in
            // Not scene-gated: when focus jumps to another scene it's our
            // keyboard retiring, and this scene may already read as inactive;
            // dropping it would leave the bar floating. Zeroing is harmless.
            withAnimation(keyboardAnimation(note)) { keyboardHeight = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard keyboardTargetsThisScene(note),
                  let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue)?.cgRectValue else { return }
            // Interactive-dismiss commits and in-place height changes (emoji
            // keyboard, QuickType bar) fire only a frame-change; track the end
            // frame's overlap so the bar doesn't stay floating then snap.
            let overlap = keyboardOverlap(of: frame)
            guard overlap != keyboardHeight else { return }
            withAnimation(keyboardAnimation(note)) { keyboardHeight = overlap }
        }
        .photosPicker(isPresented: $showsPhotoPicker,
                      selection: $photoPickerItems,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            photoPickerItems = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first
                    if let type, type.conforms(to: .movie) {
                        let ext = type.preferredFilenameExtension ?? "mov"
                        viewModel.stageAttachment(data: data, filename: "video.\(ext)")
                    } else {
                        // Staging derives the image extension from the data.
                        viewModel.stageAttachment(data: data, filename: "image")
                    }
                }
            }
        }
        // Light tick on send; suppressed when the pref is off (hapticTick
        // only advances while it's on).
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTick)
        // Focus moving to the field while the panel rides above the keyboard
        // (panel search): the keyboard stays up so no will-show fires — retire
        // the panel here. Only in that state; the ordinary swap stays a single
        // will-show transaction.
        .onChange(of: isFocused) { _, focused in
            if focused, showsExpressionPanel, panelSearchActive {
                withAnimation(.easeOut(duration: 0.25)) {
                    showsExpressionPanel = false
                }
            }
        }
        .onChange(of: showsExpressionPanel) { _, shown in
            if !shown {
                panelSearchActive = false
                // Reopen keyboard-sized, not at the last dragged height.
                panelExtraHeight = 0
            }
        }
        #endif
        .sheet(isPresented: $showsPollSheet) {
            NewPollSheet(viewModel: viewModel)
        }
        .confirmationDialog("Share your current location?",
                            isPresented: $showsLocationShareConfirm,
                            titleVisibility: .visible) {
            Button("Share Location") {
                Task { await viewModel.shareCurrentLocation() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showsFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                viewModel.stageAttachment(fileURL: url)
            }
        }
        // Entering edit mode: stash the draft, then load the original text.
        .onChange(of: viewModel.editTarget) { previous, target in
            guard let target else {
                // Leaving edit mode: restore the stashed draft.
                if previous != nil { text = stashedDraft; stashedDraft = "" }
                return
            }
            // Stash only on the draft→edit transition; switching between two
            // edit targets keeps the original pre-edit draft.
            if previous == nil { stashedDraft = text }
            if case .text(let body) = target.kind {
                text = body
            }
            isFocused = true
        }
        // Composer (and its @State recorder) is torn down on room switch /
        // back-nav while a locked recording may be live; stop it to release
        // the timer, audio session, and temp file.
        .onDisappear {
            if recorder.isRecording { _ = recorder.stop(cancelled: true) }
        }
        #if os(iOS)
        // System stopped the recording: drop the stuck UI rather than freezing
        // a dead bar with a live red dot.
        .onChange(of: recorder.interrupted) { _, interrupted in
            guard interrupted else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                voiceHoldActive = false
                isVoiceLocked = false
                voiceDragCancelled = false
                voiceDrag = .zero
            }
            showVoiceHint(String(localized: "Recording interrupted"))
        }
        #endif
    }

    /// Transient failure line above the bar; the view model auto-clears it.
    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text(text)
                .lineLimit(2)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .appendixBubble()
    }

    /// Persistent notice that this room isn't end-to-end encrypted, so messages
    /// here aren't private the way they are in an encrypted room.
    private var unencryptedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("Not encrypted — messages aren't private")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .appendixBubble()
    }

    private var editBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Editing message")
            Button {
                viewModel.editTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    #if os(iOS)
                    // 44pt touch target.
                    .padding(13)
                    .contentShape(Rectangle())
                    .padding(-13)
                    #endif
            }
            .buttonStyle(.plain)
            .help("Cancel editing")
        }
        .font(.callout)
        .appendixBubble()
    }

    @ViewBuilder
    private var expressionPicker: some View {
        #if os(iOS)
        if let scope {
            EmojiStickerPickerView(
                stickerStore: scope.stickers,
                mediaLoader: scope.mediaLoader,
                customEmoji: scope.customEmoji,
                insertEmoji: { emoji in
                    // No refocus: raising the keyboard would retire the panel.
                    text += emoji
                },
                insertCustomEmoji: { emote in
                    // The `:shortcode:` token; the send path converts it.
                    text += emote.token + " "
                },
                sendSticker: { sticker in
                    // Panel stays up so stickers can be chained.
                    Task { await viewModel.sendSticker(sticker) }
                },
                sendPackSticker: { emote in
                    Task { await viewModel.sendSticker(emote) }
                },
                onSearchFocusChange: { focused in
                    panelSearchActive = focused
                })
        }
        #else
        EmojiStickerPickerView(
            stickerStore: scope?.stickers,
            mediaLoader: scope?.mediaLoader,
            customEmoji: scope?.customEmoji,
            insertEmoji: { emoji in
                text += emoji
                isFocused = true
            },
            insertCustomEmoji: { emote in
                text += emote.token + " "
                isFocused = true
            },
            sendSticker: { sticker in
                showsEmojiPicker = false
                Task { await viewModel.sendSticker(sticker) }
            },
            sendPackSticker: { emote in
                showsEmojiPicker = false
                Task { await viewModel.sendSticker(emote) }
            })
        #endif
    }

    /// The attach/poll/location actions, shared by both platform bars.
    @ViewBuilder
    private var attachMenuItems: some View {
        #if os(iOS)
        Button("Photo Library", systemImage: "photo.on.rectangle") {
            showsPhotoPicker = true
        }
        #endif
        Button("Attach File…", systemImage: "paperclip") {
            showsFilePicker = true
        }
        Button("Create Poll…", systemImage: "chart.bar.xaxis") {
            showsPollSheet = true
        }
        Button("Share Location", systemImage: "location.fill") {
            // Confirm before broadcasting a location.
            showsLocationShareConfirm = true
        }
    }

    /// Commits the highlighted autocomplete row, if any list is open.
    private func acceptSuggestion() -> Bool {
        if !mentionSuggestions.isEmpty {
            insertMention(mentionSuggestions[min(selectedSuggestion, mentionSuggestions.count - 1)])
            return true
        }
        if !emoteSuggestions.isEmpty {
            insertEmote(emoteSuggestions[min(selectedSuggestion, emoteSuggestions.count - 1)])
            return true
        }
        return false
    }

    /// The text field with all its input behaviors, shared by both bars.
    private var messageField: some View {
        TextField("Message \(viewModel.roomName)", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($isFocused)
            .onSubmit(send)
            .onChange(of: text) { oldValue, newValue in
                // Files dragged onto the field arrive as their paths (one per
                // line for a multi-file drop); stage them all. Bulk insertions
                // only (paste/drop grow by >1) so filePaths() doesn't stat the
                // filesystem on every keystroke.
                if newValue.count - oldValue.count > 1 {
                    let paths = filePaths(in: newValue)
                    if !paths.isEmpty {
                        text = ""
                        for path in paths {
                            viewModel.stageAttachment(fileURL: URL(fileURLWithPath: path))
                        }
                        return
                    }
                }
                // Closing colon of ":pleading_face:" → 🥺 in place.
                // Single-character growth only, so pastes aren't rewritten.
                if newValue.count == oldValue.count + 1, newValue.hasSuffix(":"),
                   let replaced = Self.autoReplacingTrailingShortcode(in: newValue) {
                    text = replaced
                    return
                }
                if !newValue.isEmpty { viewModel.composerIsTyping() }
                updateMentionQuery()
                updateEmoteQuery()
            }
            // Members load async; refresh an open mention query when they land.
            .onChange(of: viewModel.members) { _, _ in
                updateMentionQuery()
            }
            .onKeyPress(.upArrow) {
                if !mentionSuggestions.isEmpty || !emoteSuggestions.isEmpty {
                    selectedSuggestion = max(0, selectedSuggestion - 1)
                    return .handled
                }
                #if os(macOS)
                // ↑ in an empty composer edits your last message; the
                // editTarget observer prefills and focuses the field.
                if text.isEmpty, let target = viewModel.lastOwnEditableMessage() {
                    viewModel.replyTarget = nil
                    viewModel.editTarget = target
                    return .handled
                }
                #endif
                return .ignored
            }
            .onKeyPress(.downArrow) {
                let count = !mentionSuggestions.isEmpty
                    ? mentionSuggestions.count : emoteSuggestions.count
                guard count > 0 else { return .ignored }
                selectedSuggestion = min(count - 1, selectedSuggestion + 1)
                return .handled
            }
            .onKeyPress(.tab) {
                acceptSuggestion() ? .handled : .ignored
            }
            #if os(iOS)
            .onKeyPress(.return) {
                // Return picks the highlighted suggestion; else falls through
                // to onSubmit → send.
                acceptSuggestion() ? .handled : .ignored
            }
            #else
            // macOS Return dispatch. Accept wins first; then send-vs-newline
            // depends on `sendOnEnter`. Always .handled, so .onSubmit(send)
            // never fires here — sends go through send() explicitly.
            .onKeyPress(keys: [.return], phases: .down) { press in
                if acceptSuggestion() { return .handled }
                // ⌥⏎ is always a newline, regardless of the pref.
                if press.modifiers.contains(.option) { return .ignored }
                let shift = press.modifiers.contains(.shift)
                if prefs.sendOnEnter {
                    // ⇧⏎ newline; plain ⏎ / ⌘⏎ send.
                    if shift { text.append("\n") } else { send() }
                } else {
                    // Inverted: plain ⏎ newline; ⇧⏎ / ⌘⏎ send.
                    if shift || press.modifiers.contains(.command) {
                        send()
                    } else {
                        text.append("\n")
                    }
                }
                return .handled
            }
            // Escape backs out of composer state (recording, edit, reply),
            // else ignored so Escape still exits full screen.
            .onKeyPress(.escape) {
                if recorder.isRecording {
                    _ = recorder.stop(cancelled: true)
                    return .handled
                }
                if viewModel.editTarget != nil {
                    viewModel.editTarget = nil
                    return .handled
                }
                if viewModel.replyTarget != nil {
                    viewModel.replyTarget = nil
                    return .handled
                }
                return .ignored
            }
            // ⌘V with files or image data stages attachments; plain text
            // pastes normally.
            .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in
                stagePasteboardContents()
            }
            #endif
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
    }

    #if os(iOS)
    /// iOS bar: attach and mic/send controls as independent glass bubbles
    /// beside the field bubble.
    private var touchBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if recorder.isRecording {
                    // Discard: the slide-to-cancel trash / locked-mode delete.
                    Button {
                        discardActiveRecording()
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(voiceDrag.width < Self.voiceCancelThreshold * 0.5
                                             ? AnyShapeStyle(.red)
                                             : AnyShapeStyle(.secondary))
                    }
                } else {
                    Menu {
                        attachMenuItems
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                }
            }
            .buttonStyle(PressFeedbackStyle())
            .frame(width: 40, height: 40)
            .glassEffect()
            // 44pt hit target around the 40pt visual.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .hoverEffect(.highlight)

            HStack(alignment: .center, spacing: 2) {
                if recorder.isRecording, voiceHoldActive, !isVoiceLocked {
                    slideToCancelBar
                } else if recorder.isRecording {
                    recordingBar
                } else {
                    messageField
                }
            }
            .frame(minHeight: 40)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .top) {
                if let voiceHint {
                    Text(voiceHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .glassEffect(in: Capsule())
                        .offset(y: -34)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: voiceHint)

            // Expression picker toggle.
            if !recorder.isRecording {
                Button {
                    if showsExpressionPanel {
                        // Focusing raises the keyboard; its will-show handler
                        // retires the panel in the same transaction.
                        isFocused = true
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showsExpressionPanel = true
                        }
                        // Padding is already 0 with the panel up, so the
                        // keyboard's departure doesn't move the bar.
                        isFocused = false
                    }
                } label: {
                    Image(systemName: showsExpressionPanel ? "keyboard" : "face.smiling")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PressFeedbackStyle())
                .frame(width: 40, height: 40)
                .glassEffect()
                // 44pt hit target around the 40pt visual.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .hoverEffect(.highlight)
            }

            Group {
                if recorder.isRecording && isVoiceLocked {
                    // Locked recording: tap to send.
                    Button(action: sendActiveRecording) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(PressFeedbackStyle())
                    .accessibilityLabel("Send voice message")
                } else if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(PressFeedbackStyle())
                } else {
                    // Hold to record; slide left to discard, up to lock. Not a
                    // Button: the zero-distance drag needs the raw press.
                    Image(systemName: voiceHoldActive ? "mic.fill" : "mic")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(voiceHoldActive
                                         ? AnyShapeStyle(.red)
                                         : AnyShapeStyle(.secondary))
                        .scaleEffect(voiceHoldActive ? 1.25 : 1)
                        .animation(.easeOut(duration: 0.15), value: voiceHoldActive)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .gesture(voiceHoldGesture)
                        .accessibilityLabel("Record voice message")
                        .accessibilityHint("Double tap to start a hands-free recording, then use the send or delete buttons. Or hold to record and release to send.")
                        // VoiceOver can't drive the drag, so its double-tap
                        // toggles a locked recording instead.
                        .accessibilityAction {
                            if recorder.isRecording {
                                sendActiveRecording()
                            } else {
                                isVoiceLocked = true
                                Task { if await recorder.start() == false { isVoiceLocked = false } }
                            }
                        }
                }
            }
            .frame(width: 40, height: 40)
            .glassEffect()
            // 44pt hit target around the 40pt visual.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .hoverEffect(.highlight)
            // Lock target floats above the mic while holding.
            .overlay(alignment: .bottom) {
                if voiceHoldActive && !isVoiceLocked {
                    voiceLockPill
                        .offset(y: -56)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: voiceHoldActive)
    }

    /// Zero-distance drag: down starts recording; movement drives
    /// slide-to-cancel/slide-to-lock; release sends. Global coordinate space
    /// on purpose: starting a recording dismisses the keyboard and slides the
    /// bar down, which in local space reads as the finger moving up and
    /// falsely triggers the lock.
    private var voiceHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !voiceDragCancelled else { return }
                if !voiceHoldActive {
                    voiceHoldActive = true
                    isVoiceLocked = false
                    Task {
                        let started = await recorder.start()
                        // The finger may have lifted before the mic spun up
                        // (e.g. behind a permission prompt); don't leave a
                        // ghost recording.
                        if started, !voiceHoldActive, !isVoiceLocked {
                            _ = recorder.stop(cancelled: true)
                        }
                    }
                }
                guard !isVoiceLocked else { return }
                voiceDrag = value.translation
                if value.translation.width < Self.voiceCancelThreshold {
                    voiceDragCancelled = true
                    discardActiveRecording()
                } else if value.translation.height < Self.voiceLockThreshold {
                    isVoiceLocked = true
                    voiceDrag = .zero
                }
            }
            .onEnded { _ in
                let wasCancelled = voiceDragCancelled
                voiceHoldActive = false
                voiceDrag = .zero
                voiceDragCancelled = false
                guard !wasCancelled, !isVoiceLocked else { return }
                if recorder.duration < 0.5 {
                    // A tap, not a hold.
                    discardActiveRecording()
                    showVoiceHint(String(localized: "Hold to record, release to send"))
                } else {
                    sendActiveRecording()
                }
            }
    }

    private func sendActiveRecording() {
        isVoiceLocked = false
        voiceHoldActive = false
        guard let recording = recorder.stop() else { return }
        sendCount += 1
        if prefs.sendMessageHaptic { hapticTick += 1 }
        Task { await viewModel.sendVoiceMessage(recording) }
    }

    private func discardActiveRecording() {
        isVoiceLocked = false
        _ = recorder.stop(cancelled: true)
    }

    private func showVoiceHint(_ text: String) {
        voiceHint = text
        voiceHintTask?.cancel()
        voiceHintTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            voiceHint = nil
        }
    }

    /// Lock target above the mic; fills in as the slide approaches.
    private var voiceLockPill: some View {
        let progress = min(1, max(0, -voiceDrag.height / -Self.voiceLockThreshold))
        return VStack(spacing: 2) {
            Image(systemName: progress >= 1 ? "lock.fill" : "lock.open")
                .font(.callout.weight(.medium))
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.semibold))
                .opacity(0.6)
        }
        .foregroundStyle(progress > 0.7 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .glassEffect(in: Capsule())
        .accessibilityHidden(true)
    }
    #endif

    #if os(iOS)
    /// Held-recording bar: timer plus a "slide to cancel" hint that rides the
    /// finger toward the trash.
    private var slideToCancelBar: some View {
        let pull = min(0, voiceDrag.width)
        let cancelProgress = min(1, max(0, pull / Self.voiceCancelThreshold))
        return HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
            Text(durationLabel(recorder.duration))
                .font(.callout)
                .monospacedDigit()
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                Text("Slide to cancel")
                    .font(.callout)
            }
            .foregroundStyle(cancelProgress > 0.5 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .opacity(1 - cancelProgress * 0.5)
            .offset(x: pull * 0.5)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
    #endif

    /// Red-dot timer + live level bars while recording.
    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
            Text(durationLabel(recorder.duration))
                .font(.callout)
                .monospacedDigit()
            WaveformBars(samples: recorder.levels.suffix(60).map { $0 })
                .frame(height: 20)
                .frame(maxWidth: 180)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }

    /// Preview chips for staged attachments.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = attachment.previewImage {
                                Image(platformImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                    Text(attachment.filename)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                        .frame(width: 64, height: 64)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            // Excluded from sends until the load lands.
                            if attachment.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .overlay {
                            if attachment.uploadFailed {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.red, lineWidth: 1.5)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if attachment.uploadFailed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white, .red)
                                    .padding(3)
                            }
                        }
                        .accessibilityLabel(attachment.uploadFailed
                            ? Text("\(attachment.filename): upload failed — will retry when you send")
                            : Text(attachment.filename))

                        Button {
                            viewModel.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                                #if os(iOS)
                                // 44pt touch target.
                                .padding(13)
                                .contentShape(Rectangle())
                                .padding(-13)
                                #endif
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .help("Remove attachment")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.hasPendingAttachments
    }

    /// Returns an existing file path if the string is exactly one (dragged in).
    /// Valid file paths in dropped/pasted text — one line per file. A single
    /// path (which may contain spaces) stays one line; multiple files are
    /// newline-separated. Directories and non-existent paths are dropped.
    private func filePaths(in string: String) -> [String] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") else { return [] }
        return trimmed.split(whereSeparator: \.isNewline).compactMap { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/") || candidate.hasPrefix("file://") else { return nil }
            let path = candidate.hasPrefix("file://")
                ? (URL(string: candidate)?.path(percentEncoded: false) ?? candidate)
                : candidate
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return path
        }
    }

    private func send() {
        guard canSend else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentions = resolvedMentions(in: message)
        chosenMentions = []
        text = ""
        // A vertical TextField can commit the submit's newline into the binding
        // right after this clear (racing onSubmit), leaving a stray line behind.
        // Re-clear next runloop so the field always ends empty.
        DispatchQueue.main.async { text = "" }
        #if os(iOS)
        sendCount += 1
        if prefs.sendMessageHaptic { hapticTick += 1 }
        #endif
        Task { await viewModel.sendComposed(text: message, mentions: mentions) }
    }

    private func replyBanner(_ target: MessageItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
            (Text("Replying to ") + Text(target.displayName).bold())
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                viewModel.replyTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    #if os(iOS)
                    // 44pt touch target.
                    .padding(13)
                    .contentShape(Rectangle())
                    .padding(-13)
                    #endif
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .appendixBubble()
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble")
                .font(.caption2)
            Text(typingText)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .appendixBubble()
    }

    private var typingText: String {
        // Display name, falling back to the mxid localpart.
        let names = viewModel.typingUsers.map { userId in
            viewModel.membersById[userId]?.name
                ?? (userId.hasPrefix("@")
                    ? String(userId.dropFirst().prefix(while: { $0 != ":" }))
                    : userId)
        }
        switch names.count {
        case 1: return String(localized: "\(names[0]) is typing…")
        case 2: return String(localized: "\(names[0]) and \(names[1]) are typing…")
        default: return String(localized: "Several people are typing…")
        }
    }
}

#if os(iOS)
/// Zero-size view that reports its hosting UIWindow, so keyboard-notification
/// filtering can reason about its own scene.
private struct WindowCapture: UIViewRepresentable {
    let onWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onWindow = onWindow
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        uiView.onWindow = onWindow
    }

    final class CaptureView: UIView {
        var onWindow: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let window = self.window
            let onWindow = self.onWindow
            // Deferred: didMoveToWindow can land mid view-update, where
            // mutating @State is undefined.
            DispatchQueue.main.async { onWindow?(window) }
        }
    }
}
#endif

/// Composer "appendix" styling: a compact glass tag hugging its content.
private extension View {
    func appendixBubble() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 360, alignment: .leading)
    }
}

private extension AnyTransition {
    /// Grows out of the composer's top edge and shrinks back into it.
    static var appendix: AnyTransition {
        .scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity)
    }
}
