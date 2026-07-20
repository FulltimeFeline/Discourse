import Foundation
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Observation
@preconcurrency import MatrixRustSDK

/// The user's personal sticker pack, stored in `im.ponies.user_emotes`
/// account data (MSC2545).
@MainActor
@Observable
final class StickerStore {
    struct Sticker: Identifiable, Hashable {
        var id: String { shortcode }
        let shortcode: String
        var body: String
        var url: String       // mxc://
        var width: Int
        var height: Int
        var mimetype: String
        var size: Int
        /// Organizational pack name (Discourse-specific; ignored elsewhere).
        var pack: String = Self.defaultPack

        static let defaultPack = String(localized: "My Stickers")
    }

    /// Pack names in display order.
    var packs: [String] {
        var seen: [String] = []
        for sticker in stickers where !seen.contains(sticker.pack) {
            seen.append(sticker.pack)
        }
        return seen
    }

    func stickers(inPack pack: String) -> [Sticker] {
        stickers.filter { $0.pack == pack }
    }

    private static let accountDataType = "im.ponies.user_emotes"
    private let client: Client
    private(set) var stickers: [Sticker] = []
    private(set) var errorMessage: String?

    init(client: Client) {
        self.client = client
    }

    /// Whether an image entry is ours (declared sticker usage or our pack tag).
    /// Foreign custom emoji must never be imported or rewritten here.
    private static func isSticker(_ entry: [String: Any]) -> Bool {
        if let usage = entry["usage"] as? [String], !usage.isEmpty {
            return usage.contains("sticker")
        }
        return entry["es.discourse.pack"] != nil
    }

    func load() async {
        guard let json = try? await client.accountData(eventType: Self.accountDataType),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["images"] as? [String: [String: Any]]
        else { return }

        stickers = images.compactMap { shortcode, entry in
            guard Self.isSticker(entry), let url = entry["url"] as? String else { return nil }
            let info = entry["info"] as? [String: Any] ?? [:]
            return Sticker(
                shortcode: shortcode,
                body: entry["body"] as? String ?? shortcode,
                url: url,
                width: info["w"] as? Int ?? 512,
                height: info["h"] as? Int ?? 512,
                mimetype: info["mimetype"] as? String ?? "image/png",
                size: info["size"] as? Int ?? 0,
                pack: entry["es.discourse.pack"] as? String ?? Sticker.defaultPack
            )
        }
        .sorted { $0.shortcode.localizedCaseInsensitiveCompare($1.shortcode) == .orderedAscending }
    }

    /// Foreign shortcodes in the shared event, which must never be overwritten
    /// by a same-named sticker.
    private func foreignShortcodes() async -> Set<String> {
        guard let json = try? await client.accountData(eventType: Self.accountDataType),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["images"] as? [String: [String: Any]]
        else { return [] }
        return Set(images.filter { !Self.isSticker($0.value) }.keys)
    }

    /// Appends a numeric suffix until the shortcode collides with neither a
    /// foreign nor an existing local entry.
    private func uniqueStickerShortcode(_ base: String, foreignShortcodes: Set<String>) -> String {
        let localShortcodes = Set(stickers.map(\.shortcode))
        func taken(_ code: String) -> Bool {
            foreignShortcodes.contains(code)
        }
        guard taken(base) else { return base }
        var suffix = 2
        while true {
            let candidate = "\(base)_\(suffix)"
            if !taken(candidate) && !localShortcodes.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    /// Square-crops and downscales to 512px PNG, uploads, and files it in the
    /// pack.
    func add(name: String, imageData: Data, pack: String = Sticker.defaultPack) async {
        errorMessage = nil
        guard let processed = Self.makeStickerPNG(from: imageData) else {
            errorMessage = String(localized: "That image couldn't be read.")
            return
        }
        do {
            let mxcUrl = try await client.uploadMedia(mimeType: "image/png",
                                                      data: processed.data,
                                                      progressWatcher: nil)
            let shortcode = name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let packName = pack.trimmingCharacters(in: .whitespaces)
            // Uniquify up front so save() can't overwrite a same-named foreign
            // emoji sharing this event.
            let baseShortcode = shortcode.isEmpty ? "sticker_\(stickers.count + 1)" : shortcode
            let uniqueShortcode = uniqueStickerShortcode(baseShortcode,
                                                         foreignShortcodes: await foreignShortcodes())
            let sticker = Sticker(
                shortcode: uniqueShortcode,
                body: name,
                url: mxcUrl,
                width: processed.width,
                height: processed.height,
                mimetype: "image/png",
                size: processed.data.count,
                pack: packName.isEmpty ? Sticker.defaultPack : packName
            )
            stickers.removeAll { $0.shortcode == sticker.shortcode }
            stickers.append(sticker)
            try await save()
        } catch {
            errorMessage = String(localized: "Couldn't save the sticker: \(error.localizedDescription)")
        }
    }

    func remove(_ shortcode: String) async {
        errorMessage = nil
        stickers.removeAll { $0.shortcode == shortcode }
        do {
            try await save()
        } catch {
            // Surface and re-sync; a silent failure resurrects the sticker on
            // the next load.
            errorMessage = String(localized: "Couldn't remove the sticker: \(error.localizedDescription)")
            await load()
        }
    }

    private func save() async throws {
        // Merge into current server content: this event also carries the user's
        // custom emoji, which a wholesale replace would turn into stickers.
        var root: [String: Any] = [:]
        if let json = try? await client.accountData(eventType: Self.accountDataType),
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var images = (root["images"] as? [String: [String: Any]]) ?? [:]
        // Drop only our own entries; foreign ones stay verbatim.
        let foreignKeys = Set(images.filter { !Self.isSticker($0.value) }.keys)
        images = images.filter { !Self.isSticker($0.value) }
        for sticker in stickers {
            // Never overwrite a foreign entry, even on a shortcode collision.
            guard !foreignKeys.contains(sticker.shortcode) else { continue }
            images[sticker.shortcode] = [
                "body": sticker.body,
                "url": sticker.url,
                "usage": ["sticker"],
                "es.discourse.pack": sticker.pack,
                "info": [
                    "w": sticker.width,
                    "h": sticker.height,
                    "mimetype": sticker.mimetype,
                    "size": sticker.size,
                ],
            ]
        }
        root["images"] = images
        if root["pack"] == nil {
            root["pack"] = ["display_name": "Discourse"]
        }
        let data = try JSONSerialization.data(withJSONObject: root)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try await client.setAccountData(eventType: Self.accountDataType, content: json)
    }

    /// Center-square-crop + downscale to 512px, preserving transparency.
    private static func makeStickerPNG(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(image.width, image.height)
        let cropRect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                              width: side, height: side)
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        let target = min(side, 512)
        guard let context = CGContext(
            data: nil, width: target, height: target,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }

        // ImageIO PNG encoding — works on both platforms.
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (png as Data, target, target)
    }
}
