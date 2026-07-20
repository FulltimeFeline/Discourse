import SwiftUI

/// Parsing and rendering for MSC2545 custom emoji ("emotes").
enum InlineEmotes {
    /// `<img data-mx-emoticon …>` tags in a formatted body, as a
    /// `":shortcode:" → mxc URL` map. The plain-text body carries the same
    /// tokens (the img alt text), which is where rendering swaps them in.
    static func parse(html: String) -> [String: String] {
        guard html.contains("data-mx-emoticon") else { return [:] }
        var found: [String: String] = [:]
        let range = NSRange(html.startIndex..., in: html)
        imgTag.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let tag = String(html[tagRange])
            guard tag.contains("data-mx-emoticon"),
                  let url = attribute("src", in: tag), url.hasPrefix("mxc://"),
                  let name = attribute("alt", in: tag) ?? attribute("title", in: tag)
            else { return }
            let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !trimmed.isEmpty else { return }
            found[":\(trimmed):"] = url
        }
        return found
    }

    /// One rendered segment of a body: literal text or an emote image.
    enum Segment: Hashable {
        case text(String)
        case emote(token: String, url: String)
    }

    /// Splits a plain body on known `:token:` occurrences.
    static func segments(of body: String, emotes: [String: String]) -> [Segment] {
        var segments: [Segment] = []
        var pendingText = ""
        var remainder = Substring(body)
        while let colon = remainder.firstIndex(of: ":") {
            pendingText += remainder[..<colon]
            let afterColon = remainder.index(after: colon)
            var end = afterColon
            while end < remainder.endIndex, CustomEmojiStore.isShortcodeCharacter(remainder[end]) {
                end = remainder.index(after: end)
            }
            if end < remainder.endIndex, remainder[end] == ":", end > afterColon,
               case let token = String(remainder[colon...end]),
               let url = emotes[token] {
                if !pendingText.isEmpty {
                    segments.append(.text(pendingText))
                    pendingText = ""
                }
                segments.append(.emote(token: token, url: url))
                remainder = remainder[remainder.index(after: end)...]
            } else {
                pendingText += ":"
                remainder = remainder[afterColon...]
            }
        }
        pendingText += remainder
        if !pendingText.isEmpty { segments.append(.text(pendingText)) }
        return segments
    }

    private static let imgTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>",
                                                         options: [.caseInsensitive])

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = attributeRegexes[name] else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              // Group 1: double-quoted value; group 2: single-quoted.
              let valueRange = Range(match.range(at: 1), in: tag)
                ?? Range(match.range(at: 2), in: tag) else { return nil }
        // `&amp;` last, or "&amp;lt;" double-decodes to "<".
        return String(tag[valueRange])
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let attributeRegexes: [String: NSRegularExpression] = {
        var regexes: [String: NSRegularExpression] = [:]
        for name in ["src", "alt", "title"] {
            regexes[name] = try? NSRegularExpression(
                pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
                options: [.caseInsensitive])
        }
        return regexes
    }()
}

/// Emote bitmaps rasterised to an exact point height so they can sit inline
/// in `Text` (whose images render at intrinsic size). Keyed url+height.
@MainActor
enum EmoteRasterCache {
    private static var cache: [String: PlatformImage] = [:]
    private static var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    static func cached(url: String, height: CGFloat) -> PlatformImage? {
        cache["\(url)#\(Int(height))"]
    }

    static func image(url: String, height: CGFloat, loader: MediaLoader) async -> PlatformImage? {
        let key = "\(url)#\(Int(height))"
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<PlatformImage?, Never> {
            guard let source = await loader.avatar(mxcUrl: url, pixelSize: height * 3) else {
                return nil
            }
            return rasterize(source, height: height)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache[key] = image }
        return image
    }

    /// Redraws to fit a (1.8×height, height) box preserving aspect ratio, so
    /// wide banners scale down whole instead of being squashed into the cap.
    private static func rasterize(_ source: PlatformImage, height: CGFloat) -> PlatformImage? {
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        var targetWidth = height * sourceSize.width / sourceSize.height
        var targetHeight = height
        if targetWidth > height * 1.8 {
            let scale = height * 1.8 / targetWidth
            targetWidth *= scale
            targetHeight *= scale
        }
        let target = CGSize(width: max(1, targetWidth), height: max(1, targetHeight))
        #if os(macOS)
        let image = NSImage(size: target)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: CGRect(origin: .zero, size: target), from: .zero,
                    operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
        #else
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        #endif
    }
}

/// Message body text with `:shortcode:` tokens swapped for their emote
/// images: small inline with text, large (jumbo) when the message is nothing
/// but emotes. Falls back to the literal token until the image lands.
struct EmoteBodyText: View {
    let body_: String
    let emotes: [String: String]
    let loader: MediaLoader
    /// Trailing decoration, e.g. the "(edited)" suffix.
    var suffix: Text = Text(verbatim: "")
    /// When false, an all-emote message stays inline; mirrors the unicode
    /// jumbo gate in MessageRow.
    var jumboEmoji: Bool = true
    /// Chat text-size preference (0.8…1.4); scales the inline emote height so
    /// emotes track the body text. 1.0 = today's sizes.
    var fontScale: Double = 1.0

    /// Re-renders as images land; the value itself is unused.
    @State private var loadedCount = 0

    #if os(macOS)
    private static let baseInlineHeight: CGFloat = 18
    #else
    private static let baseInlineHeight: CGFloat = 21
    #endif

    /// Inline emote cap height, scaled by the chat text-size preference.
    private var inlineHeight: CGFloat {
        (Self.baseInlineHeight * CGFloat(min(max(fontScale, 0.8), 1.4))).rounded()
    }

    /// Emote urls (with tokens) when the message is nothing but emotes and
    /// whitespace, rendered jumbo as real image views. Text-attachment
    /// rendering can't grow the line box safely at 44pt — the selection
    /// container clips to line fragments and cuts the images vertically.
    private func jumboEmotes(in segments: [InlineEmotes.Segment]) -> [(token: String, url: String)]? {
        var found: [(String, String)] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                guard text.allSatisfy(\.isWhitespace) else { return nil }
            case .emote(let token, let url):
                found.append((token, url))
            }
        }
        // Long runs fall back to inline size rather than overflow the row.
        guard !found.isEmpty, found.count <= 6 else { return nil }
        return found
    }

    var body: some View {
        let segments = InlineEmotes.segments(of: body_, emotes: emotes)
        if jumboEmoji, let jumboEmotes = jumboEmotes(in: segments) {
            HStack(spacing: 4) {
                ForEach(Array(jumboEmotes.enumerated()), id: \.offset) { _, emote in
                    EmoteImageView(url: emote.url, size: 44 * CGFloat(min(max(fontScale, 0.8), 1.4)),
                                   loader: loader)
                        .accessibilityLabel(Text(emote.token))
                }
                suffix
            }
        } else {
            inlineText(segments: segments)
        }
    }

    private func inlineText(segments: [InlineEmotes.Segment]) -> some View {
        let height = inlineHeight
        return composedText(segments: segments, height: height)
            .textSelection(.enabled)
            // The emotes hash catches edits that swap a URL while the plain
            // body is unchanged.
            .task(id: "\(body_)#\(emotes.hashValue)") {
                for case .emote(_, let url) in segments
                where EmoteRasterCache.cached(url: url, height: height) == nil {
                    if await EmoteRasterCache.image(url: url, height: height,
                                                   loader: loader) != nil {
                        loadedCount += 1
                    }
                }
            }
    }

    private func composedText(segments: [InlineEmotes.Segment], height: CGFloat) -> Text {
        // Touch the trigger so SwiftUI re-runs this on image load.
        _ = loadedCount
        var composed = Text(verbatim: "")
        for segment in segments {
            switch segment {
            case .text(let text):
                composed = composed + Text(RenderedBodyCache.rendered(text))
            case .emote(let token, let url):
                if let image = EmoteRasterCache.cached(url: url, height: height) {
                    composed = composed
                        // Fixed, not proportional: proportional pushes the
                        // image out of the line box and it clips.
                        + Text(Image(platformImage: image))
                            .baselineOffset(-2)
                        + Text(verbatim: "\u{200B}")  // keeps selection/wrapping sane
                } else {
                    composed = composed + Text(verbatim: token).foregroundColor(.secondary)
                }
            }
        }
        return composed + suffix
    }
}

/// A single custom emote image at a fixed size (picker cells, reaction chips,
/// autocomplete rows), with a placeholder tile until the bitmap lands.
struct EmoteImageView: View {
    let url: String
    let size: CGFloat
    let loader: MediaLoader?

    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?

    /// Clamped so fractional macOS backing scales don't fragment cache keys.
    private var pixelSize: CGFloat {
        size * min(max(displayScale, 1), 3)
    }

    var body: some View {
        Group {
            if let image = image ?? cachedSeed {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let loader else { return }
            // Reset on url change (persistent view identity, e.g. a pack
            // avatar updating) so the old bitmap doesn't stick.
            image = loader.cachedImage(mxcUrl: url, pixelSize: pixelSize)
            if image == nil {
                image = await loader.avatar(mxcUrl: url, pixelSize: pixelSize)
            }
        }
    }

    /// Synchronous cache hit so recycled rows paint on the first frame.
    private var cachedSeed: PlatformImage? {
        loader?.cachedImage(mxcUrl: url, pixelSize: pixelSize)
    }
}
