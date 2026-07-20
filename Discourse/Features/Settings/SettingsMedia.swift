import SwiftUI

/// Notification privacy + sound preferences: how much a lock-screen banner
/// reveals, and whether it chimes.
struct NotificationSettingsView: View {
    @Environment(Preferences.self) private var prefs

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
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
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
