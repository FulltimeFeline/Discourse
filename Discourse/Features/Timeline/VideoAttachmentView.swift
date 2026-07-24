import QuickLook
import SwiftUI

/// Inline video: a poster frame with a play control and duration badge. Tapping
/// downloads (and decrypts) the file, then plays it in the system viewer, which
/// gives scrubbing and fullscreen for free. Mirrors `InlineImageView`.
struct VideoAttachmentView: View {
    let video: VideoItem
    let loader: MediaLoader
    @Environment(\.displayScale) private var displayScale
    @State private var poster: PlatformImage?
    @State private var blurhash: CGImage?
    /// Drives the in-app Quick Look player.
    @State private var previewURL: URL?
    @State private var isDownloading = false
    @State private var downloadFailed = false

    private var thumbnailScale: CGFloat { min(max(displayScale, 1), 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            posterBody
                .frame(width: video.displaySize.width, height: video.displaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { playOverlay }
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .onTapGesture { open() }
                .quickLookPreview($previewURL)
                .help("Play video")
                #if os(macOS)
                .pointerStyle(.link)
                #endif
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton)
                .task(id: video.source.url) {
                    guard let thumb = video.thumbnailSource, poster == nil else { return }
                    poster = await loader.thumbnail(
                        for: thumb,
                        pixelSize: max(video.displaySize.width, video.displaySize.height) * thumbnailScale)
                }
                .task(id: video.blurhash ?? "") {
                    guard blurhash == nil, poster == nil,
                          let hash = video.blurhash, !hash.isEmpty else { return }
                    let size = video.displaySize
                    let h = max(1, Int((24 * size.height / max(size.width, 1)).rounded()))
                    blurhash = Blurhash.decode(hash, width: 24, height: h)
                }
            if let caption = video.caption, !caption.isEmpty {
                Text(caption).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var posterBody: some View {
        if let poster {
            Image(platformImage: poster)
                .resizable()
                .aspectRatio(contentMode: video.hasKnownSize ? .fill : .fit)
        } else if let blurhash {
            Image(decorative: blurhash, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // No poster frame supplied: a neutral film placeholder.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playOverlay: some View {
        ZStack {
            if isDownloading {
                Circle().fill(.black.opacity(0.45)).frame(width: 52, height: 52)
                ProgressView().tint(.white)
            } else {
                Image(systemName: downloadFailed ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .shadow(radius: 3)
            }
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let text = video.durationText {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }

    private var accessibilityText: Text {
        let base = String(localized: "Video")
        return video.filename.isEmpty ? Text(base) : Text(verbatim: "\(base), \(video.filename)")
    }

    private func open() {
        guard !isDownloading else { return }
        if let previewURL {
            // Already downloaded this session: reopen without re-fetching.
            self.previewURL = nil
            DispatchQueue.main.async { self.previewURL = previewURL }
            return
        }
        isDownloading = true
        downloadFailed = false
        Task {
            defer { isDownloading = false }
            guard let url = await Self.temporaryFile(for: video, loader: loader) else {
                downloadFailed = true
                return
            }
            previewURL = url
        }
    }

    /// Downloads the full video into a stable temp file (named by source, so
    /// repeat opens reuse it), with an extension Quick Look understands.
    @MainActor
    static func temporaryFile(for video: VideoItem, loader: MediaLoader) async -> URL? {
        guard let data = await loader.fullContent(for: video.source) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "discourse-\(video.source.url.hashValue.magnitude).\(fileExtension(for: video))")
        let wrote = await Task.detached(priority: .userInitiated) {
            (try? data.write(to: url)) != nil
        }.value
        return wrote ? url : nil
    }

    private static func fileExtension(for video: VideoItem) -> String {
        let fromName = (video.filename as NSString).pathExtension
        if !fromName.isEmpty { return fromName }
        switch video.mimeType {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }
}
