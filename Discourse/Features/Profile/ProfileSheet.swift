import SwiftUI

struct ProfileTarget: Identifiable {
    var id: String { userId }
    let userId: String
    var displayName: String?
    var avatarURL: String?
}

/// A wide banner image loaded from an mxc URL through the media loader.
struct BannerImageView: View {
    let mxcUrl: String
    @Environment(\.mediaLoader) private var mediaLoader
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .clipped()
        .task(id: mxcUrl) {
            image = await mediaLoader?.avatar(mxcUrl: mxcUrl, pixelSize: 700)
        }
    }
}

/// A tappable `foxchat.social_links` entry: an optional icon, the title, and an
/// external-link chevron. Opens the link in the browser.
private struct SocialLinkRow: View {
    let link: MatrixService.SocialLink
    @Environment(\.mediaLoader) private var mediaLoader
    @Environment(\.openURL) private var openURL
    @State private var icon: PlatformImage?

    var body: some View {
        Button {
            if let url = URL(string: link.link) { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(platformImage: icon).resizable().scaledToFill()
                    } else if let img = link.img, !img.isEmpty, !img.hasPrefix("mxc://") {
                        Text(img)  // unicode emoji icon
                    } else {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(link.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(link.link)
        // Only mxc icons load through the media loader; http(s) icons are skipped
        // (CSP/remote-fetch), falling back to the link glyph.
        .task(id: link.img) {
            guard let img = link.img, img.hasPrefix("mxc://") else { return }
            icon = await mediaLoader?.avatar(mxcUrl: img, pixelSize: 40)
        }
    }
}

/// A full-screen list of shared rooms/spaces, opened from a "Mutual …" button.
private struct MutualRoomsList: View {
    let title: LocalizedStringKey
    let refs: [ProfileSheet.MutualRef]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        NavigationStack {
            list
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        #else
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            list
        }
        .frame(width: 340, height: 420)
        #endif
    }

    private var list: some View {
        List(refs) { ref in
            Button {
                open(ref.id)
            } label: {
                HStack(spacing: 10) {
                    RoomAvatarView(name: ref.name, isDirect: false, size: 30,
                                   avatarURL: ref.avatarURL)
                    Text(ref.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }
}

/// Compact user profile: avatar, names, message/copy actions.
struct ProfileSheet: View {
    let target: ProfileTarget
    let ownUserId: String
    /// Starts (or opens) a DM and navigates to it; false when creation failed.
    let message: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.presenceService) private var presence
    @Environment(\.pronounsStore) private var pronounsStore
    @Environment(AppState.self) private var appState
    @State private var isMessaging = false
    @State private var messageError: String?
    @State private var mutualSpaces: [MutualRef] = []
    @State private var mutualRooms: [MutualRef] = []
    @State private var mutualList: MutualList?

    /// A room/space shared with the profile's user.
    struct MutualRef: Identifiable, Hashable {
        let id: String
        let name: String
        let avatarURL: String?
        let isSpace: Bool
    }

    /// The list opened by a "Mutual …" button.
    struct MutualList: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let refs: [MutualRef]
    }

    var body: some View {
        layout
            .task(id: target.userId) { await loadMutual() }
            .sheet(item: $mutualList) { list in
                MutualRoomsList(title: list.title, refs: list.refs) { id in
                    appState.pendingRoomNavigation = id
                    mutualList = nil
                    dismiss()
                }
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeader
                    VStack(spacing: 14) {
                        identityBlock
                        bioBlock
                        linksBlock
                        mutualBlock
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { actionButtons }
                            VStack(spacing: 10) { actionButtons }
                        }
                        if let messageError {
                            Text(messageError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
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
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
                .padding(10)
            }
        #endif
    }

    /// iOS header: a full-width banner (or accent gradient) with the avatar
    /// overlapping its bottom edge, ringed against the sheet background — the
    /// familiar social-profile look.
    @ViewBuilder
    private var profileHeader: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let banner = pronounsStore?.bannerURL(for: target.userId) {
                    BannerImageView(mxcUrl: banner)
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                            Color.accentColor.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: 112)
            .frame(maxWidth: .infinity)
            .clipped()

            RoomAvatarView(name: target.displayName ?? target.userId, isDirect: true,
                           size: 92, avatarURL: target.avatarURL)
                .overlay(Circle().strokeBorder(Color.platformWindowBackground, lineWidth: 4))
                .presenceIndicator(userId: target.userId, size: 18)
                .offset(y: 46)
        }
        .padding(.bottom, 46)
    }

    /// macOS profile card (compact, centered).
    private var content: some View {
        VStack(spacing: 14) {
            if let banner = pronounsStore?.bannerURL(for: target.userId) {
                BannerImageView(mxcUrl: banner)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            RoomAvatarView(name: target.displayName ?? target.userId, isDirect: true,
                           size: 72, avatarURL: target.avatarURL)
                .presenceIndicator(userId: target.userId, size: 16)
            identityBlock
            bioBlock
            linksBlock
            mutualBlock

            // Side by side, stacking at accessibility type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(spacing: 10) { actionButtons }
            }
            if let messageError {
                Text(messageError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Name, pronouns, handle, status, presence and local time — shared by both
    /// platforms' layouts.
    @ViewBuilder
    private var identityBlock: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(target.displayName ?? target.userId)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let pronouns = pronounsStore?.pronouns(for: target.userId) {
                    Text(pronouns)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(target.userId)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let status = pronounsStore?.status(for: target.userId), !status.isEmpty {
                Label {
                    Text(status)
                } icon: {
                    Image(systemName: "quote.bubble.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            if let presence, let detail = presence.detailText(of: target.userId) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(presence.state(of: target.userId) == .online
                                     ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .padding(.top, 2)
            }
            if let local = localTime {
                Label(local, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bioBlock: some View {
        if let bio = pronounsStore?.bio(for: target.userId) {
            Text(bio)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var linksBlock: some View {
        if let links = pronounsStore?.socialLinks(for: target.userId), !links.isEmpty {
            VStack(spacing: 6) {
                ForEach(links) { link in
                    SocialLinkRow(link: link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var mutualBlock: some View {
        if !mutualSpaces.isEmpty || !mutualRooms.isEmpty {
            VStack(spacing: 6) {
                mutualButton("Mutual Spaces", systemImage: "square.stack.3d.up", refs: mutualSpaces)
                mutualButton("Mutual Rooms", systemImage: "number", refs: mutualRooms)
            }
        }
    }

    /// A "Mutual …(N)" button that opens the full list in its own screen, so the
    /// profile card stays compact even with lots of shared rooms.
    @ViewBuilder
    private func mutualButton(_ title: LocalizedStringKey, systemImage: String,
                              refs: [MutualRef]) -> some View {
        if !refs.isEmpty {
            Button {
                mutualList = MutualList(title: title, refs: refs)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(title).font(.callout)
                    Text("\(refs.count)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Loads shared rooms/spaces (MSC2666) and resolves them against our own
    /// room list, split into spaces vs (non-DM) rooms.
    private func loadMutual() async {
        guard case .active(let scope) = appState.phase, target.userId != ownUserId else {
            mutualSpaces = []; mutualRooms = []
            return
        }
        let ids = Set(await scope.service.mutualRooms(with: target.userId))
        guard !ids.isEmpty else { mutualSpaces = []; mutualRooms = []; return }
        mutualSpaces = scope.roomList.spaces
            .filter { ids.contains($0.id) }
            .map { MutualRef(id: $0.id, name: $0.name, avatarURL: $0.avatarURL, isSpace: true) }
        mutualRooms = scope.roomList.rooms
            .filter { ids.contains($0.id) && !$0.isSpace && !$0.isDirect }
            .map { MutualRef(id: $0.id, name: $0.name, avatarURL: $0.avatarURL, isSpace: false) }
    }

    /// The user's current local time, from their `m.tz` IANA timezone.
    private var localTime: String? {
        guard let tz = pronounsStore?.timezone(for: target.userId),
              let zone = TimeZone(identifier: tz) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let abbreviation = zone.abbreviation() ?? tz
        return "\(formatter.string(from: .now)) local time (\(abbreviation))"
    }

    @ViewBuilder
    private var actionButtons: some View {
        if target.userId != ownUserId {
            Button {
                guard !isMessaging else { return }
                isMessaging = true
                messageError = nil
                Task {
                    let ok = await message(target.userId)
                    if ok {
                        dismiss()
                    } else {
                        isMessaging = false
                        messageError = String(localized: "Couldn't start the conversation.")
                    }
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
