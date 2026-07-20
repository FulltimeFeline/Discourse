import SwiftUI
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Every user-facing customization option, persisted in `UserDefaults` and
/// observed app-wide. Each property loads from defaults at launch and writes
/// back on change.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Appearance
        appearance = defaults.enumValue(AppearanceMode.self, "pref.appearance") ?? .system
        accentColor = defaults.enumValue(AccentChoice.self, "pref.accentColor") ?? .system
        messageDensity = defaults.enumValue(MessageDensity.self, "pref.messageDensity") ?? .comfortable
        use24HourTime = defaults.boolValue("pref.use24HourTime", default: false)
        coloredSenderNames = defaults.boolValue("pref.coloredSenderNames", default: true)
        showAvatarsInTimeline = defaults.boolValue("pref.showAvatarsInTimeline", default: true)
        chatFontScale = defaults.doubleValue("pref.chatFontScale", default: 1.0)
        // Chat behavior
        jumboEmoji = defaults.boolValue("pref.jumboEmoji", default: true)
        animatedEmotes = defaults.boolValue("pref.animatedEmotes", default: true)
        showReadReceipts = defaults.boolValue("pref.showReadReceipts", default: true)
        showTypingIndicators = defaults.boolValue("pref.showTypingIndicators", default: true)
        groupingWindowMinutes = defaults.intValue("pref.groupingWindowMinutes", default: 5)
        sendOnEnter = defaults.boolValue("pref.sendOnEnter", default: true)
        confirmBeforeDeleting = defaults.boolValue("pref.confirmBeforeDeleting", default: false)
        sendMessageHaptic = defaults.boolValue("pref.sendMessageHaptic", default: true)
        // Privacy
        sendReadReceipts = defaults.boolValue("pref.sendReadReceipts", default: true)
        sendTypingNotifications = defaults.boolValue("pref.sendTypingNotifications", default: true)
        sharePresence = defaults.boolValue("pref.sharePresence", default: true)
        stripLocationMetadata = defaults.boolValue("pref.stripLocationMetadata", default: true)
        // Media & storage
        autoDownloadImages = defaults.boolValue("pref.autoDownloadImages", default: true)
        // Notifications
        notificationPreview = defaults.enumValue(NotificationPreview.self, "pref.notificationPreview") ?? .full
        notificationSound = defaults.boolValue("pref.notificationSound", default: true)
        // Accessibility
        alwaysShowTimestamps = defaults.boolValue("pref.alwaysShowTimestamps", default: false)
        reduceTimelineMotion = defaults.boolValue("pref.reduceTimelineMotion", default: false)
        largerTapTargets = defaults.boolValue("pref.largerTapTargets", default: false)
        // Advanced
        showEventIds = defaults.boolValue("pref.showEventIds", default: false)
        observeSystemAccessibility()
    }

    // MARK: System accessibility (mirrored so views react to changes)

    /// Combined with the in-app toggle in `reduceMotion`.
    private(set) var systemReduceMotion = false
    private(set) var systemReduceTransparency = false

    private func observeSystemAccessibility() {
        #if os(iOS)
        systemReduceMotion = UIAccessibility.isReduceMotionEnabled
        systemReduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        let center = NotificationCenter.default
        center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemReduceMotion = UIAccessibility.isReduceMotionEnabled }
        }
        center.addObserver(forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemReduceTransparency = UIAccessibility.isReduceTransparencyEnabled }
        }
        #elseif os(macOS)
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
        #endif
    }

    // MARK: Appearance
    var appearance: AppearanceMode { didSet { defaults.setEnum(appearance, "pref.appearance") } }
    var accentColor: AccentChoice { didSet { defaults.setEnum(accentColor, "pref.accentColor") } }
    var messageDensity: MessageDensity { didSet { defaults.setEnum(messageDensity, "pref.messageDensity") } }
    var use24HourTime: Bool { didSet { defaults.set(use24HourTime, forKey: "pref.use24HourTime") } }
    var coloredSenderNames: Bool { didSet { defaults.set(coloredSenderNames, forKey: "pref.coloredSenderNames") } }
    var showAvatarsInTimeline: Bool { didSet { defaults.set(showAvatarsInTimeline, forKey: "pref.showAvatarsInTimeline") } }
    /// Timeline text scale (0.8…1.4), on top of Dynamic Type.
    var chatFontScale: Double { didSet { defaults.set(chatFontScale, forKey: "pref.chatFontScale") } }

    // MARK: Chat behavior
    var jumboEmoji: Bool { didSet { defaults.set(jumboEmoji, forKey: "pref.jumboEmoji") } }
    var animatedEmotes: Bool { didSet { defaults.set(animatedEmotes, forKey: "pref.animatedEmotes") } }
    var showReadReceipts: Bool { didSet { defaults.set(showReadReceipts, forKey: "pref.showReadReceipts") } }
    var showTypingIndicators: Bool { didSet { defaults.set(showTypingIndicators, forKey: "pref.showTypingIndicators") } }
    /// Minutes within which same-sender messages group under one header.
    var groupingWindowMinutes: Int { didSet { defaults.set(groupingWindowMinutes, forKey: "pref.groupingWindowMinutes") } }
    /// macOS: plain Return sends (⇧Return newline).
    var sendOnEnter: Bool { didSet { defaults.set(sendOnEnter, forKey: "pref.sendOnEnter") } }
    var confirmBeforeDeleting: Bool { didSet { defaults.set(confirmBeforeDeleting, forKey: "pref.confirmBeforeDeleting") } }
    var sendMessageHaptic: Bool { didSet { defaults.set(sendMessageHaptic, forKey: "pref.sendMessageHaptic") } }

    // MARK: Privacy
    var sendReadReceipts: Bool { didSet { defaults.set(sendReadReceipts, forKey: "pref.sendReadReceipts") } }
    var sendTypingNotifications: Bool { didSet { defaults.set(sendTypingNotifications, forKey: "pref.sendTypingNotifications") } }
    var sharePresence: Bool { didSet { defaults.set(sharePresence, forKey: "pref.sharePresence") } }
    var stripLocationMetadata: Bool { didSet { defaults.set(stripLocationMetadata, forKey: "pref.stripLocationMetadata") } }

    // MARK: Media & storage
    var autoDownloadImages: Bool { didSet { defaults.set(autoDownloadImages, forKey: "pref.autoDownloadImages") } }

    // MARK: Notifications
    var notificationPreview: NotificationPreview { didSet { defaults.setEnum(notificationPreview, "pref.notificationPreview") } }
    var notificationSound: Bool { didSet { defaults.set(notificationSound, forKey: "pref.notificationSound") } }

    // MARK: Accessibility
    var alwaysShowTimestamps: Bool { didSet { defaults.set(alwaysShowTimestamps, forKey: "pref.alwaysShowTimestamps") } }
    var reduceTimelineMotion: Bool { didSet { defaults.set(reduceTimelineMotion, forKey: "pref.reduceTimelineMotion") } }
    var largerTapTargets: Bool { didSet { defaults.set(largerTapTargets, forKey: "pref.largerTapTargets") } }

    // MARK: Advanced
    var showEventIds: Bool { didSet { defaults.set(showEventIds, forKey: "pref.showEventIds") } }

    func resetToDefaults() {
        appearance = .system
        accentColor = .system
        messageDensity = .comfortable
        use24HourTime = false
        coloredSenderNames = true
        showAvatarsInTimeline = true
        chatFontScale = 1.0
        jumboEmoji = true
        animatedEmotes = true
        showReadReceipts = true
        showTypingIndicators = true
        groupingWindowMinutes = 5
        sendOnEnter = true
        confirmBeforeDeleting = false
        sendMessageHaptic = true
        sendReadReceipts = true
        sendTypingNotifications = true
        sharePresence = true
        stripLocationMetadata = true
        autoDownloadImages = true
        notificationPreview = .full
        notificationSound = true
        alwaysShowTimestamps = false
        reduceTimelineMotion = false
        largerTapTargets = false
        showEventIds = false
    }

    // MARK: Derived

    /// Color scheme to force, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Resolved accent tint, or nil for the asset-catalog accent.
    var resolvedTint: Color? { accentColor.color }

    var groupingWindow: TimeInterval { TimeInterval(groupingWindowMinutes * 60) }

    /// In-app toggle OR system "Reduce Motion". Prefer this at animation sites.
    var reduceMotion: Bool { reduceTimelineMotion || systemReduceMotion }

    var reduceTransparency: Bool { systemReduceTransparency }
}

// MARK: - Option enums

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, indigo, purple, pink, red, orange, yellow, green, teal, mint, brown, gray
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .system: "Default"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .mint: "Mint"
        case .brown: "Brown"
        case .gray: "Graphite"
        }
    }
    /// nil for `.system` (uses the asset-catalog AccentColor).
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .mint: .mint
        case .brown: .brown
        case .gray: .gray
        }
    }
    /// Concrete swatch for the picker (system shows the app accent).
    var swatch: Color { color ?? .accentColor }
}

enum MessageDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }
    /// Vertical padding above a new sender group.
    var groupTopPadding: CGFloat { self == .compact ? 8 : 14 }
    /// Vertical padding for a grouped (headerless) row.
    var rowVerticalPadding: CGFloat { self == .compact ? 1 : 2 }
}

enum NotificationPreview: String, CaseIterable, Identifiable {
    case full, senderOnly, none
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .full: "Sender and Message"
        case .senderOnly: "Sender Only"
        case .none: "Nothing"
        }
    }
}

// MARK: - UserDefaults helpers

private extension UserDefaults {
    func boolValue(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
    func intValue(_ key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }
    func doubleValue(_ key: String, default fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
    func enumValue<T: RawRepresentable>(_ type: T.Type, _ key: String) -> T? where T.RawValue == String {
        string(forKey: key).flatMap { T(rawValue: $0) }
    }
    func setEnum<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        set(value.rawValue, forKey: key)
    }
}

