import SwiftUI
@preconcurrency import MatrixRustSDK

/// Shared bits between global and in-room message search.
enum MessageSearch {
    struct Hit: Identifiable {
        let id: String
        let roomId: String
        let sender: String
        let senderName: String
        let timestamp: Date
        let preview: String
        let category: Category
    }

    enum Category: String, CaseIterable, Identifiable {
        case all, text, images, video, audio, files
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .text: "Text"
            case .images: "Images"
            case .video: "Video"
            case .audio: "Audio"
            case .files: "Files"
            }
        }
    }

    static func hit(roomId: String, event: RoomSearchResult) -> Hit {
        var senderName = event.sender
        if case .ready(let displayName, _, _) = event.senderProfile, let displayName {
            senderName = displayName
        }
        return Hit(
            id: event.eventId,
            roomId: roomId,
            sender: event.sender,
            senderName: senderName,
            timestamp: Date(timeIntervalSince1970: Double(event.timestamp) / 1000),
            preview: RoomSummary.previewText(from: event.content) ?? "…",
            category: category(of: event.content)
        )
    }

    static func category(of content: TimelineItemContent) -> Category {
        guard case .msgLike(let msgLike) = content else { return .text }
        switch msgLike.kind {
        case .message(let message):
            switch message.msgType {
            case .image, .gallery: return .images
            case .video: return .video
            case .audio: return .audio
            case .file: return .files
            default: return .text
            }
        case .sticker: return .images
        default: return .text
        }
    }
}

private struct SearchHitRow: View {
    let hit: MessageSearch.Hit
    /// Shown above the message; nil in single-room search.
    var roomName: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let roomName {
                        Text(roomName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(hit.timestamp, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    Text(hit.senderName)
                        .font(.callout.weight(.semibold))
                    Text(hit.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Global message search across joined rooms, with media-type filtering.
struct SearchResultsSheet: View {
    let scope: SessionScope
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Seeded from the sidebar's search text, editable in-sheet so a typo doesn't
    /// need a dismiss/retype/reopen.
    @State private var searchText: String
    @State private var searchDebounce: Task<Void, Never>?
    @State private var hits: [MessageSearch.Hit] = []
    @State private var isLoading = false
    @State private var canLoadMore = false
    @State private var category: MessageSearch.Category = .all
    @State private var iterator: GlobalSearchIterator?
    /// Set when the search request itself failed, so the view can offer a
    /// retry instead of a false "No Results".
    @State private var searchError: String?

    init(scope: SessionScope, query: String) {
        self.scope = scope
        _searchText = State(initialValue: query)
    }
    /// Resolved in loadMore, not body, so rows don't re-render on every 100ms
    /// summary flush.
    @State private var roomNames: [String: String] = [:]

    private var filtered: [MessageSearch.Hit] {
        category == .all ? hits : hits.filter { $0.category == category }
    }

    var body: some View {
        // macOS: fixed-size card. iOS: full sheet with a nav bar.
        #if os(macOS)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Results for “\(searchText)”", systemImage: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            resultsContent
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .task { await startSearch() }
        #else
        NavigationStack {
            resultsContent
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search messages and media")
                .onChange(of: searchText) { _, _ in debounceSearch() }
        }
        .task { await startSearch() }
        #endif
    }

    /// Restarts the search a beat after typing stops.
    private func debounceSearch() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await startSearch()
        }
    }

    private var resultsContent: some View {
        VStack(spacing: 10) {
            CategorySegmentedControl(selection: $category)
                #if os(iOS)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                #endif

            if isLoading && hits.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError, hits.isEmpty {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("Try Again") {
                        Task { await startSearch() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        List(filtered) { hit in
            SearchHitRow(hit: hit, roomName: roomNames[hit.roomId] ?? hit.roomId) {
                // The navigation layer handles opening the room and scrolling.
                appState.pendingEventNavigation = .init(roomId: hit.roomId, eventId: hit.id)
                dismiss()
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        #else
        .listStyle(.plain)
        #endif

        if canLoadMore {
            Button("Load More Results") {
                Task { await loadMore() }
            }
            .disabled(isLoading)
        }
    }

    private func startSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        // Reset for a fresh query; re-runs on every edit via the debounce.
        hits = []
        iterator = nil
        canLoadMore = false
        searchError = nil
        guard !trimmed.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let iterator = try await scope.service.client.searchMessages(
                query: trimmed, filter: .rooms, numResultsPerBatch: 40)
            self.iterator = iterator
            await loadMore()
        } catch {
            canLoadMore = false
            searchError = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let iterator else { return }
        isLoading = true
        defer { isLoading = false }
        let batch: [GlobalSearchResult]
        do {
            // nil = no more results, distinct from a request failure.
            guard let next = try await iterator.nextEvents() else {
                canLoadMore = false
                return
            }
            batch = next
        } catch {
            canLoadMore = false
            if hits.isEmpty { searchError = error.localizedDescription }
            return
        }
        canLoadMore = !batch.isEmpty
        hits.append(contentsOf: batch.map {
            MessageSearch.hit(roomId: $0.roomId, event: $0.result)
        })
        // Resolve names once per new room here (untracked by body) rather than
        // per-row during rendering.
        for id in Set(batch.map(\.roomId)) where roomNames[id] == nil {
            roomNames[id] = scope.roomList.rooms.first { $0.id == id }?.name
        }
    }
}

/// In-room search (⌘F). Searches the timeline itself: instant over loaded history,
/// then back-paginates to reach old (and encrypted) messages the SDK's cache-only
/// search misses.
struct RoomSearchSheet: View {
    let viewModel: TimelineViewModel
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var category: MessageSearch.Category = .all
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Newest-first matches over everything loaded so far.
    private var matches: [MessageItem] {
        let q = trimmedQuery
        guard !q.isEmpty || category != .all else { return [] }
        return viewModel.entries.reversed().compactMap { entry -> MessageItem? in
            guard case .message(let message) = entry, message.eventId != nil else { return nil }
            guard category == .all || Self.category(of: message.kind) == category else { return nil }
            guard q.isEmpty || Self.searchText(of: message).localizedCaseInsensitiveContains(q)
            else { return nil }
            return message
        }
    }

    /// The date search has reached going back, for the footer.
    private var oldestLoaded: Date? {
        for entry in viewModel.entries {
            if case .message(let message) = entry { return message.timestamp }
        }
        return nil
    }

    var body: some View {
        // macOS: fixed-size card. iOS: full sheet with a nav bar.
        #if os(macOS)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Search in \(viewModel.roomName)", systemImage: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            searchContent
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .onChange(of: trimmedQuery) { _, newValue in
            if !newValue.isEmpty && !isScanning { scanOlder(pages: 6) }
        }
        .onDisappear { scanTask?.cancel() }
        #else
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                searchContent
            }
            .padding(16)
            .navigationTitle(Text("Search in \(viewModel.roomName)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: trimmedQuery) { _, newValue in
            if !newValue.isEmpty && !isScanning { scanOlder(pages: 6) }
        }
        .onDisappear { scanTask?.cancel() }
        #endif
    }

    /// Liquid-glass search bubble: a capsule with an inline magnifier and clear
    /// button, replacing the boxed rounded-border field.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search messages and media…", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                // ⌘F means "type now" — autofocus.
                .onAppear { isSearchFieldFocused = true }
                .onSubmit { scanOlder() }
                #if os(iOS)
                .submitLabel(.search)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassSearchCapsule())
    }

    @ViewBuilder
    private var searchContent: some View {
        searchField

        CategorySegmentedControl(selection: $category)
            .padding(.top, 2)

        if matches.isEmpty {
            if trimmedQuery.isEmpty && category == .all {
                ContentUnavailableView("Search This Room",
                                       systemImage: "magnifyingglass",
                                       description: Text("Type to search messages — or pick a media type to browse attachments."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isScanning {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: trimmedQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(matches) { message in
                SearchHitRow(hit: MessageSearch.Hit(
                    id: message.eventId ?? message.id,
                    roomId: viewModel.roomId,
                    sender: message.sender,
                    senderName: message.displayName,
                    timestamp: message.timestamp,
                    preview: Self.previewText(of: message),
                    category: Self.category(of: message.kind)
                ), roomName: nil) {
                    dismiss()
                    if let eventId = message.eventId { onSelect(eventId) }
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }

        // Coverage footer: how deep the search has gone, plus a lever to keep
        // digging through server history.
        HStack(spacing: 8) {
            if isScanning {
                ProgressView().controlSize(.small)
                Text("Searching older messages…")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Stop") { scanTask?.cancel() }
                    .controlSize(.small)
            } else if viewModel.reachedStart {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Searched the whole conversation.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let oldestLoaded {
                    Text("Searched back to \(oldestLoaded, format: .dateTime.day().month().year()).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Search Older Messages") { scanOlder() }
                    .controlSize(.small)
            }
            Spacer()
            Text("^[\(matches.count) result](inflect: true)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// Pulls older history in chunks; `matches` recomputes live as pages land.
    private func scanOlder(pages: Int = 20) {
        guard !isScanning, !viewModel.reachedStart else { return }
        isScanning = true
        scanTask = Task {
            defer { isScanning = false }
            for _ in 0..<pages {
                guard !Task.isCancelled, !viewModel.reachedStart else { return }
                await viewModel.paginateBackwards()
                // Let the diff stream apply before the next round.
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private static func category(of kind: MessageItem.Kind) -> MessageSearch.Category {
        switch kind {
        case .image: .images
        case .audio: .audio
        case .media(_, let systemImage): systemImage == "video" ? .video : .files
        default: .text
        }
    }

    private static func searchText(of message: MessageItem) -> String {
        var parts = [message.displayName]
        switch message.kind {
        case .text(let body), .notice(let body), .emote(let body):
            parts.append(body)
        case .image(let image):
            parts.append(image.filename)
            if let caption = image.caption { parts.append(caption) }
        case .audio(let audio):
            parts.append(audio.filename)
        case .media(let label, _):
            parts.append(label)
        case .poll(let poll):
            parts.append(poll.question)
        case .location(let body, _):
            parts.append(body)
        default:
            break
        }
        return parts.joined(separator: " ")
    }

    private static func previewText(of message: MessageItem) -> String {
        switch message.kind {
        case .text(let body), .notice(let body), .emote(let body): body
        case .image(let image): image.caption ?? image.filename
        case .audio(let audio): audio.isVoiceMessage ? String(localized: "Voice message") : audio.filename
        case .media(let label, _): label
        case .poll(let poll): poll.question
        case .location(let body, _): body.isEmpty ? String(localized: "Shared location") : body
        default: String(localized: "Message")
        }
    }
}

/// Wraps content in the OS "liquid glass" capsule on macOS 26 / iOS 26, falling
/// back to a material-filled capsule with a hairline border on older systems.
private struct GlassSearchCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
    }
}

/// iOS 26-style segmented control for the search category: a glass capsule with
/// a tinted pill that slides to the selected segment, in place of the boxed,
/// divider-separated `.segmented` picker.
private struct CategorySegmentedControl: View {
    @Binding var selection: MessageSearch.Category
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MessageSearch.Category.allCases) { item in
                let selected = item == selection
                Text(item.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(Color.accentColor.opacity(0.85))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.28)) { selection = item }
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .glassEffect(in: Capsule())
    }
}
