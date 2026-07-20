import SwiftUI

/// Holds section-header scroll positions in a reference type so the per-frame
/// minY writes don't invalidate the picker's body. Mutated only from
/// onGeometryChange / onDisappear, both on the main actor.
@MainActor
final class HeaderPositionBox<Key: Hashable> {
    var values: [Key: CGFloat] = [:]
}

/// Compact emoji picker popover; the system palette can't be anchored to a
/// button (it follows the caret), so we draw our own.
struct EmojiPickerView: View {
    /// Custom emoji packs (MSC2545), shown above the unicode categories.
    var customPacks: [CustomEmojiStore.Pack] = []
    var loader: MediaLoader?
    /// Present when the surface supports custom emoji (composer, reactions).
    var insertCustom: ((CustomEmojiStore.Emote) -> Void)?
    /// Reports search-field focus so the iOS expression panel can coexist with
    /// the keyboard instead of being dismissed by it.
    var onSearchFocusChange: ((Bool) -> Void)?
    let insert: (String) -> Void

    @AppStorage("recentEmoji") private var recentEmojiStorage = ""
    @FocusState private var searchFocused: Bool
    @State private var category = 0
    @State private var query = ""
    /// Measured width of the bottom category bar, divided into equal slots.
    @State private var barWidth: CGFloat = 320
    /// Live minY of each section header, so the bar highlight follows the
    /// scroll. In a reference box, out of observation: every scroll frame
    /// writes a header's minY, and doing that to @State would invalidate the
    /// whole ~1400-cell picker at 120Hz. The derived category hits @State only
    /// when it flips.
    @State private var headerPositions = HeaderPositionBox<Int>()
    @State private var scrolledCategory = 0

    /// The section whose header most recently crossed the top.
    private func computeScrolledCategory() -> Int {
        let positions = headerPositions.values
        let passed = positions.filter { $0.value <= 90 }
        if let current = passed.max(by: { $0.value < $1.value }) { return current.key }
        // No header across the top line (deep in a tall category, or at the
        // very top): keep the current selection. Falling back to the topmost
        // visible header jumped the highlight ahead mid-scroll.
        return scrolledCategory
    }

    private var recents: [String] {
        recentEmojiStorage.split(separator: " ").map(String.init)
    }

    // fileprivate: EmojiShortcodes below derives its index from this catalog.
    fileprivate static let categories: [(icon: String, title: LocalizedStringKey, emoji: [String])] = [
        ("face.smiling", "Smileys", ["😀","😃","😄","😁","😆","😅","😂","🤣","🥲","🥹","☺️","😊","😇","🙂","🙃","😉","😌","😍","🥰","😘","😗","😙","😚","😋","😛","😝","😜","🤪","🤨","🧐","🤓","😎","🥸","🤩","🥳","😏","😒","😞","😔","😟","😕","🙁","☹️","😣","😖","😫","😩","🥺","😢","😭","😮‍💨","😤","😠","😡","🤬","🤯","😳","🥵","🥶","😱","😨","😰","😥","😓","🤗","🤔","🫣","🤭","🫢","🫡","🤫","🤥","😶","😶‍🌫️","🫥","😐","🫤","😑","😬","🙄","😯","😦","😧","😮","😲","🥱","😴","🤤","😪","😵","😵‍💫","🫨","🤐","🥴","🤢","🤮","🤧","😷","🤒","🤕","🤑","🤠","😈","👿","👹","👺","🤡","💩","👻","💀","☠️","👽","👾","🤖","🎃","😺","😸","😹","😻","😼","😽","🙀","😿","😾","🙈","🙉","🙊"]),
        ("hand.raised", "People & Body", ["👋","🤚","🖐️","✋","🖖","🫱","🫲","🫳","🫴","🫷","🫸","👌","🤌","🤏","✌️","🤞","🫰","🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","🫵","👍","👎","✊","👊","🤛","🤜","👏","🙌","🫶","👐","🤲","🤝","🙏","✍️","💅","🤳","💪","🦾","🦿","🦵","🦶","👂","🦻","👃","🧠","🫀","🫁","🦷","🦴","👀","👁️","👅","👄","🫦","💋"]),
        ("person", "People & Clothing", ["👶","🧒","👦","👧","🧑","👱","👨","🧔","👩","🧓","👴","👵","🙍","🙎","🙅","🙆","💁","🙋","🧏","🙇","🤦","🤷","👮","🕵️","💂","🥷","👷","🫅","🤴","👸","👳","👲","🧕","🤵","👰","🤰","🫃","🫄","🤱","👼","🎅","🤶","🦸","🦹","🧙","🧚","🧛","🧜","🧝","🧞","🧟","🧌","💆","💇","🚶","🧍","🧎","🏃","💃","🕺","🕴️","👯","🧖","🧗","👭","👫","👬","💏","💑","👪","🗣️","👤","👥","🫂","👣","🧳","🌂","☂️","🧵","🪡","🪢","🧶","👓","🕶️","🥽","🥼","🦺","👔","👕","👖","🧣","🧤","🧥","🧦","👗","👘","🥻","🩱","🩲","🩳","👙","👚","👛","👜","👝","🎒","🩴","👞","👟","🥾","🥿","👠","👡","🩰","👢","👑","👒","🎩","🎓","🧢","🪖","⛑️","📿","💄","💍","💼"]),
        ("pawprint", "Animals & Nature", ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨","🐯","🦁","🐮","🐷","🐽","🐸","🐵","🐔","🐧","🐦","🐦‍⬛","🐤","🐣","🐥","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🪱","🐛","🦋","🐌","🐞","🐜","🪰","🪲","🪳","🦟","🦗","🕷️","🕸️","🦂","🐢","🐍","🦎","🦖","🦕","🐙","🦑","🪼","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🦭","🐊","🐅","🐆","🦓","🦍","🦧","🦣","🐘","🦛","🦏","🐪","🐫","🦒","🦘","🦬","🐃","🐂","🐄","🐎","🐖","🐏","🐑","🦙","🐐","🦌","🫎","🐕","🐩","🦮","🐕‍🦺","🐈","🐈‍⬛","🪶","🪽","🐓","🦃","🦤","🦚","🦜","🦢","🪿","🦩","🕊️","🐇","🦝","🦨","🦡","🦫","🦦","🦥","🐁","🐀","🐿️","🦔","🐾","🐉","🐲","🌵","🎄","🌲","🌳","🌴","🪵","🌱","🌿","☘️","🍀","🎍","🪴","🎋","🍃","🍂","🍁","🪹","🪺","🍄","🐚","🪸","🪨","🌾","💐","🌷","🪷","🌹","🥀","🌺","🌸","🪻","🌼","🌻","🌞","🌝","🌛","🌜","🌚","🌕","🌖","🌗","🌘","🌑","🌒","🌓","🌔","🌙","🌎","🌍","🌏","🪐","💫","⭐","🌟","✨","⚡","☄️","💥","🔥","🌪️","🌈","☀️","🌤️","⛅","🌥️","☁️","🌦️","🌧️","⛈️","🌩️","🌨️","❄️","☃️","⛄","🌬️","💨","💧","💦","🫧","☔","🌊","🌫️"]),
        ("fork.knife", "Food & Drink", ["🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶️","🫑","🌽","🥕","🫒","🧄","🧅","🥔","🍠","🥐","🥯","🍞","🥖","🥨","🧀","🥚","🍳","🧈","🥞","🧇","🥓","🥩","🍗","🍖","🌭","🍔","🍟","🍕","🫓","🥪","🥙","🧆","🌮","🌯","🫔","🥗","🥘","🫕","🥫","🍝","🍜","🍲","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚","🍘","🍥","🥠","🥮","🍢","🍡","🍧","🍨","🍦","🥧","🧁","🍰","🎂","🍮","🍭","🍬","🍫","🍿","🍩","🍪","🥜","🌰","🫘","🍯","🥛","🍼","☕","🍵","🫖","🧃","🥤","🧋","🍶","🍺","🍻","🥂","🍷","🥃","🍸","🍹","🧉","🍾","🧊","🧂","🥣","🥡","🥢","🍽️","🍴","🥄"]),
        ("soccerball", "Activity", ["⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱","🪀","🏓","🏸","🏒","🏑","🥍","🏏","🪃","🥅","⛳","🪁","🏹","🎣","🤿","🥊","🥋","🎽","🛹","🛼","🛷","⛸️","🥌","🎿","⛷️","🏂","🪂","🏋️","🤼","🤸","⛹️","🤺","🤾","🏌️","🏇","🧘","🏄","🏊","🤽","🚣","🧗","🚵","🚴","🏆","🥇","🥈","🥉","🏅","🎖️","🏵️","🎗️","🎫","🎟️","🎪","🤹","🎭","🩰","🎨","🎬","🎤","🎧","🎼","🎹","🥁","🪘","🎷","🎺","🪗","🎸","🪕","🎻","🎲","♟️","🎯","🎳","🎮","🎰","🧩"]),
        ("car", "Travel & Places", ["🚗","🚕","🚙","🚌","🚎","🏎️","🚓","🚑","🚒","🚐","🛻","🚚","🚛","🚜","🦯","🦽","🦼","🛴","🚲","🛵","🏍️","🛺","🛞","🚨","🚔","🚍","🚘","🚖","🚡","🚠","🚟","🚃","🚋","🚞","🚝","🚄","🚅","🚈","🚂","🚆","🚇","🚊","🚉","✈️","🛫","🛬","🛩️","💺","🛰️","🚀","🛸","🚁","🛶","⛵","🚤","🛥️","🛳️","⛴️","🚢","🛟","⚓","🪝","⛽","🚧","🚦","🚥","🗺️","🗿","🗽","🗼","🏰","🏯","🏟️","🎡","🎢","🎠","⛲","⛱️","🏖️","🏝️","🏜️","🌋","⛰️","🏔️","🗻","🏕️","⛺","🛖","🏠","🏡","🏘️","🏚️","🏗️","🏭","🏢","🏬","🏣","🏤","🏥","🏦","🏨","🏪","🏫","🏩","💒","🏛️","⛪","🕌","🕍","🛕","🕋","⛩️","🏞️","🌁","🌃","🏙️","🌄","🌅","🌆","🌇","🌉","🎆","🎇","🌠","🗾"]),
        ("lightbulb", "Objects", ["⌚","📱","📲","💻","⌨️","🖥️","🖨️","🖱️","🖲️","🕹️","🗜️","💽","💾","💿","📀","📼","📷","📸","📹","🎥","📽️","🎞️","📞","☎️","📟","📠","📺","📻","🎙️","🎚️","🎛️","🧭","⏱️","⏲️","⏰","🕰️","⌛","⏳","📡","🔋","🪫","🔌","💡","🔦","🕯️","🪔","🧯","🛢️","💸","💵","💴","💶","💷","🪙","💰","💳","💎","⚖️","🪜","🧰","🪛","🔧","🔨","⚒️","🛠️","⛏️","🪚","🔩","⚙️","🪤","🧱","⛓️","🧲","🔫","💣","🧨","🪓","🔪","🗡️","⚔️","🛡️","🚬","⚰️","🪦","⚱️","🏺","🔮","📿","🧿","🪬","💈","⚗️","🔭","🔬","🕳️","🩹","🩺","💊","💉","🩸","🧬","🦠","🧫","🧪","🌡️","🧹","🪠","🧺","🧻","🚽","🚰","🚿","🛁","🛀","🧼","🪥","🪒","🧽","🪣","🧴","🛎️","🔑","🗝️","🚪","🪑","🛋️","🛏️","🛌","🧸","🪆","🖼️","🪞","🪟","🛍️","🛒","🎁","🎈","🎏","🎀","🪄","🪅","🎊","🎉","🪩","🎎","🏮","🎐","🧧","✉️","📩","📨","📧","💌","📥","📤","📦","🏷️","🪧","📪","📫","📬","📭","📮","📯","📜","📃","📄","📑","🧾","📊","📈","📉","🗒️","🗓️","📆","📅","🗑️","📇","🗃️","🗳️","🗄️","📋","📁","📂","🗂️","🗞️","📰","📓","📔","📒","📕","📗","📘","📙","📚","📖","🔖","🧷","🔗","📎","🖇️","📐","📏","🧮","📌","📍","✂️","🖊️","🖋️","✒️","🖌️","🖍️","📝","✏️","🔍","🔎","🔏","🔐","🔒","🔓"]),
        ("number", "Symbols", ["❤️","🩷","🧡","💛","💚","💙","🩵","💜","🖤","🩶","🤍","🤎","💔","❤️‍🔥","❤️‍🩹","❣️","💕","💞","💓","💗","💖","💘","💝","💟","💯","💢","💥","💫","💦","💨","🕳️","💬","🗨️","🗯️","💭","💤","♠️","♥️","♦️","♣️","🃏","🀄","🎴","🔇","🔈","🔉","🔊","📢","📣","📯","🔔","🔕","🎵","🎶","💹","☮️","✝️","☪️","🕉️","☸️","✡️","🔯","🕎","☯️","☦️","🛐","⛎","♈","♉","♊","♋","♌","♍","♎","♏","♐","♑","♒","♓","❌","⭕","❗","❓","❕","❔","‼️","⁉️","💱","💲","⚕️","♻️","⚜️","🔱","📛","🔰","✅","☑️","✔️","✖️","➕","➖","➗","➰","➿","〽️","✳️","✴️","❇️","©️","®️","™️","🔟","🔢","🔣","🔤","🅰️","🆎","🅱️","🆑","🆒","🆓","ℹ️","🆔","Ⓜ️","🆕","🆖","🅾️","🆗","🅿️","🆘","🆙","🆚","⚠️","🚸","⛔","🚫","🚳","🚭","🚯","🚱","🚷","📵","🔞","☢️","☣️","⬆️","↗️","➡️","↘️","⬇️","↙️","⬅️","↖️","↕️","↔️","↩️","↪️","⤴️","⤵️","🔃","🔄","🔙","🔚","🔛","🔜","🔝","🔀","🔁","🔂","▶️","⏩","◀️","⏪","🔼","⏫","🔽","⏬","⏸️","⏹️","⏺️","⏏️","🎦","🔅","🔆","📶","📳","📴"]),
        ("flag", "Flags", ["🏁","🚩","🎌","🏴","🏳️","🏳️‍🌈","🏳️‍⚧️","🏴‍☠️","🇦🇷","🇦🇺","🇦🇹","🇧🇪","🇧🇷","🇨🇦","🇨🇱","🇨🇳","🇨🇴","🇨🇺","🇨🇿","🇩🇰","🇩🇴","🇪🇨","🇪🇬","🇫🇮","🇫🇷","🇩🇪","🇬🇷","🇬🇹","🇭🇳","🇭🇰","🇭🇺","🇮🇸","🇮🇳","🇮🇩","🇮🇪","🇮🇱","🇮🇹","🇯🇵","🇰🇷","🇲🇽","🇳🇱","🇳🇿","🇳🇴","🇵🇦","🇵🇪","🇵🇭","🇵🇱","🇵🇹","🇵🇷","🇷🇴","🇷🇺","🇸🇦","🇸🇬","🇿🇦","🇪🇸","🇸🇪","🇨🇭","🇹🇼","🇹🇭","🇹🇷","🇺🇦","🇦🇪","🇬🇧","🇺🇸","🇺🇾","🇻🇪","🇻🇳"]),
    ]

    /// Unicode names ("grinning face") for search, built once. ZWJ sequences
    /// flatten to component names, fine for contains-matching.
    private static let searchIndex: [(emoji: String, name: String)] = {
        var seen = Set<String>()
        return categories.flatMap(\.emoji).compactMap { emoji in
            guard seen.insert(emoji).inserted else { return nil }
            let name = emoji.applyingTransform(.toUnicodeName, reverse: false)?
                .replacingOccurrences(of: "\\N{", with: " ")
                .replacingOccurrences(of: "}", with: " ")
                .lowercased() ?? ""
            return (emoji, name)
        }
    }()

    #if os(iOS)
    private let gridColumns = [GridItem(.adaptive(minimum: 40, maximum: 44), spacing: 6)]
    private let cellSize: CGFloat = 40
    private let emojiFontSize: CGFloat = 29
    #else
    private let gridColumns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8)
    private let cellSize: CGFloat = 32
    private let emojiFontSize: CGFloat = 22
    #endif

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var searchResults: [String] {
        Self.searchIndex.filter { $0.name.contains(trimmedQuery) }.map(\.emoji)
    }

    /// Packs shown: only when the surface can insert them, and only their
    /// emoticon images. Sticker-only tokens don't convert on send, so offering
    /// them here would produce literal `:text:`.
    private var shownPacks: [CustomEmojiStore.Pack] {
        insertCustom == nil ? [] : customPacks.filter { !$0.emoticons.isEmpty }
    }

    private var customSearchResults: [CustomEmojiStore.Emote] {
        // Colons are how users type shortcodes; strip them for matching.
        let needle = trimmedQuery.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        return shownPacks.flatMap(\.emoticons).filter { emote in
            (emote.shortcode.lowercased().contains(needle)
                || emote.body.lowercased().contains(needle))
                && seen.insert(emote.shortcode).inserted
        }
    }

    /// Section index for a custom pack, above the unicode categories' 0…n.
    private func packIndex(_ pack: CustomEmojiStore.Pack) -> Int {
        100 + (shownPacks.firstIndex(of: pack) ?? 0)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if !trimmedQuery.isEmpty {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !customSearchResults.isEmpty {
                        emoteGrid(customSearchResults)
                    }
                    emojiGrid(searchResults)
                }
                .padding(8)
            } else {
                // Every category as a titled section in one scroll; the bottom
                // bar jumps between them.
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !recents.isEmpty {
                        sectionTitle("Frequently Used", index: -1)
                            .id(-1)
                        emojiGrid(recents)
                    }
                    ForEach(shownPacks) { pack in
                        sectionTitle(LocalizedStringKey(pack.displayName),
                                     index: packIndex(pack))
                            .id(packIndex(pack))
                        emoteGrid(pack.emoticons)
                    }
                    ForEach(Self.categories.indices, id: \.self) { index in
                        sectionTitle(Self.categories[index].title, index: index)
                            .id(index)
                        emojiGrid(Self.categories[index].emoji)
                    }
                }
                .padding(8)
            }
        }
        .coordinateSpace(name: "emojiScroll")
        .overlay {
            if !trimmedQuery.isEmpty && searchResults.isEmpty && customSearchResults.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        // Carved out of the scroll area so the search field stays in the frame.
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
                    // Emoji shortcodes aren't dictionary words.
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            // The bare glyph missed easily and fell through to
                            // the grid.
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
        // Same carve-out for the category bar at the bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Divider()
                // Scrolls when packs overflow; the system categories fit
                // without packs.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        if !recents.isEmpty {
                            categoryButton(index: -1, icon: "clock",
                                           title: "Frequently Used", proxy: proxy)
                        }
                        ForEach(shownPacks) { pack in
                            packButton(pack, proxy: proxy)
                        }
                        ForEach(Self.categories.indices, id: \.self) { index in
                            categoryButton(index: index,
                                           icon: Self.categories[index].icon,
                                           title: Self.categories[index].title,
                                           proxy: proxy)
                        }
                    }
                }
                // Measured on the container, not the content (which would feed
                // its own width back into the slot math).
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    barWidth = width
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            // Opaque backdrop: scrolled emoji pass beneath this bar.
            .background(.regularMaterial)
        }
        }
        #if os(macOS)
        .frame(width: 320, height: 320)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private func emojiGrid(_ list: [String]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(list, id: \.self) { emoji in
                Button {
                    insert(emoji)
                    remember(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: emojiFontSize))
                        .frame(width: cellSize, height: cellSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, index: Int) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.horizontal, 4)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("emojiScroll")).minY
            } action: { y in
                headerPositions.values[index] = y
                let derived = computeScrolledCategory()
                if derived != scrolledCategory { scrolledCategory = derived }
            }
            // Drop the position when the header leaves the LazyVStack buffer,
            // so stale off-screen values can't skew `passed` and flicker the
            // highlight.
            .onDisappear {
                headerPositions.values.removeValue(forKey: index)
                let derived = computeScrolledCategory()
                if derived != scrolledCategory { scrolledCategory = derived }
            }
    }

    /// One slot in the bottom bar: equal division of the measured width,
    /// floored so overflow scrolls.
    private var barItemWidth: CGFloat {
        let count = (recents.isEmpty ? 0 : 1) + shownPacks.count + Self.categories.count
        #if os(iOS)
        // Low enough that the packless bar (11 slots) fits an iPhone width.
        return max(34, barWidth / CGFloat(max(1, count)))
        #else
        return max(26, min(34, barWidth / CGFloat(max(1, count))))
        #endif
    }

    #if os(iOS)
    private let barItemHeight: CGFloat = 32
    #else
    private let barItemHeight: CGFloat = 24
    #endif

    private func categoryButton(index: Int, icon: String,
                                title: LocalizedStringKey,
                                proxy: ScrollViewProxy) -> some View {
        Button {
            category = index
            query = ""
            proxy.scrollTo(index, anchor: .top)
        } label: {
            Image(systemName: icon)
                #if os(iOS)
                .font(.system(size: 16))
                #else
                .font(.system(size: 12))
                #endif
                .frame(width: barItemWidth, height: barItemHeight)
                .foregroundStyle(scrolledCategory == index && query.isEmpty
                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(scrolledCategory == index && query.isEmpty
                    ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Announce the section title, not the SF Symbol name, to VoiceOver.
        .accessibilityLabel(Text(title))
    }

    /// A custom pack's slot in the bottom bar, its avatar as the icon.
    private func packButton(_ pack: CustomEmojiStore.Pack,
                            proxy: ScrollViewProxy) -> some View {
        let index = packIndex(pack)
        return Button {
            category = index
            query = ""
            proxy.scrollTo(index, anchor: .top)
        } label: {
            Group {
                if let avatarURL = pack.avatarURL {
                    EmoteImageView(url: avatarURL,
                                   size: barItemHeight - 10,
                                   loader: loader)
                } else {
                    Image(systemName: "star")
                        .font(.system(size: 14))
                }
            }
            .frame(width: barItemWidth, height: barItemHeight)
            .foregroundStyle(scrolledCategory == index && query.isEmpty
                ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(scrolledCategory == index && query.isEmpty
                ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pack.displayName)
        .accessibilityLabel(Text(pack.displayName))
    }

    /// Grid of custom emotes, matching the unicode grid's cell metrics.
    private func emoteGrid(_ emotes: [CustomEmojiStore.Emote]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(emotes) { emote in
                Button {
                    insertCustom?(emote)
                } label: {
                    EmoteImageView(url: emote.url, size: cellSize - 8, loader: loader)
                        .frame(width: cellSize, height: cellSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(emote.token)
                .accessibilityLabel(Text(emote.token))
            }
        }
    }

    private func remember(_ emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentEmojiStorage = list.prefix(24).joined(separator: " ")
    }
}

/// Unicode emoji addressable by `:shortcode:` tokens derived from their
/// Unicode names ("PLEADING FACE" → `pleading_face`). Backs the composer's
/// `:token:` autocomplete and closing-colon auto-replace.
@MainActor
enum EmojiShortcodes {
    static let entries: [(emoji: String, shortcode: String)] = {
        var seen = Set<String>()
        return EmojiPickerView.categories.flatMap(\.emoji).compactMap { emoji in
            guard seen.insert(emoji).inserted,
                  let name = emoji.applyingTransform(.toUnicodeName, reverse: false)
            else { return nil }
            let cleaned = name
                .replacingOccurrences(of: "\\N{", with: " ")
                .replacingOccurrences(of: "}", with: " ")
                // ZWJ/variation plumbing is noise in a shortcode.
                .replacingOccurrences(of: "VARIATION SELECTOR-16", with: " ")
                .replacingOccurrences(of: "ZERO WIDTH JOINER", with: " ")
                .lowercased()
            let shortcode = cleaned
                .split(whereSeparator: { $0 == " " || $0 == "-" })
                .joined(separator: "_")
            guard !shortcode.isEmpty else { return nil }
            return (emoji, shortcode)
        }
    }()

    static let byShortcode: [String: String] =
        Dictionary(entries.map { ($0.shortcode, $0.emoji) }) { first, _ in first }

    /// Prefix matches first, then contains — the composer's suggestion feed.
    static func matches(_ needle: String, limit: Int) -> [(emoji: String, shortcode: String)] {
        guard !needle.isEmpty else { return [] }
        var prefix: [(emoji: String, shortcode: String)] = []
        var contains: [(emoji: String, shortcode: String)] = []
        for entry in entries {
            if entry.shortcode.hasPrefix(needle) {
                prefix.append(entry)
                if prefix.count == limit { break }
            } else if contains.count < limit, entry.shortcode.contains(needle) {
                contains.append(entry)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }
}

/// Emoji and stickers behind one button, switched with a tab bar.
struct EmojiStickerPickerView: View {
    let stickerStore: StickerStore?
    let mediaLoader: MediaLoader?
    var customEmoji: CustomEmojiStore?
    let insertEmoji: (String) -> Void
    /// Inserts a custom emote token into the composer.
    var insertCustomEmoji: ((CustomEmojiStore.Emote) -> Void)?
    let sendSticker: (StickerStore.Sticker) -> Void
    /// Sends a room/space-pack sticker.
    var sendPackSticker: ((CustomEmojiStore.Emote) -> Void)?
    /// Bubbles the active tab's search-field focus to the composer.
    var onSearchFocusChange: ((Bool) -> Void)?

    private enum Tab: Hashable {
        case emoji, stickers
    }

    @State private var tab: Tab = .emoji

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack(spacing: 6) {
                tabButton("Emoji", .emoji)
                tabButton("Stickers", .stickers)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            #else
            Picker("", selection: $tab) {
                Text("Emoji").tag(Tab.emoji)
                Text("Stickers").tag(Tab.stickers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            #endif

            switch tab {
            case .emoji:
                EmojiPickerView(customPacks: customEmoji?.packs ?? [],
                                loader: mediaLoader,
                                insertCustom: insertCustomEmoji,
                                onSearchFocusChange: onSearchFocusChange,
                                insert: insertEmoji)
                    // Packs go stale as the user joins things; opening the
                    // picker is the natural refresh point.
                    .task { await customEmoji?.refreshIfStale() }
            case .stickers:
                if let stickerStore, let mediaLoader {
                    StickerPickerView(store: stickerStore, loader: mediaLoader,
                                      customEmoji: customEmoji,
                                      send: sendSticker,
                                      sendPackSticker: sendPackSticker,
                                      onSearchFocusChange: onSearchFocusChange)
                } else {
                    ContentUnavailableView("No stickers yet", systemImage: "face.smiling")
                        .frame(width: 320, height: 320)
                }
            }
        }
        // Switching tabs destroys the active picker mid-focus; its focus
        // reporter never fires false, leaving the composer's panel-search
        // latch stuck.
        .onChange(of: tab) { _, _ in
            onSearchFocusChange?(false)
        }
    }

    #if os(iOS)
    private func tabButton(_ title: LocalizedStringKey, _ value: Tab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(tab == value ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(tab == value
                    ? AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
                    : AnyShapeStyle(.clear),
                    in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
    #endif
}
