import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showsSignOutConfirm = false

    var body: some View {
        Group {
            if case .active(let scope) = appState.phase {
                signedInTabs(scope: scope)
            } else {
                signedOutTabs
            }
        }
        // Wide enough that all ten tab items stay in the toolbar instead of
        // collapsing into an overflow menu.
        .frame(width: 860, height: 480)
    }

    @ViewBuilder
    private func signedInTabs(scope: SessionScope) -> some View {
        TabView {
            accountTab(scope: scope)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ChatSettingsView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AccessibilitySettingsView()
                .tabItem { Label("Accessibility", systemImage: "accessibility") }
            StorageSettingsView(loader: scope.mediaLoader)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            StickerMakerView(store: scope.stickers, loader: scope.mediaLoader)
                .tabItem { Label("Stickers", systemImage: "face.smiling") }
            AdvancedSettingsView(scope: scope)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .environment(\.mediaLoader, scope.mediaLoader)
    }

    private var signedOutTabs: some View {
        TabView {
            Form {
                Text("Sign in to see settings.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }

    @ViewBuilder
    private func accountTab(scope: SessionScope) -> some View {
        Form {
            ProfileEditSection(scope: scope)
            Section("Account") {
                LabeledContent("User ID", value: scope.userId)
                LabeledContent("Homeserver", value: scope.token.session.homeserverUrl)
                LabeledContent("Device ID", value: scope.token.session.deviceId)
            }
            Section {
                Button("Sign Out…", role: .destructive) {
                    showsSignOutConfirm = true
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Sign out of \(scope.userId)?"),
            isPresented: $showsSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.logOut() }
            }
        } message: {
            Text("Local session data is removed from this device.")
        }
    }
}

/// Edit avatar and display name, published server-side.
private struct ProfileEditSection: View {
    let scope: SessionScope

    @State private var displayName = ""
    @State private var pronouns = ""
    @State private var bio = ""
    @State private var statusMsg = ""
    @State private var timezone = ""
    @State private var links: [EditableLink] = []
    @State private var loaded = false
    @State private var iconTarget: LinkIconTarget?

    /// A mutable social-link row (stable id for ForEach/focus).
    struct EditableLink: Identifiable {
        let id = UUID()
        var title = ""
        var link = ""
        var img = ""
    }

    /// Identifies which link row's icon the emote picker is choosing for.
    struct LinkIconTarget: Identifiable { let id: UUID }
    // A single image picker, routed by target: SwiftUI faults if two
    // .photosPicker/.fileImporter modifiers coexist in one view subtree.
    private enum ImageTarget { case avatar, banner }
    @State private var imageTarget: ImageTarget = .avatar
    @State private var showsImagePicker = false
    @State private var isSaving = false
    @State private var status: (message: String, isError: Bool)?
    #if os(iOS)
    @State private var pickerItem: PhotosPickerItem?
    #endif

    var body: some View {
        // Centered avatar header, sitting on the form background rather than in
        // a boxed row — the standard "profile top" look.
        Section {
            VStack(spacing: 12) {
                RoomAvatarView(name: displayName.isEmpty ? scope.userId : displayName,
                               isDirect: true, size: 88, avatarURL: scope.ownAvatarURL)
                    .task {
                        await scope.loadOwnProfile()
                        // Seed the editable fields once, so typing isn't clobbered
                        // by a later profile refresh.
                        guard !loaded else { return }
                        loaded = true
                        displayName = scope.ownDisplayName ?? ""
                        pronouns = scope.ownPronouns ?? ""
                        bio = scope.ownBio ?? ""
                        statusMsg = scope.ownStatus ?? ""
                        timezone = scope.ownTimezone ?? ""
                        links = scope.ownSocialLinks.map {
                            EditableLink(title: $0.title, link: $0.link, img: $0.img ?? "")
                        }
                    }
                Text(displayName.isEmpty ? scope.userId : displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Button("Change Photo") { imageTarget = .avatar; showsImagePicker = true }
                    if scope.ownAvatarURL != nil {
                        Button("Remove", role: .destructive) {
                            run { try await scope.removeAvatar() }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
        // One picker for both avatar and banner, routed by `imageTarget`.
        // iOS: photo library; macOS: file importer.
        #if os(iOS)
        .photosPicker(isPresented: $showsImagePicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/png"
            let target = imageTarget
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    status = (String(localized: "Couldn't read that image."), true)
                    return
                }
                applyPickedImage(data: data, mime: mime, target: target)
            }
        }
        #else
        .fileImporter(isPresented: $showsImagePicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            applyPickedImage(data: data, mime: mime, target: imageTarget)
        }
        #endif

        Section {
            if let banner = scope.ownBannerURL {
                BannerImageView(mxcUrl: banner)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 10) {
                Button(scope.ownBannerURL == nil ? "Add Banner…" : "Change Banner…") {
                    imageTarget = .banner; showsImagePicker = true
                }
                if scope.ownBannerURL != nil {
                    Button("Remove", role: .destructive) { run { await scope.removeBanner() } }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } header: {
            Text("Banner")
        } footer: {
            Text("Shows at the top of your profile card.")
        }

        Section {
            labeledField("Name", placeholder: "Display name", text: $displayName)
            labeledField("Pronouns", placeholder: "they/them", text: $pronouns)
            labeledField("Status", placeholder: "What you're up to", text: $statusMsg)
            VStack(alignment: .leading, spacing: 6) {
                Text("Bio").foregroundStyle(.secondary)
                #if os(macOS)
                TextField("", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                #else
                TextField("Add a bio", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                #endif
            }
            timezoneRow
        } header: {
            Text("Identity")
        } footer: {
            Text("Your name, pronouns, and status are visible to everyone you share a room with.")
        }

        Section {
            socialLinksEditor
        } header: {
            Text("Social Links")
        }

        Section {
            Button { saveAll() } label: {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Save Profile").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || !hasChanges)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        } footer: {
            if let status {
                Text(status.message)
                    .font(.callout)
                    .foregroundStyle(status.isError ? .red : .green)
            }
        }
    }

    /// A labeled text row: right-aligned field on iOS (Settings-style), a
    /// bordered field beside its label on macOS.
    @ViewBuilder
    private func labeledField(_ label: LocalizedStringKey,
                              placeholder: LocalizedStringKey,
                              text: Binding<String>) -> some View {
        #if os(macOS)
        // The label already names the field, so no placeholder example.
        LabeledContent(label) {
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
        #else
        HStack {
            Text(label)
            Spacer(minLength: 12)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .submitLabel(.done)
        }
        #endif
    }

    @ViewBuilder
    private var timezoneRow: some View {
        #if os(macOS)
        LabeledContent("Timezone") {
            HStack {
                TextField("", text: $timezone).textFieldStyle(.roundedBorder)
                Button("Use current") { timezone = TimeZone.current.identifier }
                    .controlSize(.small)
            }
        }
        #else
        HStack {
            Text("Timezone")
            Spacer(minLength: 12)
            TextField("Europe/Berlin", text: $timezone)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .submitLabel(.done)
            Button { timezone = TimeZone.current.identifier } label: {
                Image(systemName: "location.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Use current timezone")
        }
        #endif
    }

    @ViewBuilder
    private var socialLinksEditor: some View {
        ForEach($links) { $link in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Title", text: $link.title)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    // iOS: inline remove; macOS puts it at the bottom of the row.
                    #if os(iOS)
                    Button {
                        links.removeAll { $0.id == link.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove link")
                    #endif
                }
                TextField("Link (https://…)", text: $link.link)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #else
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                HStack(spacing: 8) {
                    Button {
                        iconTarget = LinkIconTarget(id: link.id)
                    } label: {
                        HStack(spacing: 6) {
                            LinkIconPreview(img: link.img, loader: scope.mediaLoader)
                            Text(link.img.isEmpty ? "Choose Icon…" : "Change Icon…")
                        }
                    }
                    .controlSize(.small)
                    if !link.img.isEmpty {
                        Button { link.img = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove icon")
                    }
                    Spacer()
                    #if os(macOS)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        links.removeAll { $0.id == link.id }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Remove link")
                    #endif
                }
            }
            .padding(.vertical, 4)
        }
        Button {
            links.append(EditableLink())
        } label: {
            Label("Add Link", systemImage: "plus.circle.fill")
        }
        .controlSize(.small)
        .sheet(item: $iconTarget) { target in
            EmoteIconPicker(scope: scope) { img in
                if let i = links.firstIndex(where: { $0.id == target.id }) {
                    links[i].img = img
                }
                iconTarget = nil
            }
        }
    }

    /// The edited links as `SocialLink`s, dropping rows with no usable link.
    private var currentLinks: [MatrixService.SocialLink] {
        links.compactMap { row in
            let link = row.link.trimmingCharacters(in: .whitespaces)
            guard !link.isEmpty else { return nil }
            let title = row.title.trimmingCharacters(in: .whitespaces)
            let img = row.img.trimmingCharacters(in: .whitespaces)
            return MatrixService.SocialLink(img: img.isEmpty ? nil : img,
                                            title: title.isEmpty ? link : title,
                                            link: link)
        }
    }

    private var hasChanges: Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameChanged = !norm(displayName).isEmpty && norm(displayName) != (scope.ownDisplayName ?? "")
        return nameChanged
            || norm(pronouns) != (scope.ownPronouns ?? "")
            || norm(statusMsg) != (scope.ownStatus ?? "")
            || norm(bio) != (scope.ownBio ?? "")
            || norm(timezone) != (scope.ownTimezone ?? "")
            || currentLinks != scope.ownSocialLinks
    }

    /// Saves every field that changed, in one pass.
    private func saveAll() {
        isSaving = true
        status = nil
        Task {
            defer { isSaving = false }
            func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
            do {
                let name = norm(displayName)
                if !name.isEmpty, name != scope.ownDisplayName { try await scope.setDisplayName(name) }
                if norm(pronouns) != (scope.ownPronouns ?? "") { await scope.setPronouns(pronouns) }
                if norm(statusMsg) != (scope.ownStatus ?? "") { await scope.setStatus(statusMsg) }
                if norm(bio) != (scope.ownBio ?? "") { await scope.setBio(bio) }
                if norm(timezone) != (scope.ownTimezone ?? "") { await scope.setTimezone(timezone) }
                if currentLinks != scope.ownSocialLinks { await scope.setSocialLinks(currentLinks) }
                status = (String(localized: "Profile updated."), false)
            } catch {
                status = (error.localizedDescription, true)
            }
        }
    }

    private func applyPickedImage(data: Data, mime: String, target: ImageTarget) {
        switch target {
        case .avatar: run { try await scope.setAvatar(data: data, mimeType: mime) }
        case .banner: run { try await scope.setBanner(data: data, mimeType: mime) }
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        isSaving = true
        status = nil
        Task {
            defer { isSaving = false }
            do {
                try await operation()
                status = (String(localized: "Profile updated."), false)
            } catch {
                status = (error.localizedDescription, true)
            }
        }
    }
}

/// Small preview of a social-link icon: an mxc emote, a unicode emoji, or a
/// placeholder glyph.
private struct LinkIconPreview: View {
    let img: String
    let loader: MediaLoader?
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else if !img.isEmpty, !img.hasPrefix("mxc://") {
                Text(img)  // unicode emoji
            } else {
                Image(systemName: "face.smiling").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .task(id: img) {
            image = nil
            guard img.hasPrefix("mxc://") else { return }
            image = await loader?.avatar(mxcUrl: img, pixelSize: 40)
        }
    }
}

/// Presents the emoji/emote picker to choose a social-link icon: a custom emote
/// yields its mxc URL, a unicode emoji yields the character.
private struct EmoteIconPicker: View {
    let scope: SessionScope
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var picker: some View {
        EmojiPickerView(
            customPacks: scope.customEmoji.packs,
            loader: scope.mediaLoader,
            insertCustom: { onPick($0.url) },
            insert: { onPick($0) })
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            picker
                .navigationTitle("Choose Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        #else
        VStack(spacing: 0) {
            HStack {
                Text("Choose Icon").font(.headline)
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
            picker
        }
        .frame(width: 360, height: 420)
        #endif
    }
}

#if os(iOS)
/// The iPhone Settings tab: identity, profile editing, stickers, account controls.
struct ProfileTabView: View {
    let scope: SessionScope
    @Environment(AppState.self) private var appState
    @State private var showsSignOutConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // Apple-ID-style identity card: taps through to a dedicated Edit
                // Profile screen rather than inlining the whole editor here.
                Section {
                    NavigationLink {
                        Form { ProfileEditSection(scope: scope) }
                            .navigationTitle("Edit Profile")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 14) {
                            RoomAvatarView(name: scope.ownDisplayName ?? scope.userId,
                                           isDirect: true, size: 60,
                                           avatarURL: scope.ownAvatarURL)
                                .presenceIndicator(userId: scope.userId, size: 15)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scope.ownDisplayName ?? scope.userId)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Edit Profile")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                Section("Customization") {
                    NavigationLink {
                        AppearanceSettingsView()
                            .navigationTitle("Appearance")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    NavigationLink {
                        ChatSettingsView()
                            .navigationTitle("Chat")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink {
                        AccessibilitySettingsView()
                            .navigationTitle("Accessibility")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Accessibility", systemImage: "accessibility")
                    }
                    NavigationLink {
                        StorageSettingsView(loader: scope.mediaLoader)
                            .navigationTitle("Storage")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        StickerMakerView(store: scope.stickers, loader: scope.mediaLoader)
                            .navigationTitle("Stickers")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Stickers", systemImage: "face.smiling")
                    }
                }
                Section {
                    NavigationLink {
                        PrivacySettingsView()
                            .navigationTitle("Privacy & Security")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Privacy & Security", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        NotificationSettingsView()
                            .navigationTitle("Notifications")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                Section("Accounts") {
                    ForEach(appState.accountTokens, id: \.session.userId) { token in
                        Button {
                            Task { await appState.switchAccount(to: token.session.userId) }
                        } label: {
                            HStack {
                                Text(token.session.userId)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if token.session.userId != appState.activeUserId,
                                   appState.unreadCount(forUserId: token.session.userId) > 0 {
                                    UnreadBadge(count: appState.unreadCount(forUserId: token.session.userId))
                                }
                                if token.session.userId == appState.activeUserId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Button("Add Account…", systemImage: "person.badge.plus") {
                        appState.isAddAccountPresented = true
                    }
                }
                Section("Account") {
                    LabeledContent("Homeserver", value: scope.token.session.homeserverUrl)
                    LabeledContent("Device ID", value: scope.token.session.deviceId)
                }
                Section {
                    NavigationLink {
                        AdvancedSettingsView(scope: scope)
                            .navigationTitle("Advanced")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Advanced", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        AboutSettingsView()
                            .navigationTitle("About")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                Section {
                    Button("Sign Out…", role: .destructive) {
                        showsSignOutConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                Text("Sign out of \(scope.userId)?"),
                isPresented: $showsSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await appState.logOut() }
                }
            } message: {
                Text("Local session data is removed from this device.")
            }
        }
        .environment(\.mediaLoader, scope.mediaLoader)
    }
}
#endif

/// Pick and name an image; it's cropped, scaled to 512px, uploaded, and saved
/// to the account-wide sticker pack (MSC2545).
struct StickerMakerView: View {
    let store: StickerStore
    let loader: MediaLoader

    @State private var pickedData: Data?
    @State private var pickedPreview: PlatformImage?
    @State private var name = ""
    @State private var pack = StickerStore.Sticker.defaultPack
    @State private var showsPicker = false
    @State private var isAdding = false
    #if os(iOS)
    @State private var pickerItem: PhotosPickerItem?
    #endif

    var body: some View {
        platformBody
            .task { await store.load() }
    }

    private func addSticker() {
        guard let pickedData else { return }
        isAdding = true
        let stickerName = name
        let packName = pack
        Task {
            // store.add reports failure via store.errorMessage, not throwing;
            // keep the picked image and name so a retry needn't re-pick.
            await store.add(name: stickerName, imageData: pickedData, pack: packName)
            isAdding = false
            if store.errorMessage == nil {
                self.pickedData = nil
                self.pickedPreview = nil
                self.name = ""
            }
        }
    }

    private var canAdd: Bool {
        pickedData != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !isAdding
    }

    // MARK: iOS — inset-grouped Form with per-row deletion

    #if os(iOS)
    private var platformBody: some View {
        Form {
            Section {
                Button {
                    showsPicker = true
                } label: {
                    HStack {
                        Text(pickedPreview == nil ? "Choose Image" : "Change Image")
                        Spacer()
                        if let pickedPreview {
                            Image(platformImage: pickedPreview)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "photo.badge.plus")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .photosPicker(isPresented: $showsPicker, selection: $pickerItem, matching: .images)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    pickerItem = nil
                    Task {
                        guard let data = try? await item.loadTransferable(type: Data.self)
                        else { return }
                        pickedData = data
                        pickedPreview = PlatformImage(data: data)
                    }
                }

                TextField("Name", text: $name)
                    .submitLabel(.done)

                HStack {
                    TextField("Pack", text: $pack)
                        .submitLabel(.done)
                    if !store.packs.isEmpty {
                        Menu {
                            ForEach(store.packs, id: \.self) { existing in
                                Button(existing) { pack = existing }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(Text("Choose Existing Pack"))
                    }
                }

                Button {
                    addSticker()
                } label: {
                    if isAdding {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Adding…")
                        }
                    } else {
                        Text("Add Sticker")
                    }
                }
                .disabled(!canAdd)
            } header: {
                Text("New Sticker")
            } footer: {
                Text("Stickers are cropped, scaled, and saved to your account-wide pack. They sync to other Matrix clients.")
            }

            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }

            if store.stickers.isEmpty {
                Section {
                    Text("Your stickers appear here and sync to other Matrix clients.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.packs, id: \.self) { packName in
                    Section(packName) {
                        ForEach(store.stickers(inPack: packName)) { sticker in
                            HStack(spacing: 12) {
                                StickerThumb(sticker: sticker, loader: loader, size: 44)
                                Text(sticker.body)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                // Visible per-row delete, discoverable without a
                                // long-press.
                                Button {
                                    Task { await store.remove(sticker.shortcode) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Delete \(sticker.body)"))
                            }
                            // Long-press affordance too.
                            .contextMenu {
                                Button("Delete Sticker", systemImage: "trash", role: .destructive) {
                                    Task { await store.remove(sticker.shortcode) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: macOS — settings-window card (unchanged)

    #else
    private var platformBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    showsPicker = true
                } label: {
                    Group {
                        if let pickedPreview {
                            Image(platformImage: pickedPreview)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.title2)
                                Text("Choose Image")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                // The file importer's filename prefills the name.
                .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.image]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        pickedData = data
                        pickedPreview = PlatformImage(data: data)
                        if name.isEmpty {
                            name = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Sticker name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        TextField("Pack", text: $pack)
                            .textFieldStyle(.roundedBorder)
                        if !store.packs.isEmpty {
                            Menu {
                                ForEach(store.packs, id: \.self) { existing in
                                    Button(existing) { pack = existing }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel(Text("Choose Existing Pack"))
                        }
                    }
                    Button(isAdding ? "Adding…" : "Add Sticker") {
                        addSticker()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
                }
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            if store.stickers.isEmpty {
                Text("Your stickers appear here and sync to other Matrix clients.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.packs, id: \.self) { packName in
                            Text(packName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)],
                                      spacing: 10) {
                                ForEach(store.stickers(inPack: packName)) { sticker in
                                    VStack(spacing: 2) {
                                        StickerThumb(sticker: sticker, loader: loader, size: 64)
                                        Text(sticker.body)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .contextMenu {
                                        Button("Delete Sticker", systemImage: "trash", role: .destructive) {
                                            Task { await store.remove(sticker.shortcode) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }
    #endif
}
