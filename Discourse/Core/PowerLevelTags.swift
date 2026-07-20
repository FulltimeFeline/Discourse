import Foundation

/// A named role, mapped from a power level. Interoperates with Cinny's
/// `in.cinny.room.power_level_tags`: `name`, `color`, and a nested `icon`
/// object whose `key` is either a unicode emoji or a custom-emote `mxc://` URL.
struct PowerLevelTag: Equatable, Hashable {
    var name: String
    var color: String?
    /// Cinny's `icon.key`: a unicode emoji, or an `mxc://` URL for a custom emote.
    var iconKey: String?

    init(name: String, color: String? = nil, iconKey: String? = nil) {
        self.name = name
        self.color = color
        self.iconKey = iconKey
    }

    init?(content: [String: Any]) {
        guard let name = (content["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return nil }
        self.name = name
        self.color = content["color"] as? String
        if let icon = content["icon"] as? [String: Any] {
            self.iconKey = icon["key"] as? String
        }
    }

    var content: [String: Any] {
        var dict: [String: Any] = ["name": name]
        if let color { dict["color"] = color }
        if let iconKey { dict["icon"] = ["key": iconKey] }
        return dict
    }

    /// True when `iconKey` points at a custom emote rather than a unicode emoji.
    var iconIsMxc: Bool { iconKey?.hasPrefix("mxc://") == true }
}

enum PowerLevelTags {
    static let eventType = "in.cinny.room.power_level_tags"

    /// Parses the state-event content: a flat map of power level → tag.
    static func parse(_ content: [String: Any]) -> [Int: PowerLevelTag] {
        var tags: [Int: PowerLevelTag] = [:]
        for (key, value) in content {
            guard let level = Int(key), let dict = value as? [String: Any],
                  let tag = PowerLevelTag(content: dict) else { continue }
            tags[level] = tag
        }
        return tags
    }

    static func content(from tags: [Int: PowerLevelTag]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: tags.map { (String($0.key), $0.value.content) })
    }

    /// The label to show for a member at `level`: the exact tag if defined, else
    /// the nearest defined tag at or below it (so a room creator's "infinite"
    /// power still inherits the top role), else a coarse built-in default.
    static func displayTag(forLevel level: Int, in tags: [Int: PowerLevelTag]) -> PowerLevelTag {
        if let exact = tags[level] { return exact }
        if let nearest = tags.keys.filter({ $0 <= level }).max() { return tags[nearest]! }
        return defaultTag(forLevel: level)
    }

    /// Coarse label for a level with no explicit tag (used as an editor
    /// placeholder and the final display fallback).
    static func defaultTag(forLevel level: Int) -> PowerLevelTag {
        switch level {
        case ..<0: PowerLevelTag(name: String(localized: "Muted"))
        case 0..<50: PowerLevelTag(name: String(localized: "Member"))
        case 50..<100: PowerLevelTag(name: String(localized: "Moderator"))
        default: PowerLevelTag(name: String(localized: "Admin"))
        }
    }
}
