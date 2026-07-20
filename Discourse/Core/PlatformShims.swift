import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
import UserNotifications
typealias PlatformImage = UIImage
#endif

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

extension View {
    /// `.radioGroup` on macOS, `.inline` elsewhere.
    @ViewBuilder
    func radioPickerStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }

    /// Glass in the given shape, or an opaque bordered fill under "Reduce
    /// Transparency".
    @ViewBuilder
    func adaptiveGlass(in shape: some Shape = Capsule(), reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            background(Color.platformWindowBackground, in: shape)
                .overlay(shape.stroke(.quaternary, lineWidth: 0.5))
        } else {
            glassEffect(in: shape)
        }
    }
}

extension Color {
    /// `#rrggbb` / `#rgb` (with or without `#`). nil-initializer for optional use.
    init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Column divider. macOS forces a dark hairline (a light one vanishes
    /// against the chat chrome); iOS uses the system separator.
    static var columnDivider: Color {
        #if os(macOS)
        Color.black.opacity(0.55)
        #else
        Color(uiColor: .separator)
        #endif
    }
}

extension Animation {
    /// Shared settle curve for every pager transition, so adjoining moves run
    /// on the same clock.
    static let pagerSettle = Animation.spring(response: 0.32, dampingFraction: 0.88)
}

extension PlatformImage {
    var cgImageValue: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// One-liners over the AppKit/UIKit split.
@MainActor
enum Platform {
    static var isAppActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Brings the app to the foreground (no-op on iOS).
    static func activateApp() {
        #if os(macOS)
        NSApp.activate()
        #endif
    }

    static func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func openURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// App badge: dock tile on macOS, springboard badge on iOS.
    static func setBadge(count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }
}
