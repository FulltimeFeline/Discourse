import Foundation

/// Tracks reaction usage so the quick-reaction slots adapt over time.
enum ReactionUsage {
    private static let countsKey = "reactionUsageCounts"
    private static let defaults = ["👍", "❤️", "😂", "🎉", "😮", "😢", "🔥", "👀"]

    static func record(_ emoji: String) {
        var counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        counts[emoji, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: countsKey)
    }

    /// Most-used reactions, padded with defaults. Filtered to emoji: Matrix
    /// reaction keys can be arbitrary text ("+1", "lol") that would render as a
    /// blank slot.
    static func top(_ count: Int) -> [String] {
        let counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        var result = counts.sorted { $0.value > $1.value }.map(\.key).filter(isEmoji)
        for fallback in defaults where !result.contains(fallback) {
            result.append(fallback)
        }
        return Array(result.prefix(count))
    }

    private static func isEmoji(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && first.value > 0x2100)
    }
}

/// Recently sent stickers, for the picker's recents tab.
enum StickerUsage {
    private static let recentsKey = "recentStickers"

    static func record(_ shortcode: String) {
        var recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recents.removeAll { $0 == shortcode }
        recents.insert(shortcode, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(16)), forKey: recentsKey)
    }

    static var recents: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }
}
