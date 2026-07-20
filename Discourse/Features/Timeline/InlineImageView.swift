import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Inline image: fixed footprint from the event's ImageInfo, filled by the
/// SDK thumbnail when it arrives. Click opens the full image in the system
/// viewer.
struct InlineImageView: View {
    let image: ImageItem
    let loader: MediaLoader
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: PlatformImage?
    /// Drives the in-app Quick Look viewer.
    @State private var previewURL: URL?
    /// The thumbnail fetch came back empty; show a broken-image state.
    @State private var loadFailed = false
    /// Bumped by tap-to-retry to re-fire the load task.
    @State private var loadAttempt = 0
    /// Set when the user taps a data-saver placeholder; consulted only when
    /// auto-download is off (stickers ignore the gate).
    @State private var manuallyRequested = false
    /// Decoded blurhash, shown behind the spinner so images fade in from their
    /// colors instead of a grey box.
    @State private var blurhash: CGImage?

    /// Data-saver gate: with auto-download off, non-sticker images wait behind
    /// a "Tap to load" placeholder. Stickers always load; an already-available
    /// image never gates.
    private var shouldDefer: Bool {
        guard !Preferences.shared.autoDownloadImages else { return false }
        return !image.isSticker && !manuallyRequested && displayImage == nil
    }

    /// Clamped so fractional macOS backing scales don't fragment cache keys.
    private var thumbnailScale: CGFloat {
        min(max(displayScale, 1), 3)
    }

    private var displayImage: PlatformImage? {
        loaded ?? loader.cachedThumbnail(
            for: image.source,
            pixelSize: max(image.displaySize.width, image.displaySize.height) * thumbnailScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            imageBody
                .frame(width: image.displaySize.width, height: image.displaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // The tap doubles as retry in the failed state.
                .onTapGesture {
                    if shouldDefer {
                        // Data-saver: first tap requests the deferred download.
                        manuallyRequested = true
                        loadAttempt += 1
                    } else if loadFailed {
                        loadFailed = false
                        loadAttempt += 1
                    } else {
                        openFull()
                    }
                }
                .quickLookPreview($previewURL)
                #if os(macOS)
                // Drag out to Finder / another app; the full resolution
                // downloads to a temp file at drop time.
                .draggable(TimelineImageTransfer(image: image, loader: loader))
                #endif
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton)
                .task(id: "\(loadAttempt)|\(image.source.url)") {
                    // Data-saver: don't touch the network until the user taps.
                    guard !shouldDefer else { return }
                    loaded = await loader.thumbnail(
                        for: image.source,
                        pixelSize: max(image.displaySize.width, image.displaySize.height) * thumbnailScale
                    )
                    // Not on cancellation (scroll recycling); only a fetch
                    // that came back empty.
                    if !Task.isCancelled && displayImage == nil {
                        loadFailed = true
                    }
                }
                // Decode the blurhash once (tiny; the view scales it up). Skip
                // if the real image is already available.
                .task(id: image.blurhash ?? "") {
                    guard blurhash == nil, displayImage == nil,
                          let hash = image.blurhash, !hash.isEmpty else { return }
                    let size = image.displaySize
                    let w = 24
                    let h = max(1, Int((24 * size.height / max(size.width, 1)).rounded()))
                    blurhash = Blurhash.decode(hash, width: w, height: h)
                }
            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let displayImage {
            Image(platformImage: displayImage)
                .resizable()
                // The frame matches the declared aspect ratio when there is
                // one, so .fit only differs when dimensions are missing/wrong,
                // where .fill would crop. Stickers must never be cropped.
                .aspectRatio(contentMode:
                    image.isSticker || !image.hasKnownSize ? .fit : .fill)
        } else if shouldDefer {
            // Data-saver placeholder: failed-state styling, but invites a load.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Tap to load image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if loadFailed {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Tap to retry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ZStack {
                if let blurhash {
                    Image(decorative: blurhash, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                }
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// "Image, cat.png" rather than a silent tap target. The caption reads as
    /// its own element below, so it isn't duplicated here.
    private var accessibilityText: Text {
        if shouldDefer {
            return Text("Image not loaded. Tap to load.")
        }
        if loadFailed {
            return Text("Image failed to load. Tap to retry.")
        }
        let base = image.isSticker ? String(localized: "Sticker") : String(localized: "Image")
        return image.filename.isEmpty ? Text(base) : Text(verbatim: "\(base), \(image.filename)")
    }

    private func openFull() {
        Task {
            guard let url = await Self.temporaryFile(for: image, loader: loader) else { return }
            previewURL = url
        }
    }

    /// Downloads the full-resolution content into a stable temp file, named so
    /// repeat opens of the same event reuse it.
    @MainActor
    static func temporaryFile(for image: ImageItem, loader: MediaLoader) async -> URL? {
        guard let data = await loader.fullContent(for: image.source) else { return nil }
        let ext = (image.filename as NSString).pathExtension.isEmpty ? "png" : (image.filename as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appending(path: "discourse-\(image.source.url.hashValue.magnitude).\(ext)")
        // Loader work stays on the main actor; the multi-MB write hops off.
        let wrote = await Task.detached(priority: .userInitiated) {
            do {
                try data.write(to: url)
                return true
            } catch {
                return false
            }
        }.value
        return wrote ? url : nil
    }
}

/// Exports a timeline image's full-resolution content as a file (via the
/// shared temp-file helper) so inline images can be dragged out or shared.
/// @unchecked: MediaLoader is main-actor-bound and ImageItem's FFI source is
/// preconcurrency; the export hops to the main actor before touching either.
struct TimelineImageTransfer: Transferable, @unchecked Sendable {
    let image: ImageItem
    let loader: MediaLoader

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { transfer in
            guard let url = await InlineImageView.temporaryFile(
                for: transfer.image, loader: transfer.loader) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }
}
