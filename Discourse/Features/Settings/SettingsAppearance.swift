import SwiftUI

/// Theme, accent, density, chat text size, and timeline-display toggles.
struct AppearanceSettingsView: View {
    @Environment(Preferences.self) private var prefs

    private let swatchColumns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
            }

            Section {
                LazyVGrid(columns: swatchColumns, spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        AccentSwatch(choice: choice,
                                     isSelected: prefs.accentColor == choice) {
                            prefs.accentColor = choice
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Tinted Window", isOn: $prefs.tintedWindow)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Washes the window background with the accent color; off keeps the system gray.")
            }

            Section("Message Density") {
                Picker("Density", selection: $prefs.messageDensity) {
                    ForEach(MessageDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
            }

            Section {
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: 17 * prefs.chatFontScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(value: $prefs.chatFontScale, in: 0.8...1.4, step: 0.05) {
                        Text("Chat Text Size")
                    }
                    .accessibilityValue(Text(prefs.chatFontScale, format: .percent.precision(.fractionLength(0))))
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Chat Text Size")
            } footer: {
                Text("Scales message text on top of the system text size.")
            }

            Section {
                Toggle("Show avatars in timeline", isOn: $prefs.showAvatarsInTimeline)
                Toggle("Colored sender names", isOn: $prefs.coloredSenderNames)
            } footer: {
                Text("Changes apply to the timeline immediately.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(choice.swatch)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle().strokeBorder(.background, lineWidth: 2)
                )
                .overlay(
                    // Selection ring outside the inner border, so it reads against the swatch.
                    Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
                        .padding(-3)
                )
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Chat behavior toggles: emoji rendering, time format, timestamps, receipts.
struct ChatSettingsView: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Toggle("Jumbo emoji", isOn: $prefs.jumboEmoji)
            } header: {
                Text("Emoji")
            } footer: {
                Text("Jumbo emoji enlarges messages that are only emoji.")
            }

            Section {
                Toggle("24-hour time", isOn: $prefs.use24HourTime)
                Toggle("Always show timestamps", isOn: $prefs.alwaysShowTimestamps)
            } header: {
                Text("Time")
            } footer: {
                Text("Always show timestamps displays the time on every message, not just on hover.")
            }

            Section {
                Toggle("Show read receipts", isOn: $prefs.showReadReceipts)
            } footer: {
                Text("Shows who has read up to each message in the timeline.")
            }
        }
        .formStyle(.grouped)
    }
}
