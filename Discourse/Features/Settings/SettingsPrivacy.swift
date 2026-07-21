import SwiftUI

/// Privacy controls: each toggle gates a real outbound signal (receipts, typing,
/// presence, media metadata) sent to the homeserver.
struct PrivacySettingsView: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Toggle("Send read receipts", isOn: $prefs.sendReadReceipts)
            } header: {
                Text("Read Receipts")
            } footer: {
                Text("When off, others won't see when you've read their messages. Your own unread markers still clear as you read.")
            }

            Section {
                Toggle("Send typing notifications", isOn: $prefs.sendTypingNotifications)
            } header: {
                Text("Typing")
            } footer: {
                Text("When off, people won't see a \u{201C}typing\u{2026}\u{201D} indicator while you compose.")
            }

            Section {
                Toggle("Share presence", isOn: $prefs.sharePresence)
            } header: {
                Text("Presence")
            } footer: {
                Text("Shares your online status with people you're in rooms with. You can still see theirs.")
            }

            Section {
                Toggle("Warn in unencrypted rooms", isOn: $prefs.warnUnencrypted)
            } header: {
                Text("Encryption")
            } footer: {
                Text("Shows a notice above the composer when a room isn't end-to-end encrypted.")
            }

            Section {
                Toggle("Remove location from photos", isOn: $prefs.stripLocationMetadata)
            } header: {
                Text("Media")
            } footer: {
                Text("Strips GPS location metadata from photos before sending. Leave on unless you specifically want to share where a photo was taken.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Accessibility and confirmation preferences, layered on top of the system
/// accessibility settings (only ever adding caution, never relaxing the OS).
struct AccessibilitySettingsView: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Toggle("Reduce motion", isOn: $prefs.reduceTimelineMotion)
                Toggle("Larger tap targets", isOn: $prefs.largerTapTargets)
            } header: {
                Text("Accessibility")
            } footer: {
                Text("These apply on top of your system accessibility settings.")
            }

            Section("Behavior") {
                Toggle("Confirm before deleting messages", isOn: $prefs.confirmBeforeDeleting)
                #if os(macOS)
                Toggle("Return key sends message", isOn: $prefs.sendOnEnter)
                #endif
            }
        }
        .formStyle(.grouped)
    }
}
