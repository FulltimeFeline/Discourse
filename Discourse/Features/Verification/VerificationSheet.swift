import SwiftUI

struct VerificationSheet: View {
    let scope: SessionScope
    var incoming: SessionScope.IncomingVerification? = nil
    @State private var viewModel: VerificationViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformBody
            .onAppear {
                guard viewModel == nil else { return }
                let viewModel = VerificationViewModel(service: scope.service)
                self.viewModel = viewModel
                if let incoming {
                    Task {
                        await viewModel.beginIncomingVerification(senderId: incoming.senderId,
                                                                  flowId: incoming.flowId)
                    }
                }
            }
            .onDisappear {
                // Hand the delegate back to the incoming-request watcher.
                Task { await scope.watchForIncomingVerification() }
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        VStack(spacing: 20) {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .frame(width: 440)
        #else
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let viewModel {
                        content(viewModel)
                    } else {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Verify Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel?.step == .done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            cancelIfInFlight()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// Cancels an in-flight verification before dismissing.
    private func cancelIfInFlight() {
        switch viewModel?.step {
        case .waitingForOtherDevice, .comparingEmojis, .confirming:
            viewModel?.cancel()
        default:
            break
        }
    }

    @ViewBuilder
    private func content(_ viewModel: VerificationViewModel) -> some View {
        switch viewModel.step {
        case .intro:
            // Full sentences per platform; splicing the device noun in won't translate.
            #if os(macOS)
            header("Verify This Session", systemImage: "lock.shield",
                   subtitle: Text("Until this Mac is verified, your encrypted messages stay locked."))
            #else
            header("Verify This Session", systemImage: "lock.shield",
                   subtitle: Text("Until this device is verified, your encrypted messages stay locked."))
            #endif
            VStack(spacing: 10) {
                Button {
                    Task { await viewModel.beginDeviceVerification() }
                } label: {
                    Label("Verify with Another Device", systemImage: "iphone.gen3")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.showRecoveryKeyEntry()
                } label: {
                    Label("Use Recovery Key", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                #if os(iOS)
                .buttonStyle(.bordered)
                #endif
            }
            #if os(macOS)
            dismissButton("Not Now")
            #endif

        case .waitingForOtherDevice:
            header("Check Your Other Device", systemImage: "iphone.gen3.radiowaves.left.and.right",
                   subtitle: Text("Accept the verification request on a device where you're already signed in."))
            ProgressView()
            #if os(macOS)
            Button("Cancel") {
                viewModel.cancel()
                dismiss()
            }
            #endif

        case .comparingEmojis(let emojis):
            header("Compare Emojis", systemImage: "face.smiling",
                   subtitle: Text("Confirm the same emojis appear in the same order on your other device."))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                ForEach(emojis, id: \.self) { emoji in
                    VStack(spacing: 4) {
                        Text(emoji.symbol).font(.system(size: 32))
                        Text(emoji.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            HStack {
                Button("They Don't Match", role: .destructive) {
                    viewModel.emojisDontMatch()
                }
                Button("They Match") {
                    viewModel.emojisMatch()
                }
                .buttonStyle(.borderedProminent)
            }
            #else
            VStack(spacing: 10) {
                Button {
                    viewModel.emojisMatch()
                } label: {
                    Text("They Match")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    viewModel.emojisDontMatch()
                } label: {
                    Text("They Don't Match")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            #endif

        case .confirming:
            header("Confirming…", systemImage: "hourglass",
                   subtitle: Text("Waiting for your other device to confirm."))
            ProgressView()

        case .recoveryKeyEntry:
            header("Enter Recovery Key", systemImage: "key",
                   subtitle: Text("The recovery key you saved when setting up encrypted backup (looks like EsT… groups of four)."))
            recoveryEntry(viewModel)

        case .recovering:
            header("Restoring Keys…", systemImage: "key")
            ProgressView()

        case .done:
            #if os(macOS)
            header("Session Verified", systemImage: "checkmark.seal.fill",
                   subtitle: Text("Encrypted messages will now decrypt on this Mac."))
            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            #else
            header("Session Verified", systemImage: "checkmark.seal.fill",
                   subtitle: Text("Encrypted messages will now decrypt on this device."))
            #endif

        case .failed(let message):
            header("Verification Failed", systemImage: "xmark.seal",
                   subtitle: Text(message))
            #if os(macOS)
            HStack {
                Button("Close") { dismiss() }
                Button("Try Again") { viewModel.reset() }
                    .buttonStyle(.borderedProminent)
            }
            #else
            VStack(spacing: 10) {
                Button {
                    viewModel.reset()
                } label: {
                    Text("Try Again")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
            #endif
        }
    }

    @ViewBuilder
    private func recoveryEntry(_ viewModel: VerificationViewModel) -> some View {
        @Bindable var viewModel = viewModel
        SecureField("Recovery key", text: $viewModel.recoveryKey)
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #else
            .textFieldStyle(.plain)
            .textContentType(.password)
            .submitLabel(.go)
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            #endif
            .onSubmit { Task { await viewModel.submitRecoveryKey() } }
        #if os(macOS)
        HStack {
            Button("Back") { viewModel.reset() }
            Button("Restore") {
                Task { await viewModel.submitRecoveryKey() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #else
        VStack(spacing: 10) {
            Button {
                Task { await viewModel.submitRecoveryKey() }
            } label: {
                Text("Restore")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Back") { viewModel.reset() }
                .font(.subheadline)
        }
        #endif
    }

    /// Title is a `LocalizedStringKey`; the subtitle is a `Text` so dynamic
    /// call sites stay verbatim while literals localize.
    private func header(_ title: LocalizedStringKey, systemImage: String,
                        subtitle: Text? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title).font(.title2.weight(.semibold))
            if let subtitle {
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    #if os(macOS)
    private func dismissButton(_ label: String) -> some View {
        Button(label) { dismiss() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }
    #endif
}
