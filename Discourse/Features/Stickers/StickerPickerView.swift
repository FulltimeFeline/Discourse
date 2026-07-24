import SwiftUI

/// Grid popover of the user's sticker packs plus any room/space sticker packs
/// (MSC2545 `usage: ["sticker"]`).
struct StickerPickerView: View {
    let store: StickerStore
    let loader: MediaLoader
    var customEmoji: CustomEmojiStore?
    let send: (StickerStore.Sticker) -> Void
    var sendPackSticker: ((CustomEmojiStore.Emote) -> Void)?
    /// Reports search-field focus so the iOS expression panel can coexist with the keyboard.
    var onSearchFocusChange: ((Bool) -> Void)?

    @State private var selectedPack: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var roomPacks: [CustomEmojiStore.Pack] {
        sendPackSticker == nil ? [] : (customEmoji?.stickerPacks ?? [])
    }
    /// Live minY of each section header, so the pack bar follows the scroll. Kept in
    /// a reference box, out of observation: writing it every scroll frame would
    /// re-run the per-tab grids. Only the derived pack lands in @State, on flip.
    @State private var headerPositions = HeaderPositionBox<String>()
    @State private var scrolledPack: String?

    /// The pack whose header most recently crossed the top.
    private func computeScrolledPack() -> String? {
        let positions = headerPositions.values
        let passed = positions.filter { $0.value <= 90 }
        if let current = passed.max(by: { $0.value < $1.value }) { return current.key }
        // No header near the top: keep the current selection.
        return scrolledPack ?? currentPack
    }

    private static let recentsTab = "\u{0}recents"

    // Pack-bar tab metrics: keyboard-sized touch targets on iOS, compact on desktop.
    #if os(iOS)
    private static let tabWidth: CGFloat = 44
    private static let tabHeight: CGFloat = 36
    private static let tabIconSize: CGFloat = 16
    private static let tabThumbSize: CGFloat = 26
    private static let tabCornerRadius: CGFloat = 8
    /// Bumped per sent sticker to fire the send haptic (the panel stays up for chaining).
    @State private var sendCount = 0
    #else
    private static let tabWidth: CGFloat = 30
    private static let tabHeight: CGFloat = 26
    private static let tabIconSize: CGFloat = 12
    private static let tabThumbSize: CGFloat = 22
    private static let tabCornerRadius: CGFloat = 6
    #endif

    private var recentStickers: [StickerStore.Sticker] {
        StickerUsage.recents.compactMap { shortcode in
            store.stickers.first { $0.shortcode == shortcode }
        }
    }

    private var currentPack: String? {
        selectedPack ?? (recentStickers.isEmpty ? store.packs.first : Self.recentsTab)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var searchResults: [StickerStore.Sticker] {
        store.stickers.filter {
            $0.shortcode.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.body.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var packSearchResults: [CustomEmojiStore.Emote] {
        roomPacks.flatMap(\.stickers).filter {
            $0.shortcode.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.body.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// Grid of room-pack stickers, matching the personal grid's metrics.
    private func packStickerGrid(_ emotes: [CustomEmojiStore.Emote]) -> some View {
        #if os(iOS)
        let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]
        #else
        let columns = Array(repeating: GridItem(.fixed(72), spacing: 8), count: 4)
        #endif
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(emotes) { emote in
                Button {
                    sendPackSticker?(emote)
                    #if os(iOS)
                    sendCount += 1
                    #endif
                } label: {
                    EmoteImageView(url: emote.url, size: 72, loader: loader)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(emote.body)
                .accessibilityLabel(Text(emote.body))
            }
        }
    }

    private func stickerGrid(_ stickers: [StickerStore.Sticker]) -> some View {
        #if os(iOS)
        let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]
        #else
        let columns = Array(repeating: GridItem(.fixed(72), spacing: 8), count: 4)
        #endif
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(stickers) { sticker in
                Button {
                    send(sticker)
                    #if os(iOS)
                    sendCount += 1
                    #endif
                } label: {
                    StickerThumb(sticker: sticker, loader: loader, size: 72)
                }
                .buttonStyle(.plain)
                .help(sticker.body)
            }
        }
    }

    private func sectionTitle(_ title: Text, key: String) -> some View {
        title
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("stickerScroll")).minY
            } action: { y in
                headerPositions.values[key] = y
                let derived = computeScrolledPack()
                if derived != scrolledPack { scrolledPack = derived }
            }
            // Drop the position when the header leaves, so stale off-screen values
            // can't skew `passed` and flicker the highlight.
            .onDisappear {
                headerPositions.values.removeValue(forKey: key)
                let derived = computeScrolledPack()
                if derived != scrolledPack { scrolledPack = derived }
            }
    }

    var body: some View {
        Group {
            if store.stickers.isEmpty && roomPacks.isEmpty {
                ContentUnavailableView("No stickers yet",
                                       systemImage: "face.smiling",
                                       description: Text("Make some in Settings → Stickers."))
                    .padding(24)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    if !trimmedQuery.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            stickerGrid(searchResults)
                            if !packSearchResults.isEmpty {
                                packStickerGrid(packSearchResults)
                            }
                        }
                        .padding(12)
                    } else {
                        // One continuous scroll: recents, then each pack as a titled section.
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if !recentStickers.isEmpty {
                                sectionTitle(Text("Recently Used"), key: Self.recentsTab)
                                    .id(Self.recentsTab)
                                stickerGrid(recentStickers)
                            }
                            ForEach(store.packs, id: \.self) { pack in
                                sectionTitle(Text(pack), key: pack)
                                    .id(pack)
                                stickerGrid(store.stickers(inPack: pack))
                            }
                            ForEach(roomPacks) { pack in
                                sectionTitle(Text(pack.displayName), key: pack.id)
                                    .id(pack.id)
                                packStickerGrid(pack.stickers)
                            }
                        }
                        .padding(12)
                    }
                }
                .coordinateSpace(name: "stickerScroll")
                .overlay {
                    if !trimmedQuery.isEmpty && searchResults.isEmpty
                        && packSearchResults.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                // Carved out of the scroll area so the popover can't squeeze the search field out.
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $query)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onChange(of: searchFocused) { _, focused in
                                onSearchFocusChange?(focused)
                            }
                            #if os(iOS)
                            // Shortcodes aren't words.
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    // Real hit target so a near-miss doesn't fall through to the grid.
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect()
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                // Same carve-out for the pack bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        Divider()
                        // Pack tabs: first sticker as icon.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                if !recentStickers.isEmpty {
                                    Button {
                                        selectedPack = Self.recentsTab
                                        query = ""
                                        proxy.scrollTo(Self.recentsTab, anchor: .top)
                                    } label: {
                                        Image(systemName: "clock")
                                            .font(.system(size: Self.tabIconSize))
                                            .foregroundStyle(scrolledPack == Self.recentsTab
                                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                            .frame(width: Self.tabWidth, height: Self.tabHeight)
                                            .background(
                                                scrolledPack == Self.recentsTab
                                                    ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                    : AnyShapeStyle(.clear),
                                                in: Circle()
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Recently used")
                                    .accessibilityLabel(Text("Recently Used"))
                                }
                                ForEach(store.packs, id: \.self) { pack in
                                    Button {
                                        selectedPack = pack
                                        query = ""
                                        proxy.scrollTo(pack, anchor: .top)
                                    } label: {
                                        Group {
                                            if let first = store.stickers(inPack: pack).first {
                                                StickerThumb(sticker: first, loader: loader,
                                                             size: Self.tabThumbSize)
                                            } else {
                                                Text(String(pack.prefix(1)))
                                                    .font(.caption.weight(.semibold))
                                            }
                                        }
                                        .frame(width: Self.tabWidth, height: Self.tabHeight)
                                        .background(
                                            scrolledPack == pack
                                                ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                : AnyShapeStyle(.clear),
                                            in: Circle()
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(pack)
                                    .accessibilityLabel(Text(pack))
                                }
                                ForEach(roomPacks) { pack in
                                    Button {
                                        selectedPack = pack.id
                                        query = ""
                                        proxy.scrollTo(pack.id, anchor: .top)
                                    } label: {
                                        Group {
                                            if let avatarURL = pack.avatarURL {
                                                EmoteImageView(url: avatarURL,
                                                               size: Self.tabThumbSize,
                                                               loader: loader)
                                            } else {
                                                Text(String(pack.displayName.prefix(1)))
                                                    .font(.caption.weight(.semibold))
                                            }
                                        }
                                        .frame(width: Self.tabWidth, height: Self.tabHeight)
                                        .background(
                                            scrolledPack == pack.id
                                                ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                : AnyShapeStyle(.clear),
                                            in: Circle()
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(pack.displayName)
                                    .accessibilityLabel(Text(pack.displayName))
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .padding(.bottom, 6)
                    }
                    .background(.regularMaterial)
                }
                }
                #if os(macOS)
                .frame(width: 340, height: 320)
                #else
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        .task {
            await store.load()
            await customEmoji?.refreshIfStale()
        }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        #endif
    }
}

struct StickerThumb: View {
    let sticker: StickerStore.Sticker
    let loader: MediaLoader
    var size: CGFloat = 72
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: sticker.url) {
            image = await loader.avatar(mxcUrl: sticker.url, pixelSize: size * 2)
        }
    }
}
