import SwiftUI

/// Notification privacy + sound preferences: how much a lock-screen banner
/// reveals, and whether it chimes.
struct NotificationSettingsView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Show in Notifications", selection: $prefs.notificationPreview) {
                    ForEach(NotificationPreview.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
            } footer: {
                Text("""
                    Sender and Message shows who wrote and a preview of the text. \
                    Sender Only shows who and where, but hides the message. \
                    Nothing reveals only that a notification arrived.
                    """)
            }

            Section {
                Toggle("Play sound", isOn: $prefs.notificationSound)
            }

            // Per-account notification toggles, so each signed-in account can be
            // silenced independently. Each row also shows that account's unread.
            if appState.accountTokens.count > 1 {
                Section {
                    ForEach(appState.accountTokens, id: \.session.userId) { token in
                        let userId = token.session.userId
                        Toggle(isOn: Binding(
                            get: { prefs.notificationsEnabled(forUserId: userId) },
                            set: { appState.setNotificationsEnabled($0, forUserId: userId) }
                        )) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(appState.accountDisplayName(forUserId: userId))
                                        .lineLimit(1)
                                    Text(userId)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if appState.unreadCount(forUserId: userId) > 0,
                                   userId != appState.activeUserId {
                                    UnreadBadge(count: appState.unreadCount(forUserId: userId))
                                }
                            }
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Turn notifications on or off for each account.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }
}

/// A small pill showing an unread count (capped at 99+), for account rows and
/// tab/switcher badges.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red, in: Capsule())
    }
}

/// Media downloading + on-disk cache management.
struct StorageSettingsView: View {
    let loader: MediaLoader
    @Environment(Preferences.self) private var prefs

    /// nil while the first measurement is in flight.
    @State private var cacheSize: Int?
    @State private var isMeasuring = false
    @State private var isClearing = false

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Toggle("Auto-download images", isOn: $prefs.autoDownloadImages)
            } footer: {
                Text("When off, images wait behind a tap before downloading. Stickers always load.")
            }

            Section("Cache") {
                LabeledContent("Image Cache") {
                    if isMeasuring, cacheSize == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text((cacheSize ?? 0).formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Clear Cache", role: .destructive) {
                    clearCache()
                }
                .disabled(isClearing || (cacheSize ?? 0) == 0)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .task { await measure() }
    }

    private func measure() async {
        isMeasuring = true
        cacheSize = await loader.totalDiskCacheSize()
        isMeasuring = false
    }

    private func clearCache() {
        isClearing = true
        loader.clearCache()
        // Deletion is fire-and-forget off-main; re-measure shortly after.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await measure()
            isClearing = false
        }
    }
}
