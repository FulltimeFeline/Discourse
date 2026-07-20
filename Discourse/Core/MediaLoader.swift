#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import MatrixRustSDK

/// Fetches media through the SDK (E2EE decryption + caching on the Rust side)
/// and memory-caches decoded images. Thumbnails also persist to a capped
/// per-account disk cache so relaunches paint without the network.
@MainActor
final class MediaLoader {
    private let client: Client
    private let cache = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: Task<(image: PlatformImage?, didPersist: Bool), Never>] = [:]
    private var inFlightContent: [String: Task<Data?, Never>] = [:]
    /// Pixel sizes per URL — NSCache can't be enumerated, so this is how
    /// `cachedThumbnail` finds a same-URL entry at another size. A stale size
    /// just misses the cache.
    private var cachedSizes: [String: [Int]] = [:]
    /// Memoized "does the source JSON carry an AES key" check; `toJson()` is
    /// too costly to repeat per cache miss.
    private var encryptedByUrl: [String: Bool] = [:]
    /// Disk writes since the last trim. `prepareDiskCache` runs only at init,
    /// so re-trim every N persists to bound a long-lived session.
    private var diskWritesSinceTrim = 0
    private static let diskTrimInterval = 200
    /// Per-account on-disk downsampled thumbnails, so cold launches paint
    /// avatars without a round-trip. nil if Caches is missing.
    private let diskCacheDirectory: URL?
    #if os(iOS)
    /// Read from the nonisolated deinit; written only at the end of init.
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?
    #endif

    init(client: Client) {
        self.client = client
        #if os(iOS)
        // Scale to the device; phones can't spare 256MB for thumbnails.
        cache.totalCostLimit = min(256 * 1024 * 1024,
                                   Int(ProcessInfo.processInfo.physicalMemory / 8))
        #else
        cache.totalCostLimit = 256 * 1024 * 1024
        #endif
        // Namespace per account so logout can wipe exactly its thumbnails.
        let userId = (try? client.userId()) ?? "global"
        diskCacheDirectory = Self.thumbnailCacheDirectory(forUserId: userId)
        if let directory = diskCacheDirectory {
            Task.detached(priority: .utility) {
                Self.prepareDiskCache(at: directory)
            }
        }
        #if os(iOS)
        // Last: the closure captures self, legal only once every property is set.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.purgeInMemoryCaches() }
            }
        #endif
    }

    #if os(iOS)
    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Memory-warning response: drop the decoded bitmaps and bookkeeping maps.
    /// Disk copies survive, so repopulating is cheap.
    private func purgeInMemoryCaches() {
        cache.removeAllObjects()
        cachedSizes.removeAll()
        encryptedByUrl.removeAll()
    }
    #endif

    /// Keyed on url + rounded pixel size so different sizes of one image don't
    /// collide in the cache or in-flight table.
    private func cacheKey(url: String, side: Int) -> NSString {
        "\(url)#\(side)" as NSString
    }

    private func roundedSide(_ pixelSize: CGFloat) -> Int {
        max(1, Int(pixelSize.rounded()))
    }

    private func isEncrypted(_ box: MediaSourceBox) -> Bool {
        if let known = encryptedByUrl[box.url] { return known }
        let encrypted = box.source.toJson().contains("\"key\"")
        encryptedByUrl[box.url] = encrypted
        return encrypted
    }

    /// Decodes + downsamples off-main. ImageIO thumbnailing never materializes
    /// the full-size bitmap, and `ShouldCacheImmediately` decodes here rather
    /// than at first draw. When `fileURL` is set, also writes the bitmap back
    /// to the disk cache while it's still off-main.
    nonisolated private static func decodeThumbnail(_ data: Data, maxPixelSize: CGFloat,
                                                    persistingTo fileURL: URL? = nil) async -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
            kCGImageSourceShouldCacheImmediately: true,
            // Bake in EXIF orientation.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        if let fileURL, let encoded = encodeForDisk(cg) {
            // Fire-and-forget; don't make the caller wait on file IO.
            Task.detached(priority: .utility) {
                writeDiskThumbnail(encoded, to: fileURL)
            }
        }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    // MARK: Disk thumbnail cache

    /// Caches/thumbnails/<account>/ of already-downsampled bitmaps.
    nonisolated static func thumbnailCacheDirectory(forUserId userId: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appending(path: "thumbnails/\(filesystemSafe(userId))",
                                directoryHint: .isDirectory)
    }

    /// Deletes an account's disk thumbnails wholesale (logout hygiene).
    nonisolated static func removeDiskCache(forUserId userId: String) {
        guard let directory = thumbnailCacheDirectory(forUserId: userId) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Map filesystem-unfriendly characters (`@`, `:`, …) to `_` so a user ID
    /// can name a directory.
    nonisolated private static func filesystemSafe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    /// SHA-256 of the memory-cache key, so disk and memory key identically.
    nonisolated private static func diskFileURL(in directory: URL, url: String, side: Int) -> URL {
        let digest = SHA256.hash(data: Data("\(url)#\(side)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Reads + decodes a stored thumbnail off-main. Touches the modification
    /// date (for LRU trimming) only when >12h stale — a write per read is pure
    /// IO overhead and LRU doesn't need sub-day resolution.
    nonisolated private static func readDiskThumbnail(at fileURL: URL, maxPixelSize: CGFloat,
                                                      persistingTo persistURL: URL? = nil) async -> PlatformImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate,
           Date().timeIntervalSince(modified) > 12 * 3600 {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: fileURL.path(percentEncoded: false))
        }
        return await decodeThumbnail(data, maxPixelSize: maxPixelSize, persistingTo: persistURL)
    }

    /// JPEG at 0.8; PNG when the bitmap has alpha, which JPEG would flatten.
    nonisolated private static func encodeForDisk(_ cg: CGImage) -> Data? {
        let hasAlpha = switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil)
        else { return nil }
        let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated private static func writeDiskThumbnail(_ data: Data, to fileURL: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        #if os(macOS)
        try? data.write(to: fileURL, options: [.atomic])
        #else
        // Encrypted-room avatars land here; protect until first unlock.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    /// One-time init, off-main: create the directory, exclude it from backups,
    /// and trim to ~100 MB by deleting least-recently-read files.
    nonisolated private static func prepareDiskCache(at directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let capBytes = 100 * 1024 * 1024
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard let resources = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, resources.contentModificationDate ?? .distantPast,
                    resources.totalFileAllocatedSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > capBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > capBytes else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Storage settings

    /// Total bytes of this account's thumbnail cache, summed off-main.
    func totalDiskCacheSize() async -> Int {
        guard let directory = diskCacheDirectory else { return 0 }
        return await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys) else { return 0 }
            return files.reduce(0) { sum, url in
                sum + ((try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
            }
        }.value
    }

    /// Wipes both cache tiers (memory + on-disk), then re-prepares the
    /// directory so subsequent writes still land.
    func clearCache() {
        cache.removeAllObjects()
        cachedSizes.removeAll()
        encryptedByUrl.removeAll()
        diskWritesSinceTrim = 0
        guard let directory = diskCacheDirectory else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) {
                for url in files { try? fm.removeItem(at: url) }
            }
            Self.prepareDiskCache(at: directory)
        }
    }

    /// Server-side thumbnail for inline display, falling back to full content
    /// (no server thumbnailing for encrypted media).
    func thumbnail(for box: MediaSourceBox, pixelSize: CGFloat) async -> PlatformImage? {
        let side = roundedSide(pixelSize)
        let key = cacheKey(url: box.url, side: side)
        if let hit = cache.object(forKey: key) { return hit }
        // Concurrent callers share the fetch; a dedup hit just takes the image
        // (only the originator's didPersist drives the trim counter).
        if let running = inFlight[key as String] { return await running.value.image }

        let client = self.client
        let encrypted = isEncrypted(box)
        let fileURL = diskCacheDirectory.map { Self.diskFileURL(in: $0, url: box.url, side: side) }
        // A larger cached size can be decoded down from disk instead of
        // hitting the network. Smallest-first: cheapest decode that's >= side.
        let largerFileURLs: [URL] = diskCacheDirectory.map { directory in
            (cachedSizes[box.url] ?? []).filter { $0 > side }.sorted()
                .map { Self.diskFileURL(in: directory, url: box.url, side: $0) }
        } ?? []
        // `didPersist` marks paths that wrote a new disk file, so the trim
        // counter only counts real growth.
        let task = Task<(image: PlatformImage?, didPersist: Bool), Never> {
            // Disk before network.
            if let fileURL, let stored = await Self.readDiskThumbnail(at: fileURL, maxPixelSize: pixelSize) {
                return (stored, false)
            }
            for larger in largerFileURLs {
                if let derived = await Self.readDiskThumbnail(at: larger, maxPixelSize: pixelSize,
                                                              persistingTo: fileURL) {
                    return (derived, fileURL != nil)
                }
            }
            let data: Data?
            // Encrypted sources can't be server-thumbnailed (asking hangs);
            // download + decrypt directly. The url-keyed in-flight table lets
            // concurrent sizes share one full-content download.
            if encrypted {
                data = await self.fullContent(for: box)
            } else if let thumb = try? await client.getMediaThumbnail(mediaSource: box.source, width: UInt64(side), height: UInt64(side)) {
                data = thumb
            } else {
                data = await self.fullContent(for: box)
            }
            guard let data else { return (nil, false) }
            let decoded = await Self.decodeThumbnail(data, maxPixelSize: pixelSize, persistingTo: fileURL)
            return (decoded, decoded != nil && fileURL != nil)
        }
        inFlight[key as String] = task
        let (image, didPersist) = await task.value
        inFlight[key as String] = nil
        if let image {
            // Cost is the bitmap's byte size, from pixel (not point) dimensions.
            let cost = image.cgImageValue.map { $0.width * $0.height * 4 }
                ?? Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
            if !cachedSizes[box.url, default: []].contains(side) {
                cachedSizes[box.url, default: []].append(side)
            }
        }
        if didPersist, let directory = diskCacheDirectory {
            diskWritesSinceTrim += 1
            if diskWritesSinceTrim >= Self.diskTrimInterval {
                diskWritesSinceTrim = 0
                Task.detached(priority: .utility) { Self.prepareDiskCache(at: directory) }
            }
        }
        return image
    }

    /// Bulk-loads disk thumbnails into memory before the sidebar's first paint,
    /// so `cachedThumbnail` hits on frame one instead of avatars popping in.
    func prewarmThumbnails(mxcUrls: [String], pixelSize: CGFloat) async {
        guard let directory = diskCacheDirectory else { return }
        let side = roundedSide(pixelSize)
        let missing = mxcUrls.filter {
            cache.object(forKey: cacheKey(url: $0, side: side)) == nil
        }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (String, PlatformImage?).self) { group in
            for url in missing {
                let fileURL = Self.diskFileURL(in: directory, url: url, side: side)
                group.addTask {
                    (url, await Self.readDiskThumbnail(at: fileURL, maxPixelSize: pixelSize))
                }
            }
            for await (url, image) in group {
                guard let image else { continue }
                let cost = image.cgImageValue.map { $0.width * $0.height * 4 }
                    ?? Int(image.size.width * image.size.height * 4)
                cache.setObject(image, forKey: cacheKey(url: url, side: side), cost: cost)
                if !cachedSizes[url, default: []].contains(side) {
                    cachedSizes[url, default: []].append(side)
                }
            }
        }
    }

    /// Synchronous in-memory hit for seeding views before the async fetch
    /// lands; falls back to a same-URL entry at another size. Kicks off no work.
    @MainActor
    func cachedThumbnail(for source: MediaSourceBox, pixelSize: CGFloat) -> PlatformImage? {
        let side = roundedSide(pixelSize)
        if let exact = cache.object(forKey: cacheKey(url: source.url, side: side)) { return exact }
        for other in cachedSizes[source.url] ?? [] where other != side {
            if let hit = cache.object(forKey: cacheKey(url: source.url, side: other)) { return hit }
        }
        return nil
    }

    /// Full-resolution content (e.g. opening an image externally), deduplicated
    /// per URL in flight. Also the download step for encrypted thumbnails.
    func fullContent(for box: MediaSourceBox) async -> Data? {
        if let running = inFlightContent[box.url] { return await running.value }
        let client = self.client
        let task = Task<Data?, Never> {
            try? await client.getMediaContent(mediaSource: box.source)
        }
        inFlightContent[box.url] = task
        let data = await task.value
        inFlightContent[box.url] = nil
        return data
    }

    /// URL-keyed sibling of `cachedThumbnail` (any cached size). Kicks off no
    /// work.
    func cachedImage(mxcUrl: String, pixelSize: CGFloat) -> PlatformImage? {
        let side = roundedSide(pixelSize)
        if let exact = cache.object(forKey: cacheKey(url: mxcUrl, side: side)) { return exact }
        for other in cachedSizes[mxcUrl] ?? [] where other != side {
            if let hit = cache.object(forKey: cacheKey(url: mxcUrl, side: other)) { return hit }
        }
        return nil
    }

    /// Avatar by `mxc://` URL (room avatars, sender profiles, members).
    func avatar(mxcUrl: String, pixelSize: CGFloat) async -> PlatformImage? {
        if let hit = cache.object(forKey: cacheKey(url: mxcUrl, side: roundedSide(pixelSize))) { return hit }
        guard let source = try? MediaSource.fromUrl(url: mxcUrl) else { return nil }
        return await thumbnail(for: MediaSourceBox(source), pixelSize: pixelSize)
    }
}

// MARK: - Environment plumbing

private struct MediaLoaderKey: EnvironmentKey {
    static let defaultValue: MediaLoader? = nil
}

extension EnvironmentValues {
    var mediaLoader: MediaLoader? {
        get { self[MediaLoaderKey.self] }
        set { self[MediaLoaderKey.self] = newValue }
    }
}
