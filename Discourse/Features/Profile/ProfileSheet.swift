import SwiftUI

struct ProfileTarget: Identifiable {
    var id: String { userId }
    let userId: String
    var displayName: String?
    var avatarURL: String?
}

/// Compact user profile: avatar, names, message/copy actions.
struct ProfileSheet: View {
    let target: ProfileTarget
    let ownUserId: String
    /// Starts (or opens) a DM and navigates to it.
    let message: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.presenceService) private var presence
    @State private var isMessaging = false

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // .large too: the content outgrows .medium at accessibility type sizes.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        content
            .padding(28)
            .frame(width: 340)
            .overlay(alignment: .topTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(10)
            }
        #endif
    }

    private var content: some View {
        VStack(spacing: 14) {
            RoomAvatarView(name: target.displayName ?? target.userId, isDirect: true,
                           size: 72, avatarURL: target.avatarURL)
                .presenceIndicator(userId: target.userId, size: 16)
            VStack(spacing: 2) {
                Text(target.displayName ?? target.userId)
                    .font(.title3.weight(.semibold))
                Text(target.userId)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let presence, let detail = presence.detailText(of: target.userId) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(presence.state(of: target.userId) == .online
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .padding(.top, 2)
                }
            }

            // Side by side, stacking at accessibility type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(spacing: 10) { actionButtons }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if target.userId != ownUserId {
            Button {
                guard !isMessaging else { return }
                isMessaging = true
                Task {
                    await message(target.userId)
                    dismiss()
                }
            } label: {
                Label("Message", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isMessaging)
        }
        Button {
            Platform.copyToClipboard(target.userId)
        } label: {
            Label("Copy User ID", systemImage: "doc.on.doc")
        }
    }
}
