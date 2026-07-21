import SwiftUI

/// Developer-facing controls, the session identity readout, and a reset-everything
/// escape hatch.
struct AdvancedSettingsView: View {
    let scope: SessionScope

    @Environment(Preferences.self) private var prefs
    @State private var showsResetConfirm = false

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Session") {
                LabeledContent("User ID", value: scope.userId)
                    .textSelection(.enabled)
                LabeledContent("Homeserver", value: scope.token.session.homeserverUrl)
                    .textSelection(.enabled)
                LabeledContent("Device ID", value: scope.token.session.deviceId)
                    .textSelection(.enabled)
            }

            Section {
                Toggle("Show event IDs", isOn: $prefs.showEventIds)
            } header: {
                Text("Developer")
            } footer: {
                Text("Displays raw Matrix event IDs beneath messages. Useful for debugging.")
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    showsResetConfirm = true
                }
            } footer: {
                Text("Restores every customization option to its default. Your account and messages are not affected.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Reset all settings?"),
            isPresented: $showsResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) {
                Preferences.shared.resetToDefaults()
            }
        } message: {
            Text("Every customization returns to its default value. This can't be undone.")
        }
    }
}

/// App identity, version, and links out to the Matrix project.
struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Discourse")
                        .font(.title2.weight(.semibold))
                    Text("A Matrix client")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("by FulltimeFeline")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Version") {
                LabeledContent("Version", value: version)
                    .textSelection(.enabled)
                LabeledContent("Build", value: build)
                    .textSelection(.enabled)
            }

            Section {
                Link(destination: URL(string: "https://github.com/FulltimeFeline/Discourse")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://matrix.org")!) {
                    Label("About the Matrix Protocol", systemImage: "network")
                }
                Link(destination: URL(string: "https://spec.matrix.org")!) {
                    Label("Matrix Specification", systemImage: "doc.text")
                }
            } footer: {
                Text("Discourse speaks the open Matrix protocol for secure, decentralized messaging.")
            }
        }
        .formStyle(.grouped)
    }
}
