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
        .frame(width: 560, height: 460)
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
            Section("Profile") {
                ProfileEditSection(scope: scope)
            }
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
    @State private var showsAvatarPicker = false
    @State private var isSaving = false
    @State private var status: (message: String, isError: Bool)?
    #if os(iOS)
    @State private var avatarItem: PhotosPickerItem?
    #endif

    var body: some View {
        HStack(spacing: 12) {
            RoomAvatarView(name: displayName.isEmpty ? scope.userId : displayName,
                           isDirect: true, size: 52, avatarURL: scope.ownAvatarURL)
                .task {
                    await scope.loadOwnProfile()
                    if displayName.isEmpty {
                        displayName = scope.ownDisplayName ?? ""
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // iOS: 44pt-friendly borderless buttons; macOS: compact
                    // settings-window controls.
                    Button("Change Avatar…") { showsAvatarPicker = true }
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    if scope.ownAvatarURL != nil {
                        Button("Remove") {
                            run { try await scope.removeAvatar() }
                        }
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    }
                }
                Text("Your avatar and name are visible to everyone you share a room with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // iOS: photo library; macOS: file importer.
        #if os(iOS)
        .photosPicker(isPresented: $showsAvatarPicker, selection: $avatarItem, matching: .images)
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            avatarItem = nil
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/png"
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                run { try await scope.setAvatar(data: data, mimeType: mime) }
            }
        }
        #else
        .fileImporter(isPresented: $showsAvatarPicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            run { try await scope.setAvatar(data: data, mimeType: mime) }
        }
        #endif

        HStack {
            // Plain row in the iOS Form; rounded border only in the macOS
            // settings window.
            TextField("Display name", text: $displayName)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                .submitLabel(.done)
                #endif
                .onSubmit { saveName() }
            Button("Save") { saveName() }
                .disabled(isSaving
                          || displayName.trimmingCharacters(in: .whitespaces).isEmpty
                          || displayName == scope.ownDisplayName)
        }

        if let status {
            Text(status.message)
                .font(.callout)
                .foregroundStyle(status.isError ? .red : .green)
        }
    }

    private func saveName() {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run { try await scope.setDisplayName(name) }
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

#if os(iOS)
/// The iPhone Settings tab: identity, profile editing, stickers, account controls.
struct ProfileTabView: View {
    let scope: SessionScope
    @Environment(AppState.self) private var appState
    @State private var showsSignOutConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        RoomAvatarView(name: scope.ownDisplayName ?? scope.userId,
                                       isDirect: true, size: 64,
                                       avatarURL: scope.ownAvatarURL)
                            .presenceIndicator(userId: scope.userId, size: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.ownDisplayName ?? scope.userId)
                                .font(.title3.weight(.semibold))
                            Text(scope.userId)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("Profile") {
                    ProfileEditSection(scope: scope)
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
                                if token.session.userId == appState.activeUserId {
                                    Spacer()
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
