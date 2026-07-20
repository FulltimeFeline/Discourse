import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Outgoing-media preprocessing: strip location metadata, generate the
/// thumbnails encrypted rooms need to paint a preview (no server thumbnailing
/// for E2EE), and extract a video poster frame. All work is nonisolated.
enum MediaProcessing {
    struct ProcessedImage {
        var data: Data
        var mimetype: String
        var width: UInt64
        var height: UInt64
    }

    struct Thumbnail {
        var data: Data
        var mimetype: String
        var width: UInt64
        var height: UInt64
    }

    struct VideoAttributes {
        var duration: TimeInterval?
        var width: UInt64?
        var height: UInt64?
        var thumbnail: Thumbnail?
    }

    /// Re-encodes an image with its GPS block removed, baking in orientation.
    /// Animated images (GIF/APNG) pass through untouched. Returns nil only if
    /// the bytes can't be read.
    nonisolated static func sanitizedImage(data: Data) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(source) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
        let mimetype = UTType(typeId as String)?.preferredMIMEType ?? "application/octet-stream"

        // Multi-frame: leave the bytes alone (re-encoding index 0 would flatten
        // the animation).
        if CGImageSourceGetCount(source) > 1 {
            guard let width, let height else { return nil }
            return ProcessedImage(data: data, mimetype: mimetype, width: width, height: height)
        }

        // Rewrite, nulling GPS; keeps everything else (incl. orientation).
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, typeId, 1, nil) else {
            guard let width, let height else { return nil }
            return ProcessedImage(data: data, mimetype: mimetype, width: width, height: height)
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImagePropertyGPSDictionary: kCFNull as Any,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0,
              let width, let height else {
            guard let width, let height else { return nil }
            return ProcessedImage(data: data, mimetype: mimetype, width: width, height: height)
        }
        return ProcessedImage(data: output as Data, mimetype: mimetype,
                              width: width, height: height)
    }

    /// Downsampled thumbnail (≤`maxPixelSize` px) for the message's
    /// ImageInfo/VideoInfo. JPEG unless the source has alpha (then PNG).
    nonisolated static func thumbnail(from data: Data, maxPixelSize: Int = 800) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return encode(cg)
    }

    /// Duration, dimensions, and poster-frame thumbnail for a video staged as
    /// bytes. Writes to a temp file (AVAsset needs a URL) and cleans up.
    nonisolated static func videoAttributes(data: Data, filename: String) async -> VideoAttributes {
        let ext = (filename as NSString).pathExtension.isEmpty
            ? "mov" : (filename as NSString).pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "discourse-upload-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: tempURL)) != nil else { return VideoAttributes() }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let asset = AVURLAsset(url: tempURL)
        var attrs = VideoAttributes()
        if let duration = try? await asset.load(.duration) {
            attrs.duration = CMTimeGetSeconds(duration)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let oriented = size.applying(transform)
            attrs.width = UInt64(abs(oriented.width))
            attrs.height = UInt64(abs(oriented.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        // Seek in a little; frame 0 is often all black.
        let seekTime = CMTime(seconds: min(1, (attrs.duration ?? 2) / 2), preferredTimescale: 600)
        if let cg = try? await generator.image(at: seekTime).image {
            attrs.thumbnail = encode(cg)
        }
        return attrs
    }

    private nonisolated static func encode(_ cg: CGImage) -> Thumbnail? {
        let hasAlpha = switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type = (hasAlpha ? UTType.png : UTType.jpeg)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = hasAlpha
            ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return Thumbnail(data: output as Data,
                         mimetype: type.preferredMIMEType ?? (hasAlpha ? "image/png" : "image/jpeg"),
                         width: UInt64(cg.width), height: UInt64(cg.height))
    }
}
