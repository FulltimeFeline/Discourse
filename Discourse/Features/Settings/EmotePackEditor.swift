import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Editor for a room/space's MSC2545 emote pack (`im.ponies.room_emotes`, default
/// state key). Writes require state-event permission.
struct EmotePackEditor: View {
    let model: RoomSettingsModel

    @State private var newName = ""
    @State private var newUsage: Usage = .emoticon
    @State private var stagedImage: Data?
    /// "image/png" for the flatten path, or the source type for a kept animation.
    @State private var stagedMimeType = "image/png"
    @State private var stagedPreview: PlatformImage?
    @State private var showsImporter = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Usage: String, CaseIterable, Identifiable {
        case emoticon, sticker, both
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .emoticon: "Emoji"
            case .sticker: "Sticker"
            case .both: "Both"
            }
        }

        /// MSC2545: an empty usage list means usable as both.
        var usageSet: Set<String> {
            switch self {
            case .emoticon: ["emoticon"]
            case .sticker: ["sticker"]
            case .both: []
            }
        }
    }

    private var store: CustomEmojiStore { model.scope.customEmoji }
    private var loader: MediaLoader { model.scope.mediaLoader }
    private var roomId: String { model.target.roomId }

    private var pack: CustomEmojiStore.Pack? {
        store.packs.first { $0.roomId == roomId && $0.stateKey == "" }
    }

    var body: some View {
        Form {
            Section {
                if let pack, !pack.emotes.isEmpty {
                    ForEach(pack.emotes) { emote in
                        emoteRow(emote)
                    }
                } else {
                    Text(model.target.isSpace
                         ? "No custom emoji in this space yet."
                         : "No custom emoji in this room yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Pack")
            } footer: {
                Text(model.target.isSpace
                     ? "Everyone in the space can use these in messages, reactions, and as stickers."
                     : "Everyone in the room can use these in messages, reactions, and as stickers.")
            }

            Section {
                TextField("Name (becomes :shortcode:)", text: $newName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Picker("Usable as", selection: $newUsage) {
                    ForEach(Usage.allCases) { usage in
                        Text(usage.label).tag(usage)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    if let stagedPreview {
                        Image(platformImage: stagedPreview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Button(stagedImage == nil ? "Choose Image…" : "Change Image…") {
                        showsImporter = true
                    }
                }
                Button {
                    add()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add to Pack")
                    }
                }
                .disabled(isWorking || stagedImage == nil
                          || CustomEmojiStore.sanitizedShortcode(newName).isEmpty)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Add Emoji or Sticker")
            } footer: {
                Text("Images are scaled down to 256 px; small animated GIFs are kept as-is. Emotes are shared as part of the \(model.target.isSpace ? "space" : "room"). You need permission to change \(model.target.isSpace ? "space" : "room") settings.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let raw = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(raw as CFData, nil) else {
                errorMessage = String(localized: "That image couldn't be read.")
                return
            }
            // Keep a small animated GIF/WebP intact; flatten everything else to PNG.
            if CGImageSourceGetCount(source) > 1, raw.count <= 512 * 1024,
               let type = CGImageSourceGetType(source),
               let mime = UTType(type as String)?.preferredMIMEType {
                errorMessage = nil
                stagedImage = raw
                stagedMimeType = mime
                stagedPreview = PlatformImage(data: raw)
            } else {
                guard let processed = Self.processedEmoteImage(from: raw) else {
                    errorMessage = String(localized: "That image couldn't be read.")
                    return
                }
                errorMessage = nil
                stagedImage = processed.data
                stagedMimeType = "image/png"
                stagedPreview = PlatformImage(data: processed.data)
            }
            if newName.isEmpty {
                newName = url.deletingPathExtension().lastPathComponent
            }
        }
        .task {
            await store.ensureRoomPack(roomId: roomId, roomName: model.name)
        }
    }

    private func emoteRow(_ emote: CustomEmojiStore.Emote) -> some View {
        HStack(spacing: 10) {
            EmoteImageView(url: emote.url, size: 28, loader: loader)
            VStack(alignment: .leading, spacing: 1) {
                Text(emote.token)
                    .font(.callout)
                    .lineLimit(1)
                Text(emote.usage.isEmpty
                     ? String(localized: "Emoji & sticker")
                     : emote.usage.contains("sticker")
                        ? String(localized: "Sticker")
                        : String(localized: "Emoji"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                remove(emote)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .help("Remove from pack")
            .accessibilityLabel(Text("Remove \(emote.token)"))
        }
    }

    private func add() {
        guard let stagedImage else { return }
        let processedName = newName
        let usage = newUsage.usageSet
        isWorking = true
        errorMessage = nil
        Task {
            let size = Self.pixelSize(of: stagedImage)
            let error = await store.addToRoomPack(
                roomId: roomId, roomName: model.name,
                name: processedName, imageData: stagedImage, mimeType: stagedMimeType,
                width: size?.width, height: size?.height, usage: usage)
            isWorking = false
            if let error {
                errorMessage = error
            } else {
                newName = ""
                self.stagedImage = nil
                stagedMimeType = "image/png"
                stagedPreview = nil
            }
        }
    }

    private func remove(_ emote: CustomEmojiStore.Emote) {
        isWorking = true
        errorMessage = nil
        Task {
            let error = await store.removeFromRoomPack(roomId: roomId, roomName: model.name,
                                                       shortcode: emote.shortcode)
            isWorking = false
            if let error { errorMessage = error }
        }
    }

    /// Downscales to ≤256 px (aspect preserved) and re-encodes as PNG to keep transparency.
    private static func processedEmoteImage(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (png as Data, scaled.width, scaled.height)
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (width, height)
    }
}
