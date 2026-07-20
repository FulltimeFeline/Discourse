import SwiftUI

/// Ringing banner for an incoming call; floats over the main window while the
/// ringtone loops.
struct IncomingCallView: View {
    let call: AppState.RingingCall
    let accept: () -> Void
    let decline: () -> Void

    #if os(iOS)
    private static let buttonSize: CGFloat = 44
    private static let buttonIconSize: CGFloat = 17
    #else
    private static let buttonSize: CGFloat = 38
    private static let buttonIconSize: CGFloat = 15
    #endif

    var body: some View {
        HStack(spacing: 12) {
            RoomAvatarView(name: call.roomName, isDirect: call.isDirect, size: 44,
                           avatarURL: call.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.roomName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Incoming call…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(action: decline) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: Self.buttonIconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Decline")
            .accessibilityLabel("Decline")
            Button(action: accept) {
                Image(systemName: "phone.fill")
                    .font(.system(size: Self.buttonIconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(.green, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Accept")
            .accessibilityLabel("Accept")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Fixed on desktop; spans the phone screen, capped on iPad.
        #if os(macOS)
        .frame(width: 380)
        #else
        .frame(maxWidth: 420)
        #endif
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        #if os(iOS)
        .padding(.horizontal, 12)
        #endif
        .padding(.top, 14)
        .onAppear { RingtonePlayer.shared.start() }
        .onDisappear { RingtonePlayer.shared.stop() }
        .task {
            // Give up ringing if nobody picks up.
            try? await Task.sleep(for: .seconds(45))
            decline()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
