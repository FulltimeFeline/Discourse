import Foundation
import Observation
@preconcurrency import MatrixRustSDK

/// Custom emoji (MSC2545) aggregated from `im.ponies.user_emotes` account
/// data, `im.ponies.room_emotes` state in every joined space (plus rooms opted
/// in via `im.ponies.emote_rooms`), and packs of rooms opened this session.
@MainActor
@Observable
final class CustomEmojiStore {
    struct Emote: Identifiable, Hashable {
        /// Shortcode without the wrapping colons.
        let shortcode: String
        let url: String
        let body: String
        let packId: String
        /// Empty = usable as both emoticon and sticker.
        var usage: Set<String> = []
        var width: Int?
        var height: Int?
        var mimetype: String?
        var size: Int?
        var id: String { "\(packId)/\(shortcode)" }
        var token: String { ":\(shortcode):" }
        var isEmoticon: Bool { usage.isEmpty || usage.contains("emoticon") }
        var isSticker: Bool { usage.isEmpty || usage.contains("sticker") }
    }

    struct Pack: Identifiable, Hashable {
        /// "user" for the personal pack, else "roomId|stateKey".
        let id: String
        var displayName: String
        var avatarURL: String?
        var emotes: [Emote]
        var roomId: String?
        var stateKey: String?

        var emoticons: [Emote] { emotes.filter(\.isEmoticon) }
        var stickers: [Emote] { emotes.filter(\.isSticker) }
    }

    /// Display order: personal pack first, then room packs A–Z.
    private(set) var packs: [Pack] = []

    /// Room/space packs with at least one sticker; the personal sticker maker
    /// lives in StickerStore.
    var stickerPacks: [Pack] {
        packs.filter { $0.roomId != nil && !$0.stickers.isEmpty }
    }
    /// shortcode → emoticon, first-wins with the personal pack prioritised.
    private(set) var byShortcode: [String: Emote] = [:]
    /// mxc URL → emote (any usage), for labelling image reactions.
    private(set) var byUrl: [String: Emote] = [:]

    var isEmpty: Bool { packs.allSatisfy(\.emotes.isEmpty) }

    /// Wired by the session scope so refreshes see the current rail without
    /// the store owning room-list state.
    @ObservationIgnored var spacesProvider: () -> [(id: String, name: String)] = { [] }

    private let client: Client
    @ObservationIgnored private var lastRefresh: Date?
    /// Space set as of the last refresh; a change bypasses the throttle.
    @ObservationIgnored private var lastSpaceIds: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Rooms fetched this session, so `ensureRoomPack` is one request per room.
    @ObservationIgnored private var fetchedRoomIds: Set<String> = []
    /// Keyed by source ("user" or a room ID). Rebuilt into `packs`.
    @ObservationIgnored private var packsBySource: [String: [Pack]] = [:]
    /// Room display names, for pack fallbacks.
    @ObservationIgnored private var roomNames: [String: String] = [:]
    /// `im.ponies.room_emotes` state keys per room from its last full-state
    /// fetch (recorded even when empty). Lets the cheap refresh poll each pack
    /// by key instead of re-downloading multi-MB room state every cycle.
    @ObservationIgnored private var packStateKeys: [String: Set<String>] = [:]
    /// Last full-state fetch per room. Full state is the only way to discover
    /// packs under new state keys, so it still runs, just on a long interval.
    @ObservationIgnored private var lastFullFetch: [String: Date] = [:]
    /// How long a room's state-key set is trusted before a full re-fetch.
    private static let fullFetchInterval: TimeInterval = 45 * 60

    init(client: Client) {
        self.client = client
    }

    /// Full refresh, throttled to one pass per 5 minutes unless the space list
    /// changed. Safe to call on every picker open and autocomplete keystroke.
    func refreshIfStale(force: Bool = false) async {
        let currentSpaceIds = Set(spacesProvider().map(\.id))
        if !force, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < 300,
           currentSpaceIds == lastSpaceIds {
            return
        }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Fetches one room's emote packs when its timeline opens, once per session.
    func ensureRoomPack(roomId: String, roomName: String) async {
        guard !fetchedRoomIds.contains(roomId) else { return }
        fetchedRoomIds.insert(roomId)
        roomNames[roomId] = roomName
        guard let credentials = homeserverCredentials else { return }
        let result = await Self.fetchRoomPacksWithKeys(roomId: roomId, roomName: roomName,
                                                       credentials: credentials)
        if let keys = result.keys {
            packStateKeys[roomId] = keys
            lastFullFetch[roomId] = Date()
        }
        if packsBySource[roomId] ?? [] != result.packs {
            packsBySource[roomId] = result.packs
            rebuild()
        }
    }

    /// Base URL + token for the raw state reads.
    private var homeserverCredentials: (base: URL, accessToken: String)? {
        guard let session = try? client.session(),
              let base = URL(string: session.homeserverUrl) else { return nil }
        return (base, session.accessToken)
    }

    // MARK: Refresh pipeline

    private func performRefresh() async {
        lastRefresh = Date()
        let spaces = spacesProvider()
        lastSpaceIds = Set(spaces.map(\.id))
        for (id, name) in spaces { roomNames[id] = name }

        let userPack = await fetchUserPack()

        // Spaces plus rooms opted in via `im.ponies.emote_rooms`.
        var roomIds = spaces.map(\.id)
        for roomId in await fetchEmoteRoomIds() where !roomIds.contains(roomId) {
            roomIds.append(roomId)
        }
        // Keep previously opened rooms' packs fresh.
        for roomId in fetchedRoomIds where !roomIds.contains(roomId) {
            roomIds.append(roomId)
        }

        var bySource: [String: [Pack]] = [:]
        if let userPack { bySource["user"] = [userPack] }
        if let credentials = homeserverCredentials {
            let now = Date()
            await withTaskGroup(of: (roomId: String, packs: [Pack], keys: Set<String>?).self) { group in
                for roomId in roomIds {
                    let name = roomNames[roomId] ?? ""
                    // Per-key poll when keys are known and the last full fetch
                    // is recent; otherwise full state.
                    let stateKeys = packStateKeys[roomId]
                    let recentFull = (lastFullFetch[roomId]).map {
                        now.timeIntervalSince($0) < Self.fullFetchInterval
                    } ?? false
                    if let stateKeys, recentFull {
                        let cached = packsBySource[roomId] ?? []
                        group.addTask {
                            (roomId,
                             await Self.refreshRoomPacksByKey(roomId: roomId, roomName: name,
                                                              stateKeys: stateKeys, cached: cached,
                                                              credentials: credentials),
                             nil)
                        }
                    } else {
                        group.addTask {
                            let result = await Self.fetchRoomPacksWithKeys(roomId: roomId, roomName: name,
                                                                           credentials: credentials)
                            return (roomId, result.packs, result.keys)
                        }
                    }
                }
                for await (roomId, found, keys) in group {
                    fetchedRoomIds.insert(roomId)
                    if let keys {
                        // Full fetch succeeded; a failed one reports nil keys,
                        // leaving the prior record intact.
                        packStateKeys[roomId] = keys
                        lastFullFetch[roomId] = now
                    }
                    if !found.isEmpty { bySource[roomId] = found }
                }
            }
        }
        // Rooms opened via `ensureRoomPack` mid-refresh aren't in `roomIds`;
        // carry their packs over instead of clobbering.
        for (source, packs) in packsBySource
        where source != "user" && !roomIds.contains(source) && bySource[source] == nil {
            bySource[source] = packs
        }
        packsBySource = bySource
        rebuild()
    }

    private func rebuild() {
        var ordered: [Pack] = packsBySource["user"] ?? []
        ordered.append(contentsOf: packsBySource
            .filter { $0.key != "user" }
            .flatMap(\.value)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        ordered.removeAll { $0.emotes.isEmpty }

        var shortcodes: [String: Emote] = [:]
        var urls: [String: Emote] = [:]
        for pack in ordered {
            for emote in pack.emotes {
                if emote.isEmoticon, shortcodes[emote.shortcode] == nil {
                    shortcodes[emote.shortcode] = emote
                }
                if urls[emote.url] == nil { urls[emote.url] = emote }
            }
        }
        if packs != ordered { packs = ordered }
        if byShortcode != shortcodes { byShortcode = shortcodes }
        if byUrl != urls { byUrl = urls }
    }

    // MARK: Sources

    /// `im.ponies.user_emotes` account data; only emoticon-usage images.
    private func fetchUserPack() async -> Pack? {
        guard let json = try? await client.accountData(eventType: "im.ponies.user_emotes"),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let emotes = Self.emotes(fromPackContent: root, packId: "user")
            .filter(\.isEmoticon)
        guard !emotes.isEmpty else { return nil }
        return Pack(id: "user",
                    displayName: String(localized: "My Emoji"),
                    avatarURL: emotes.first?.url,
                    emotes: emotes)
    }

    /// `im.ponies.emote_rooms`: rooms whose packs the user enabled globally.
    private func fetchEmoteRoomIds() async -> [String] {
        guard let json = try? await client.accountData(eventType: "im.ponies.emote_rooms"),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rooms = root["rooms"] as? [String: Any]
        else { return [] }
        return Array(rooms.keys)
    }

    /// Full room state via the client-server API (the FFI doesn't expose
    /// arbitrary state reads), reporting every `im.ponies.room_emotes` state
    /// key (even packs with no usable emotes) so the caller can poll them
    /// cheaply later. `keys` is nil only when the request failed.
    /// Nonisolated: full state is multi-MB for big spaces; the download and
    /// parse must stay off the main actor.
    private nonisolated static func fetchRoomPacksWithKeys(
        roomId: String, roomName: String,
        credentials: (base: URL, accessToken: String)
    ) async -> (packs: [Pack], keys: Set<String>?) {
        var request = URLRequest(url: credentials.base
            .appending(path: "_matrix/client/v3/rooms/\(roomId)/state"))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ([], nil) }

        var found: [Pack] = []
        var keys: Set<String> = []
        for event in events where event["type"] as? String == "im.ponies.room_emotes" {
            guard let content = event["content"] as? [String: Any] else { continue }
            let stateKey = event["state_key"] as? String ?? ""
            keys.insert(stateKey)
            if let pack = pack(fromPackContent: content, stateKey: stateKey,
                               roomId: roomId, roomName: roomName) {
                found.append(pack)
            }
        }
        return (found.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                keys)
    }

    /// One pack from a single `im.ponies.room_emotes` content blob; nil when
    /// it has no usable emotes.
    private nonisolated static func pack(fromPackContent content: [String: Any],
                                         stateKey: String, roomId: String,
                                         roomName: String) -> Pack? {
        let packId = "\(roomId)|\(stateKey)"
        let emotes = Self.emotes(fromPackContent: content, packId: packId)
        guard !emotes.isEmpty else { return nil }
        let meta = content["pack"] as? [String: Any]
        let name = (meta?["display_name"] as? String)
            ?? (stateKey.isEmpty ? nil : stateKey)
            ?? roomName
        return Pack(id: packId,
                    displayName: name.isEmpty ? roomName : name,
                    avatarURL: (meta?["avatar_url"] as? String) ?? emotes.first?.url,
                    emotes: emotes,
                    roomId: roomId,
                    stateKey: stateKey)
    }

    /// Cheap refresh when pack state keys are known: one
    /// `GET /state/im.ponies.room_emotes/{key}` per key. `.found` updates,
    /// `.absent` drops (deleted), `.failed` keeps the cached pack.
    private nonisolated static func refreshRoomPacksByKey(
        roomId: String, roomName: String, stateKeys: Set<String>,
        cached: [Pack], credentials: (base: URL, accessToken: String)
    ) async -> [Pack] {
        var byKey: [String: Pack] = [:]
        for pack in cached { byKey[pack.stateKey ?? ""] = pack }
        await withTaskGroup(of: (String, PackContentResult).self) { group in
            for key in stateKeys {
                group.addTask {
                    (key, await fetchPackContent(roomId: roomId, stateKey: key,
                                                 credentials: credentials))
                }
            }
            for await (key, result) in group {
                switch result {
                case .found(let content):
                    byKey[key] = pack(fromPackContent: content, stateKey: key,
                                      roomId: roomId, roomName: roomName)
                case .absent:
                    byKey[key] = nil
                case .failed:
                    break // keep the cached pack
                }
            }
        }
        return byKey.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Emotes from one MSC2545 pack content. An image's `usage` falls back to
    /// the pack's; absent both, it's usable everywhere.
    private nonisolated static func emotes(fromPackContent content: [String: Any],
                                           packId: String) -> [Emote] {
        guard let images = content["images"] as? [String: [String: Any]] else { return [] }
        let packUsage = (content["pack"] as? [String: Any])?["usage"] as? [String]
        return images.compactMap { shortcode, entry -> Emote? in
            guard let url = entry["url"] as? String, url.hasPrefix("mxc://"),
                  // These URLs get interpolated into outgoing HTML; reject
                  // anything that could break out of an attribute.
                  !url.contains(where: { $0.isWhitespace || "\"'<>&".contains($0) })
            else { return nil }
            let usage = (entry["usage"] as? [String]) ?? packUsage ?? []
            let info = entry["info"] as? [String: Any] ?? [:]
            return Emote(shortcode: shortcode,
                         url: url,
                         body: entry["body"] as? String ?? shortcode,
                         packId: packId,
                         usage: Set(usage),
                         width: info["w"] as? Int,
                         height: info["h"] as? Int,
                         mimetype: info["mimetype"] as? String,
                         size: info["size"] as? Int)
        }
        .sorted { $0.shortcode.localizedCaseInsensitiveCompare($1.shortcode) == .orderedAscending }
    }

    // MARK: Rendering fallback

    /// Maps `:tokens:` in a plain body to known emotes — fallback for messages
    /// whose HTML never reached us.
    func knownEmotes(in body: String) -> [String: String] {
        guard body.contains(":"), !byShortcode.isEmpty else { return [:] }
        var found: [String: String] = [:]
        var remainder = Substring(body)
        while let colon = remainder.firstIndex(of: ":") {
            let afterColon = remainder.index(after: colon)
            var end = afterColon
            while end < remainder.endIndex, Self.isShortcodeCharacter(remainder[end]) {
                end = remainder.index(after: end)
            }
            if end < remainder.endIndex, remainder[end] == ":", end > afterColon,
               let emote = byShortcode[String(remainder[afterColon..<end])] {
                found[emote.token] = emote.url
                remainder = remainder[remainder.index(after: end)...]
            } else {
                remainder = remainder[afterColon...]
            }
        }
        return found
    }

    // MARK: Editing room/space packs

    /// Adds an image to a room's default `im.ponies.room_emotes` pack (state
    /// key ""). Returns an error message on failure, nil on success.
    func addToRoomPack(roomId: String, roomName: String, name: String,
                       imageData: Data, mimeType: String,
                       width: Int? = nil, height: Int? = nil,
                       usage: Set<String>) async -> String? {
        let shortcode = Self.sanitizedShortcode(name)
        guard !shortcode.isEmpty else {
            return String(localized: "Give it a name first.")
        }
        do {
            let mxcUrl = try await client.uploadMedia(mimeType: mimeType,
                                                      data: imageData,
                                                      progressWatcher: nil)
            var entry: [String: Any] = [
                "url": mxcUrl,
                "body": name,
            ]
            if !usage.isEmpty { entry["usage"] = Array(usage).sorted() }
            var info: [String: Any] = ["mimetype": mimeType, "size": imageData.count]
            if let width { info["w"] = width }
            if let height { info["h"] = height }
            entry["info"] = info
            return await mutateRoomPack(roomId: roomId, roomName: roomName) { images in
                images[shortcode] = entry
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes a shortcode from the room's default pack; error message on
    /// failure, nil on success.
    func removeFromRoomPack(roomId: String, roomName: String,
                            shortcode: String) async -> String? {
        await mutateRoomPack(roomId: roomId, roomName: roomName) { images in
            images.removeValue(forKey: shortcode)
        }
    }

    /// Read-modify-write of the room's default (`state_key: ""`) pack, then a
    /// local refetch so the pickers update immediately.
    private func mutateRoomPack(roomId: String, roomName: String,
                                _ mutate: (inout [String: Any]) -> Void) async -> String? {
        guard let credentials = homeserverCredentials,
              let room = try? client.getRoom(roomId: roomId) else {
            return String(localized: "This room isn't available right now.")
        }
        // A fetch failure MUST abort: writing over a pack we couldn't read
        // would replace everyone's emotes with this one change.
        var content: [String: Any]
        switch await Self.fetchPackContent(roomId: roomId, stateKey: "",
                                           credentials: credentials) {
        case .found(let existing): content = existing
        case .absent: content = [:]
        case .failed:
            return String(localized: "Couldn't load the current pack — check your connection and try again.")
        }
        var images = (content["images"] as? [String: Any]) ?? [:]
        mutate(&images)
        content["images"] = images
        if content["pack"] == nil {
            content["pack"] = ["display_name": roomName]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: content)
            guard let json = String(data: data, encoding: .utf8) else {
                return String(localized: "Couldn't encode the pack.")
            }
            _ = try await room.sendStateEventRaw(eventType: "im.ponies.room_emotes",
                                                 stateKey: "", content: json)
        } catch {
            // Usually M_FORBIDDEN — no permission to send state here.
            let text = error.localizedDescription
            return text.contains("M_FORBIDDEN") || text.contains("forbidden")
                ? String(localized: "You don't have permission to edit this room's emoji.")
                : text
        }
        // Refetch so the pickers update without waiting for a refresh cycle.
        let result = await Self.fetchRoomPacksWithKeys(roomId: roomId, roomName: roomName,
                                                       credentials: credentials)
        if let keys = result.keys {
            packStateKeys[roomId] = keys
            lastFullFetch[roomId] = Date()
        }
        fetchedRoomIds.insert(roomId)
        packsBySource[roomId] = result.packs
        rebuild()
        return nil
    }

    /// Result of `GET /state/im.ponies.room_emotes/{stateKey}`. `.absent` and
    /// `.failed` are distinct so the read-modify-write can't treat a timeout
    /// as an empty pack.
    /// @unchecked: `.found` carries decoded JSON (`[String: Any]`, not Sendable)
    /// that crosses a `withTaskGroup` boundary but is only read afterward.
    private enum PackContentResult: @unchecked Sendable {
        case found([String: Any])
        case absent
        case failed
    }

    private nonisolated static func fetchPackContent(
        roomId: String, stateKey: String,
        credentials: (base: URL, accessToken: String)
    ) async -> PackContentResult {
        var url = credentials.base
            .appending(path: "_matrix/client/v3/rooms/\(roomId)/state/im.ponies.room_emotes")
        // Empty state key still needs its path segment.
        url.append(path: stateKey.isEmpty ? "" : stateKey)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        if status == 404 { return .absent }
        guard status == 200,
              let content = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failed }
        return .found(content)
    }

    nonisolated static func sanitizedShortcode(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { isShortcodeCharacter($0) }
    }

    // MARK: Outgoing messages

    /// Characters accepted in a `:token:`.
    nonisolated static func isShortcodeCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
            || character == "."
    }

    /// HTML body (MSC2545 `<img data-mx-emoticon>`) if `text` has known
    /// `:shortcode:` tokens; nil to fall back to the markdown path.
    func htmlBody(for text: String) -> String? {
        guard text.contains(":"), !byShortcode.isEmpty else { return nil }
        var html = ""
        var replaced = false
        var remainder = Substring(text)
        while let colon = remainder.firstIndex(of: ":") {
            html += Self.escapeHTML(remainder[..<colon])
            let afterColon = remainder.index(after: colon)
            // Longest-match scan up to a closing colon.
            var end = afterColon
            while end < remainder.endIndex, Self.isShortcodeCharacter(remainder[end]) {
                end = remainder.index(after: end)
            }
            if end < remainder.endIndex, remainder[end] == ":", end > afterColon,
               let emote = byShortcode[String(remainder[afterColon..<end])] {
                html += "<img data-mx-emoticon src=\"\(Self.escapeHTML(Substring(emote.url)))\" alt=\"\(Self.escapeHTML(Substring(emote.token)))\" title=\"\(Self.escapeHTML(Substring(emote.token)))\" height=\"32\" />"
                replaced = true
                remainder = remainder[remainder.index(after: end)...]
            } else {
                html += ":"
                remainder = remainder[afterColon...]
            }
        }
        html += Self.escapeHTML(remainder)
        guard replaced else { return nil }
        return html.replacingOccurrences(of: "\n", with: "<br/>")
    }

    private static func escapeHTML(_ text: Substring) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
