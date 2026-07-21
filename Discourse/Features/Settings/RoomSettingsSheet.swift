import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import MatrixRustSDK

struct SettingsTarget: Identifiable {
    var id: String { roomId }
    let roomId: String
    let isSpace: Bool
}

struct RoomSettingsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, security, roles, emotes, notifications, polls, advanced
        var id: String { rawValue }

        /// Spaces get a subset of the tabs plus the shared emote pack.
        static func cases(isSpace: Bool) -> [Tab] {
            isSpace ? [.general, .security, .roles, .emotes, .advanced] : allCases
        }

        func title(isSpace: Bool) -> LocalizedStringKey {
            switch self {
            case .general: "General"
            case .security: isSpace ? "Visibility" : "Security & Privacy"
            case .roles: "Roles & Permissions"
            case .emotes: "Emoji & Stickers"
            case .notifications: "Notifications"
            case .polls: "Poll History"
            case .advanced: "Advanced"
            }
        }

        func icon(isSpace: Bool) -> String {
            switch self {
            case .general: "gearshape"
            case .security: isSpace ? "eye" : "lock"
            case .roles: "shield"
            case .emotes: "face.smiling"
            case .notifications: "bell"
            case .polls: "chart.bar.xaxis"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    let scope: SessionScope
    let target: SettingsTarget
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .general
    @State private var model: RoomSettingsModel?

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            List(Tab.cases(isSpace: target.isSpace),
                 selection: Binding(get: { tab }, set: { tab = $0 ?? .general })) { item in
                Label(item.title(isSpace: target.isSpace),
                      systemImage: item.icon(isSpace: target.isSpace))
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                if let model, tab == .emotes {
                    // Has its own scrolling Form; nesting in the shared ScrollView double-scrolls.
                    EmotePackEditor(model: model)
                } else if let model {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch tab {
                            case .general: GeneralSettingsTab(model: model, dismiss: { dismiss() })
                            case .security: SecuritySettingsTab(model: model)
                            case .roles: RolesSettingsTab(model: model)
                            case .emotes: EmptyView()
                            case .notifications: NotificationSettingsTab(model: model)
                            case .polls: PollHistoryTab(model: model)
                            case .advanced: AdvancedSettingsTab(model: model)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 760, height: 560)
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
        .task {
            let model = RoomSettingsModel(scope: scope, target: target)
            await model.load()
            self.model = model
        }
        #else
        NavigationStack {
            Group {
                if let model {
                    RoomSettingsFormiOS(model: model, dismiss: { dismiss() })
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(target.isSpace ? String(localized: "Space Settings")
                                            : String(localized: "Room Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let model = RoomSettingsModel(scope: scope, target: target)
            await model.load()
            self.model = model
        }
        #endif
    }
}

// MARK: - Model

@MainActor
@Observable
final class RoomSettingsModel {
    let scope: SessionScope
    let target: SettingsTarget

    var name = ""
    var topic = ""
    var avatarURL: String?
    /// Space banner (custom state event); nil for rooms and unset spaces.
    var bannerURL: String?
    var canEditBanner = false        // page.codeberg.everypizza.room.banner
    var canonicalAlias: String?
    var newAlias = ""
    var isInDirectory = false
    var isEncrypted = false
    var joinRule: JoinRuleChoice = .invite
    var historyVisibility: HistoryChoice = .shared
    var notificationMode: NotificationChoice = .default_
    var memberCount: UInt64 = 0
    var roomVersion = "?"
    var privilegedUsers: [(userId: String, level: Int64)] = []
    var permissionValues: RoomPowerLevelsValues?
    /// Named roles (in.cinny.room.power_level_tags), power level → tag.
    var powerLevelTags: [Int: PowerLevelTag] = [:]
    var errorMessage: String?
    var infoMessage: String?

    // Resolved from the room's power levels in load(); stay false until then so
    // controls never flash editable (the sheet shows a ProgressView meanwhile).
    // Notification mode is a personal push rule and is intentionally not gated.
    var canEditBasics = false        // m.room.name / m.room.topic / m.room.avatar
    var canEnableEncryption = false  // m.room.encryption
    var canEditAccess = false        // m.room.join_rules / m.room.history_visibility
    var canEditAddresses = false     // m.room.canonical_alias (+ directory listing)
    var canEditRoles = false         // m.room.power_levels

    /// Joined spaces containing this room — restricted-rule targets.
    var parentSpaceIds: [String] {
        scope.roomList.spaceChildIds.compactMap { spaceId, children in
            children.contains(target.roomId) ? spaceId : nil
        }
    }

    var room: Room? { scope.roomList.ffiRoom(withId: target.roomId) }

    enum JoinRuleChoice: Hashable { case invite, spaceMembers, anyone }
    enum HistoryChoice: Hashable { case invited, joined, shared, worldReadable }
    enum NotificationChoice: Hashable { case default_, all, mentions, mute }

    init(scope: SessionScope, target: SettingsTarget) {
        self.scope = scope
        self.target = target
    }

    func load() async {
        guard let room, let info = try? await room.roomInfo() else {
            errorMessage = String(localized: "Couldn't load room details.")
            return
        }
        name = info.displayName ?? info.rawName ?? ""
        topic = info.topic ?? ""
        avatarURL = info.avatarUrl
        canonicalAlias = info.canonicalAlias
        isEncrypted = info.encryptionState == .encrypted
        memberCount = info.joinedMembersCount
        roomVersion = info.roomVersion ?? "?"

        joinRule = switch info.joinRule {
        case .public: .anyone
        case .restricted, .knockRestricted: .spaceMembers
        default: .invite
        }
        historyVisibility = switch info.historyVisibility {
        case .invited: .invited
        case .joined: .joined
        case .worldReadable: .worldReadable
        default: .shared
        }

        if let visibility = try? await room.getRoomVisibility() {
            isInDirectory = visibility == .public
        }
        let settings = await scope.service.client.getNotificationSettings()
        if let mode = try? await settings.getUserDefinedRoomNotificationMode(roomId: target.roomId) {
            notificationMode = switch mode {
            case .allMessages: .all
            case .mentionsAndKeywordsOnly: .mentions
            case .mute: .mute
            }
        } else {
            notificationMode = .default_
        }

        if let levels = try? await room.getPowerLevels() {
            permissionValues = levels.values()
            privilegedUsers = levels.userPowerLevels()
                .filter { $0.value != 0 }
                .map { (userId: $0.key, level: $0.value) }
                .sorted { $0.level == $1.level ? $0.userId < $1.userId : $0.level > $1.level }

            // Require every state event a grouped control covers, so an editable
            // control never fails on save with a partial grant.
            canEditBasics = levels.canOwnUserSendState(stateEvent: .roomName)
                && levels.canOwnUserSendState(stateEvent: .roomTopic)
                && levels.canOwnUserSendState(stateEvent: .roomAvatar)
            canEnableEncryption = levels.canOwnUserSendState(stateEvent: .roomEncryption)
            canEditAccess = levels.canOwnUserSendState(stateEvent: .roomJoinRules)
                && levels.canOwnUserSendState(stateEvent: .roomHistoryVisibility)
            canEditAddresses = levels.canOwnUserSendState(stateEvent: .roomCanonicalAlias)
            canEditRoles = levels.canOwnUserSendState(stateEvent: .roomPowerLevels)
            canEditBanner = target.isSpace && levels.canOwnUserSendState(
                stateEvent: .custom(value: SessionScope.spaceBannerEventType))
        }

        if target.isSpace {
            bannerURL = await scope.roomList.spaceBannerURL(forSpace: target.roomId)
        }

        if let content = await scope.service.stateEventContent(
            roomId: target.roomId, type: PowerLevelTags.eventType) {
            powerLevelTags = PowerLevelTags.parse(content)
        }
    }

    func roleTag(forLevel level: Int) -> PowerLevelTag {
        powerLevelTags[level] ?? PowerLevelTags.defaultTag(forLevel: level)
    }

    /// Persists the named-role labels (in.cinny.room.power_level_tags).
    func savePowerLevelTags() {
        // Drop tags equal to their default so the event only carries edits.
        let tags = powerLevelTags.filter { $0.value != PowerLevelTags.defaultTag(forLevel: $0.key) }
        run { [self] in
            guard let room else { return }
            let data = try JSONSerialization.data(withJSONObject: PowerLevelTags.content(from: tags))
            _ = try await room.sendStateEventRaw(
                eventType: PowerLevelTags.eventType, stateKey: "",
                content: String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    // MARK: Actions (each surfaces errors and refreshes)

    private func run(_ operation: @escaping () async throws -> Void) {
        errorMessage = nil
        infoMessage = nil
        Task {
            do {
                try await operation()
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveNameAndTopic() {
        guard let room else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            if newName != (room.displayName() ?? "") { try await room.setName(name: newName) }
            if newTopic != (room.topic() ?? "") { try await room.setTopic(topic: newTopic) }
        }
    }

    func setAvatar(data: Data) {
        guard let room else { return }
        run {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) != nil else {
                throw URLError(.cannotDecodeContentData)
            }
            let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
            try await room.uploadAvatar(mimeType: type?.preferredMIMEType ?? "image/png",
                                        data: data, mediaInfo: nil)
        }
    }

    func removeAvatar() {
        guard let room else { return }
        run { try await room.removeAvatar() }
    }

    func setBanner(data: Data) {
        guard target.isSpace else { return }
        run { [scope, target] in
            let type = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceGetType($0) as String? }
                .flatMap { UTType($0) }
            let mime = type?.preferredMIMEType ?? "image/png"
            guard try await scope.setSpaceBanner(spaceId: target.roomId,
                                                 data: data, mimeType: mime) != nil else {
                throw SettingsError.noPermission
            }
        }
    }

    func removeBanner() {
        guard target.isSpace else { return }
        run { [scope, target] in
            guard await scope.removeSpaceBanner(spaceId: target.roomId) else {
                throw SettingsError.noPermission
            }
        }
    }

    func setMainAddress() {
        guard let room else { return }
        var alias = newAlias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        if !alias.hasPrefix("#") { alias = "#" + alias }
        if !alias.contains(":") {
            let server = scope.userId.split(separator: ":").last.map(String.init) ?? ""
            alias += ":" + server
        }
        let finalAlias = alias
        run {
            // The server rejects a canonical alias that doesn't already map to the
            // room, so publish it first. A false result just means it already exists;
            // a truly conflicting alias fails at updateCanonicalAlias below.
            _ = try await room.publishRoomAliasInRoomDirectory(alias: finalAlias)
            try await room.updateCanonicalAlias(alias: finalAlias,
                                                altAliases: room.alternativeAliases())
            self.infoMessage = String(localized: "Main address set to \(finalAlias)")
            self.newAlias = ""
        }
    }

    func setDirectoryVisibility(_ visible: Bool) {
        guard let room else { return }
        run {
            try await room.updateRoomVisibility(visibility: visible ? .public : .private)
            if visible, let alias = self.canonicalAlias {
                _ = try? await room.publishRoomAliasInRoomDirectory(alias: alias)
            }
        }
    }

    func enableEncryption() {
        guard let room else { return }
        run { try await room.enableEncryption() }
    }

    func setJoinRule(_ choice: JoinRuleChoice) {
        guard let room else { return }
        let parents = parentSpaceIds
        run {
            let rule: JoinRule = switch choice {
            case .anyone: .public
            case .invite: .invite
            case .spaceMembers: .restricted(rules: parents.map { .roomMembership(roomId: $0) })
            }
            try await room.updateJoinRules(newRule: rule)
        }
    }

    func setHistoryVisibility(_ choice: HistoryChoice) {
        guard let room else { return }
        run {
            let visibility: RoomHistoryVisibility = switch choice {
            case .invited: .invited
            case .joined: .joined
            case .shared: .shared
            case .worldReadable: .worldReadable
            }
            try await room.updateHistoryVisibility(visibility: visibility)
        }
    }

    func setNotificationMode(_ choice: NotificationChoice) {
        run {
            let settings = await self.scope.service.client.getNotificationSettings()
            switch choice {
            case .default_:
                try await settings.restoreDefaultRoomNotificationMode(roomId: self.target.roomId)
            case .all:
                try await settings.setRoomNotificationMode(roomId: self.target.roomId, mode: .allMessages)
            case .mentions:
                try await settings.setRoomNotificationMode(roomId: self.target.roomId, mode: .mentionsAndKeywordsOnly)
            case .mute:
                try await settings.setRoomNotificationMode(roomId: self.target.roomId, mode: .mute)
            }
        }
    }

    func setUserLevel(userId: String, level: Int64) {
        guard let room else { return }
        run {
            try await room.updatePowerLevelsForUsers(updates: [
                UserPowerLevelUpdate(userId: userId, powerLevel: level)
            ])
        }
    }

    func applyPermissions(_ changes: RoomPowerLevelChanges) {
        guard let room else { return }
        run { try await room.applyPowerLevelChanges(changes: changes) }
    }

    /// Returns true on success. Not routed through run{}: its reload-on-success
    /// would fail once we've left the room.
    func leaveRoom() async -> Bool {
        guard let room else { return false }
        errorMessage = nil
        infoMessage = nil
        do {
            try await room.leave()
            if target.isSpace {
                await scope.roomList.selectSpace(nil)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Tabs

private enum SettingsError: LocalizedError {
    case noPermission
    var errorDescription: String? {
        String(localized: "You don't have permission to change this banner.")
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var model: RoomSettingsModel
    let dismiss: () -> Void
    /// One image picker for both avatar and banner, routed by target — two
    /// `.fileImporter`s in one subtree fault in SwiftUI.
    private enum ImageTarget { case avatar, banner }
    @State private var imageTarget: ImageTarget = .avatar
    @State private var showsImagePicker = false
    @State private var confirmingLeave = false

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        Text("General").font(.title2.weight(.semibold))
        if isSpace {
            Text("Edit your space's settings.")
                .font(.callout).foregroundStyle(.secondary)
        }

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if model.canEditBasics {
                    TextField(isSpace ? "Space name" : "Room name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                    TextField(isSpace ? "Description" : "Room topic", text: $model.topic, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("Save Changes") { model.saveNameAndTopic() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    LabeledContent(isSpace ? "Space name" : "Room name", value: model.name)
                    if !model.topic.isEmpty {
                        LabeledContent(isSpace ? "Description" : "Room topic", value: model.topic)
                    }
                }
            }
            VStack(spacing: 6) {
                RoomAvatarView(name: model.name, isDirect: false, size: 72,
                               avatarURL: model.avatarURL)
                if model.canEditBasics {
                    HStack(spacing: 6) {
                        Button("Change…") { imageTarget = .avatar; showsImagePicker = true }
                            .controlSize(.small)
                        if model.avatarURL != nil {
                            Button("Remove") { model.removeAvatar() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsImagePicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            switch imageTarget {
            case .avatar: model.setAvatar(data: data)
            case .banner: model.setBanner(data: data)
            }
        }

        if isSpace {
            Divider()

            Text("Banner").font(.headline)
            if let banner = model.bannerURL {
                BannerImageView(mxcUrl: banner)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if model.canEditBanner {
                HStack(spacing: 6) {
                    Button(model.bannerURL == nil ? "Add Banner…" : "Change Banner…") {
                        imageTarget = .banner; showsImagePicker = true
                    }
                    .controlSize(.small)
                    if model.bannerURL != nil {
                        Button("Remove", role: .destructive) { model.removeBanner() }
                            .controlSize(.small)
                    }
                }
                Text("Shown at the top of your space's home page.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Only space admins can change the banner.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if !isSpace {
            Divider()

            Text("Room Addresses").font(.headline)
            AddressesSection(model: model)
        }

        statusMessages(model)

        Divider()

        Button(isSpace ? "Leave Space…" : "Leave Room…", role: .destructive) { confirmingLeave = true }
            .confirmationDialog(isSpace ? "Leave this space?" : "Leave this room?",
                                isPresented: $confirmingLeave) {
                Button(isSpace ? "Leave Space" : "Leave Room", role: .destructive) {
                    Task { if await model.leaveRoom() { dismiss() } }
                }
            }
    }
}

/// Main-address + public-directory controls, shared by room General and space Visibility.
private struct AddressesSection: View {
    @Bindable var model: RoomSettingsModel

    var body: some View {
        if let alias = model.canonicalAlias {
            LabeledContent("Main address", value: alias)
        } else {
            Text(model.target.isSpace
                 ? "This space has no main address."
                 : "This room has no main address.")
                .foregroundStyle(.secondary)
        }
        if model.canEditAddresses {
            HStack {
                TextField(model.target.isSpace ? "#my-space" : "#my-room", text: $model.newAlias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.setMainAddress() }
                Button("Set Main Address") { model.setMainAddress() }
                    .disabled(model.newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle(model.target.isSpace
                   ? "Include this space in the public directory"
                   : "Include this room in the public room directory",
                   isOn: Binding(get: { model.isInDirectory },
                                 set: { model.setDirectoryVisibility($0) }))
        }
    }
}

private struct SecuritySettingsTab: View {
    @Bindable var model: RoomSettingsModel
    @State private var confirmingEncryption = false

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        Text(isSpace ? "Visibility" : "Security & Privacy").font(.title2.weight(.semibold))

        if !isSpace {
            Text("Encryption").font(.headline)
            if model.isEncrypted {
                Label("End-to-end encrypted", systemImage: "lock.fill")
                    .foregroundStyle(.green)
            } else if model.canEnableEncryption {
                Text("Once enabled, encryption cannot be disabled.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Enable Encryption…") { confirmingEncryption = true }
                    .confirmationDialog("Enable end-to-end encryption?",
                                        isPresented: $confirmingEncryption,
                                        titleVisibility: .visible) {
                        Button("Enable Encryption") { model.enableEncryption() }
                    } message: {
                        Text("This can't be undone — once enabled, encryption stays on for this room permanently.")
                    }
            } else {
                Text("This room is not encrypted.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
        }

        Text("Access").font(.headline)
        Text(isSpace
             ? "Decide who can view and join this space."
             : "Decide who can join this room.")
            .font(.callout).foregroundStyle(.secondary)
        if model.canEditAccess {
            Picker("Access", selection: Binding(get: { model.joinRule },
                                                set: { model.setJoinRule($0) })) {
                Label("Private (invite only)", systemImage: "lock").tag(RoomSettingsModel.JoinRuleChoice.invite)
                if !model.parentSpaceIds.isEmpty {
                    Label("Space members", systemImage: "person.2").tag(RoomSettingsModel.JoinRuleChoice.spaceMembers)
                }
                Label("Anyone", systemImage: "globe").tag(RoomSettingsModel.JoinRuleChoice.anyone)
            }
            .radioPickerStyle()
            .labelsHidden()
        } else {
            let rule = joinRuleDisplay(model.joinRule)
            Label(rule.title, systemImage: rule.icon)
        }

        Divider()

        if isSpace {
            // "Preview space" == world-readable history.
            if model.canEditAccess {
                Toggle(isOn: Binding(
                    get: { model.historyVisibility == .worldReadable },
                    set: { model.setHistoryVisibility($0 ? .worldReadable : .shared) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview space")
                        Text("Allow people to preview the space before joining. Recommended for public spaces.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Preview space") {
                    Text(model.historyVisibility == .worldReadable ? "On" : "Off")
                }
            }

            Divider()

            Text("Space Addresses").font(.headline)
            AddressesSection(model: model)
        } else {
            Text("Who can read history?").font(.headline)
            if model.canEditAccess {
                Text("Changes only apply to new messages.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("History", selection: Binding(get: { model.historyVisibility },
                                                     set: { model.setHistoryVisibility($0) })) {
                    Text("Members only (since they were invited)").tag(RoomSettingsModel.HistoryChoice.invited)
                    Text("Members only (since they joined)").tag(RoomSettingsModel.HistoryChoice.joined)
                    Text("Members only (since this option was selected)").tag(RoomSettingsModel.HistoryChoice.shared)
                    Text("Anyone").tag(RoomSettingsModel.HistoryChoice.worldReadable)
                }
                .radioPickerStyle()
                .labelsHidden()
            } else {
                Text(historyDisplay(model.historyVisibility))
            }
        }

        statusMessages(model)
    }
}

private struct RolesSettingsTab: View {
    @Bindable var model: RoomSettingsModel
    @State private var newUserId = ""
    @State private var newUserLevel: Int64 = 50

    private static let roleOptions: [(String, Int64)] = [
        ("Default", 0), ("Moderator", 50), ("Administrator", 100),
    ]

    var body: some View {
        Text("Roles & Permissions").font(.title2.weight(.semibold))

        Text("Privileged users").font(.headline)
        if model.privilegedUsers.isEmpty {
            Text("No privileged users.")
                .foregroundStyle(.secondary)
        }
        ForEach(model.privilegedUsers, id: \.userId) { user in
            LabeledContent(user.userId) {
                if model.canEditRoles {
                    Picker("", selection: Binding(
                        get: { user.level },
                        set: { model.setUserLevel(userId: user.userId, level: $0) }
                    )) {
                        ForEach(Self.roleOptions, id: \.1) { name, level in
                            Text(verbatim: name).tag(level)
                        }
                        if !Self.roleOptions.contains(where: { $0.1 == user.level }) {
                            Text("Custom (\(user.level))").tag(user.level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                } else {
                    Text(verbatim: roleName(forLevel: user.level))
                }
            }
        }

        if model.canEditRoles {
            Text("Add privileged user").font(.headline)
            HStack {
                TextField("@user:server", text: $newUserId)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newUserLevel) {
                    ForEach(Self.roleOptions, id: \.1) { name, level in
                        Text(verbatim: name).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("Apply") {
                    model.setUserLevel(userId: newUserId.trimmingCharacters(in: .whitespaces),
                                       level: newUserLevel)
                    newUserId = ""
                }
                .disabled(!newUserId.hasPrefix("@"))
            }
        }

        if model.canEditRoles {
            Divider()
            RoleLabelsEditor(model: model)
        }

        Divider()

        Text("Permissions").font(.headline)
        if model.canEditRoles {
            Text("Choose the role required for each action.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("The role required for each action.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let values = model.permissionValues {
            PermissionsGrid(model: model, values: values)
        }

        statusMessages(model)
    }
}

/// Names, colors, and emoji for each power level — writes the Cinny-compatible
/// `in.cinny.room.power_level_tags` event.
private struct RoleLabelsEditor: View {
    @Bindable var model: RoomSettingsModel
    @State private var emojiLevel: Int?

    private static let palette = ["#e64980", "#f76707", "#f59f00", "#37b24d",
                                  "#1c7ed6", "#7048e8", "#ae3ec9", "#868e96"]

    private var levels: [Int] {
        var set = Set([0, 50, 100])
        set.formUnion(model.privilegedUsers.map { Int($0.level) })
        set.formUnion(model.powerLevelTags.keys)
        return set.sorted(by: >)
    }

    private func tag(_ level: Int) -> Binding<PowerLevelTag> {
        Binding(get: { model.roleTag(forLevel: level) },
                set: { model.powerLevelTags[level] = $0 })
    }

    var body: some View {
        Text("Role labels").font(.headline)
        Text("Name, color, and emoji per power level. Names and colors interop with Cinny.")
            .font(.callout).foregroundStyle(.secondary)

        ForEach(levels, id: \.self) { level in
            let binding = tag(level)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { emojiLevel = level } label: {
                        iconPreview(binding.wrappedValue)
                            .frame(width: 26, height: 26)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { emojiLevel == level },
                                                  set: { if !$0 { emojiLevel = nil } })) {
                        EmojiPickerView(
                            customPacks: model.scope.customEmoji.packs,
                            loader: model.scope.mediaLoader,
                            insertCustom: { emote in
                                binding.wrappedValue.iconKey = emote.url
                                emojiLevel = nil
                            },
                            insert: { emoji in
                                binding.wrappedValue.iconKey = emoji
                                emojiLevel = nil
                            })
                        .frame(width: 320, height: 360)
                    }
                    TextField("Level \(level)", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                    Text(verbatim: "\(level)").foregroundStyle(.tertiary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    ForEach(Self.palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.primary,
                                     lineWidth: binding.wrappedValue.color == hex ? 2 : 0))
                            .onTapGesture { binding.wrappedValue.color = hex }
                    }
                    Button { binding.wrappedValue.color = nil } label: {
                        Image(systemName: "slash.circle")
                    }
                    .buttonStyle(.plain)
                    .help("No color")
                }
            }
        }

        Button("Save labels") { model.savePowerLevelTags() }
    }

    @ViewBuilder
    private func iconPreview(_ tag: PowerLevelTag) -> some View {
        if let key = tag.iconKey, !key.isEmpty {
            if tag.iconIsMxc {
                EmoteImageView(url: key, size: 22, loader: model.scope.mediaLoader)
            } else {
                Text(key)
            }
        } else {
            Image(systemName: "face.smiling").foregroundStyle(.secondary)
        }
    }
}

private struct PermissionsGrid: View {
    let model: RoomSettingsModel
    let values: RoomPowerLevelsValues

    private var rows: [(LocalizedStringKey, Int64, (Int64) -> RoomPowerLevelChanges)] {
        let isSpace = model.target.isSpace
        return [
            ("Default role", values.usersDefault, { RoomPowerLevelChanges(usersDefault: $0) }),
            ("Send messages", values.eventsDefault, { RoomPowerLevelChanges(eventsDefault: $0) }),
            ("Invite users", values.invite, { RoomPowerLevelChanges(invite: $0) }),
            ("Change settings", values.stateDefault, { RoomPowerLevelChanges(stateDefault: $0) }),
            ("Remove users", values.kick, { RoomPowerLevelChanges(kick: $0) }),
            ("Ban users", values.ban, { RoomPowerLevelChanges(ban: $0) }),
            ("Remove messages sent by others", values.redact, { RoomPowerLevelChanges(redact: $0) }),
            (isSpace ? "Change space name" : "Change room name",
             values.roomName, { RoomPowerLevelChanges(roomName: $0) }),
            (isSpace ? "Change space avatar" : "Change room avatar",
             values.roomAvatar, { RoomPowerLevelChanges(roomAvatar: $0) }),
            (isSpace ? "Change description" : "Change topic",
             values.roomTopic, { RoomPowerLevelChanges(roomTopic: $0) }),
        ]
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            LabeledContent {
                if model.canEditRoles {
                    Picker("", selection: Binding(
                        get: { row.1 },
                        set: { model.applyPermissions(row.2($0)) }
                    )) {
                        Text("Default").tag(Int64(0))
                        Text("Moderator").tag(Int64(50))
                        Text("Administrator").tag(Int64(100))
                        if ![0, 50, 100].contains(row.1) {
                            Text("Custom (\(row.1))").tag(row.1)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                } else {
                    Text(verbatim: roleName(forLevel: row.1))
                }
            } label: {
                Text(row.0)
            }
        }
    }
}

private struct NotificationSettingsTab: View {
    @Bindable var model: RoomSettingsModel

    var body: some View {
        Text("Notifications").font(.title2.weight(.semibold))

        Picker("Mode", selection: Binding(get: { model.notificationMode },
                                          set: { model.setNotificationMode($0) })) {
            Text("Default — follow your global settings").tag(RoomSettingsModel.NotificationChoice.default_)
            Text("All messages").tag(RoomSettingsModel.NotificationChoice.all)
            Text("@mentions and keywords only").tag(RoomSettingsModel.NotificationChoice.mentions)
            Text("Off").tag(RoomSettingsModel.NotificationChoice.mute)
        }
        .radioPickerStyle()
        .labelsHidden()

        statusMessages(model)
    }
}

private struct PollHistoryTab: View {
    let model: RoomSettingsModel

    private var polls: [(message: MessageItem, poll: PollItem)] {
        guard let timeline = model.scope.timeline(forRoomId: model.target.roomId) else { return [] }
        return timeline.entries.compactMap { entry in
            if case .message(let message) = entry, case .poll(let poll) = message.kind {
                return (message, poll)
            }
            return nil
        }
        .reversed()
    }

    var body: some View {
        Text("Poll History").font(.title2.weight(.semibold))
            .onDisappear { parkPollTimelineIfInactive(model) }
        Text("Polls from the loaded timeline history.")
            .font(.callout).foregroundStyle(.secondary)

        let all = polls
        if all.isEmpty {
            Text("No polls found in the loaded history.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(all, id: \.message.id) { item in
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(item.poll.isEnded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.poll.question)
                        Text("\(item.message.timestamp, format: .dateTime.day().month().year()) — \(item.poll.isEnded ? String(localized: "Ended") : String(localized: "Active")) — ^[\(item.poll.totalVotes) vote](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct AdvancedSettingsTab: View {
    let model: RoomSettingsModel

    var body: some View {
        Text("Advanced").font(.title2.weight(.semibold))

        Text(model.target.isSpace ? "Space information" : "Room information").font(.headline)
        LabeledContent(model.target.isSpace ? "Internal space ID" : "Internal room ID") {
            HStack(spacing: 4) {
                Text(model.target.roomId)
                    .font(.caption)
                    .textSelection(.enabled)
                Button {
                    Platform.copyToClipboard(model.target.roomId)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        LabeledContent("Room version", value: model.roomVersion)
        LabeledContent("Members", value: String(model.memberCount))
    }
}

/// Poll history materializes the room's timeline view model just to read entries.
/// Park it on the way out so LRU eviction can reclaim it; the actively open room
/// is exempt (navigation owns its parking).
@MainActor
private func parkPollTimelineIfInactive(_ model: RoomSettingsModel) {
    guard model.scope.roomList.activeRoomId != model.target.roomId else { return }
    model.scope.timeline(forRoomId: model.target.roomId)?.isParked = true
}

// MARK: - Read-only display helpers

/// Title + icon for a join-rule choice, for the read-only (no-permission) case.
private func joinRuleDisplay(_ choice: RoomSettingsModel.JoinRuleChoice)
    -> (title: LocalizedStringKey, icon: String) {
    switch choice {
    case .invite: ("Private (invite only)", "lock")
    case .spaceMembers: ("Space members", "person.2")
    case .anyone: ("Anyone", "globe")
    }
}

private func historyDisplay(_ choice: RoomSettingsModel.HistoryChoice) -> LocalizedStringKey {
    switch choice {
    case .invited: "Members only (since they were invited)"
    case .joined: "Members only (since they joined)"
    case .shared: "Members only (since this option was selected)"
    case .worldReadable: "Anyone"
    }
}

private func roleName(forLevel level: Int64) -> String {
    switch level {
    case 0: String(localized: "Default")
    case 50: String(localized: "Moderator")
    case 100: String(localized: "Administrator")
    default: String(localized: "Custom (\(level))")
    }
}

@MainActor
@ViewBuilder
private func statusMessages(_ model: RoomSettingsModel) -> some View {
    if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(.red)
    }
    if let info = model.infoMessage {
        Text(info).font(.callout).foregroundStyle(.green)
    }
}

// MARK: - iOS forms

#if os(iOS)

/// Error/info feedback as its own section, only when present.
@MainActor
@ViewBuilder
private func statusSectioniOS(_ model: RoomSettingsModel) -> some View {
    if model.errorMessage != nil || model.infoMessage != nil {
        Section {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if let info = model.infoMessage {
                Text(info).foregroundStyle(.green)
            }
        }
    }
}

private struct RoomSettingsFormiOS: View {
    @Bindable var model: RoomSettingsModel
    let dismiss: () -> Void
    @State private var showsAvatarPicker = false
    @State private var confirmingLeave = false

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    RoomAvatarView(name: model.name, isDirect: false, size: 72,
                                   avatarURL: model.avatarURL)
                    if model.canEditBasics {
                        HStack(spacing: 24) {
                            Button("Choose Photo") { showsAvatarPicker = true }
                            if model.avatarURL != nil {
                                Button("Remove Photo", role: .destructive) { model.removeAvatar() }
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                if model.canEditBasics {
                    TextField(isSpace ? "Space name" : "Room name", text: $model.name)
                    TextField(isSpace ? "Description" : "Room topic", text: $model.topic, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Save Changes") { model.saveNameAndTopic() }
                        .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    LabeledContent(isSpace ? "Space name" : "Room name") {
                        Text(model.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !model.topic.isEmpty {
                        LabeledContent(isSpace ? "Description" : "Room topic") {
                            Text(model.topic)
                        }
                    }
                }
            } footer: {
                if model.canEditBasics {
                    Text("Name and topic changes apply when you save. All other settings apply immediately.")
                }
            }

            if !isSpace {
                AddressSectioniOS(model: model)
            }

            Section {
                ForEach(RoomSettingsSheet.Tab.cases(isSpace: isSpace).filter { $0 != .general }) { tab in
                    NavigationLink {
                        detail(for: tab)
                    } label: {
                        Label(tab.title(isSpace: isSpace),
                              systemImage: tab.icon(isSpace: isSpace))
                    }
                }
            }

            statusSectioniOS(model)

            Section {
                Button(isSpace ? "Leave Space" : "Leave Room", role: .destructive) {
                    confirmingLeave = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(isPresented: $showsAvatarPicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                model.setAvatar(data: data)
            }
        }
        .confirmationDialog(isSpace ? "Leave this space?" : "Leave this room?",
                            isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button(isSpace ? "Leave Space" : "Leave Room", role: .destructive) {
                Task { if await model.leaveRoom() { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func detail(for tab: RoomSettingsSheet.Tab) -> some View {
        Group {
            switch tab {
            case .general:
                EmptyView()
            case .security:
                SecurityFormiOS(model: model)
            case .roles:
                RolesFormiOS(model: model)
            case .emotes:
                EmotePackEditor(model: model)
            case .notifications:
                NotificationsFormiOS(model: model)
            case .polls:
                PollHistoryFormiOS(model: model)
            case .advanced:
                AdvancedFormiOS(model: model)
            }
        }
        .navigationTitle(Text(tab.title(isSpace: isSpace)))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Main-address + public-directory controls, shared by the room root form and space Visibility.
private struct AddressSectioniOS: View {
    @Bindable var model: RoomSettingsModel

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        // With no edit rights and no main address there is nothing to show.
        if model.canEditAddresses || model.canonicalAlias != nil {
            Section {
                if let alias = model.canonicalAlias {
                    LabeledContent("Main address") {
                        Text(alias)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.canEditAddresses {
                    TextField(isSpace ? "#my-space" : "#my-room", text: $model.newAlias)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .onSubmit { model.setMainAddress() }
                    Button("Set Main Address") { model.setMainAddress() }
                        .disabled(model.newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                    Toggle(isSpace
                           ? "Include this space in the public directory"
                           : "Include this room in the public room directory",
                           isOn: Binding(get: { model.isInDirectory },
                                         set: { model.setDirectoryVisibility($0) }))
                }
            } header: {
                Text(isSpace ? "Space Address" : "Room Address")
            } footer: {
                if model.canonicalAlias == nil {
                    Text(isSpace
                         ? "This space has no main address."
                         : "This room has no main address.")
                }
            }
        }
    }
}

private struct SecurityFormiOS: View {
    @Bindable var model: RoomSettingsModel
    @State private var confirmingEncryption = false

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        Form {
            if !isSpace {
                Section {
                    if model.isEncrypted {
                        Label("End-to-end encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    } else if model.canEnableEncryption {
                        Button("Enable Encryption…") { confirmingEncryption = true }
                            .confirmationDialog("Enable end-to-end encryption?",
                                                isPresented: $confirmingEncryption,
                                                titleVisibility: .visible) {
                                Button("Enable Encryption") { model.enableEncryption() }
                            } message: {
                                Text("This can't be undone — once enabled, encryption stays on for this room permanently.")
                            }
                    } else {
                        Text("This room is not encrypted.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Encryption")
                } footer: {
                    if !model.isEncrypted && model.canEnableEncryption {
                        Text("Once enabled, encryption cannot be disabled.")
                    }
                }
            }

            Section {
                if model.canEditAccess {
                    Picker("Access", selection: Binding(get: { model.joinRule },
                                                        set: { model.setJoinRule($0) })) {
                        Label("Private (invite only)", systemImage: "lock")
                            .tag(RoomSettingsModel.JoinRuleChoice.invite)
                        if !model.parentSpaceIds.isEmpty {
                            Label("Space members", systemImage: "person.2")
                                .tag(RoomSettingsModel.JoinRuleChoice.spaceMembers)
                        }
                        Label("Anyone", systemImage: "globe")
                            .tag(RoomSettingsModel.JoinRuleChoice.anyone)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } else {
                    let rule = joinRuleDisplay(model.joinRule)
                    Label(rule.title, systemImage: rule.icon)
                }
            } header: {
                Text("Access")
            } footer: {
                Text(isSpace
                     ? "Decide who can view and join this space."
                     : "Decide who can join this room.")
            }

            if isSpace {
                // "Preview space" == world-readable history.
                Section {
                    if model.canEditAccess {
                        Toggle("Preview space", isOn: Binding(
                            get: { model.historyVisibility == .worldReadable },
                            set: { model.setHistoryVisibility($0 ? .worldReadable : .shared) }
                        ))
                    } else {
                        LabeledContent("Preview space") {
                            Text(model.historyVisibility == .worldReadable ? "On" : "Off")
                        }
                    }
                } footer: {
                    Text("Allow people to preview the space before joining. Recommended for public spaces.")
                }

                AddressSectioniOS(model: model)
            } else {
                Section {
                    if model.canEditAccess {
                        Picker("History", selection: Binding(get: { model.historyVisibility },
                                                             set: { model.setHistoryVisibility($0) })) {
                            Text("Members only (since they were invited)")
                                .tag(RoomSettingsModel.HistoryChoice.invited)
                            Text("Members only (since they joined)")
                                .tag(RoomSettingsModel.HistoryChoice.joined)
                            Text("Members only (since this option was selected)")
                                .tag(RoomSettingsModel.HistoryChoice.shared)
                            Text("Anyone")
                                .tag(RoomSettingsModel.HistoryChoice.worldReadable)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } else {
                        Text(historyDisplay(model.historyVisibility))
                    }
                } header: {
                    Text("Who Can Read History")
                } footer: {
                    if model.canEditAccess {
                        Text("Changes only apply to new messages.")
                    }
                }
            }

            statusSectioniOS(model)
        }
    }
}

private struct RolesFormiOS: View {
    @Bindable var model: RoomSettingsModel
    @State private var newUserId = ""
    @State private var newUserLevel: Int64 = 50

    private static let roleOptions: [(String, Int64)] = [
        ("Default", 0), ("Moderator", 50), ("Administrator", 100),
    ]

    var body: some View {
        Form {
            Section("Privileged Users") {
                if model.privilegedUsers.isEmpty {
                    Text("No privileged users.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.privilegedUsers, id: \.userId) { user in
                    if model.canEditRoles {
                        Picker(selection: Binding(
                            get: { user.level },
                            set: { model.setUserLevel(userId: user.userId, level: $0) }
                        )) {
                            ForEach(Self.roleOptions, id: \.1) { name, level in
                                Text(verbatim: name).tag(level)
                            }
                            if !Self.roleOptions.contains(where: { $0.1 == user.level }) {
                                Text("Custom (\(user.level))").tag(user.level)
                            }
                        } label: {
                            Text(user.userId)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        LabeledContent {
                            Text(verbatim: roleName(forLevel: user.level))
                        } label: {
                            Text(user.userId)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            if model.canEditRoles {
                Section("Add Privileged User") {
                    TextField("@user:server", text: $newUserId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    Picker("Role", selection: $newUserLevel) {
                        ForEach(Self.roleOptions, id: \.1) { name, level in
                            Text(verbatim: name).tag(level)
                        }
                    }
                    Button("Add") {
                        model.setUserLevel(userId: newUserId.trimmingCharacters(in: .whitespaces),
                                           level: newUserLevel)
                        newUserId = ""
                    }
                    .disabled(!newUserId.hasPrefix("@"))
                }
            }

            Section {
                if let values = model.permissionValues {
                    PermissionRowsiOS(model: model, values: values)
                }
            } header: {
                Text("Permissions")
            } footer: {
                if model.canEditRoles {
                    Text("Choose the role required for each action.")
                } else {
                    Text("The role required for each action.")
                }
            }

            statusSectioniOS(model)
        }
    }
}

private struct PermissionRowsiOS: View {
    let model: RoomSettingsModel
    let values: RoomPowerLevelsValues

    private var rows: [(LocalizedStringKey, Int64, (Int64) -> RoomPowerLevelChanges)] {
        let isSpace = model.target.isSpace
        return [
            ("Default role", values.usersDefault, { RoomPowerLevelChanges(usersDefault: $0) }),
            ("Send messages", values.eventsDefault, { RoomPowerLevelChanges(eventsDefault: $0) }),
            ("Invite users", values.invite, { RoomPowerLevelChanges(invite: $0) }),
            ("Change settings", values.stateDefault, { RoomPowerLevelChanges(stateDefault: $0) }),
            ("Remove users", values.kick, { RoomPowerLevelChanges(kick: $0) }),
            ("Ban users", values.ban, { RoomPowerLevelChanges(ban: $0) }),
            ("Remove messages sent by others", values.redact, { RoomPowerLevelChanges(redact: $0) }),
            (isSpace ? "Change space name" : "Change room name",
             values.roomName, { RoomPowerLevelChanges(roomName: $0) }),
            (isSpace ? "Change space avatar" : "Change room avatar",
             values.roomAvatar, { RoomPowerLevelChanges(roomAvatar: $0) }),
            (isSpace ? "Change description" : "Change topic",
             values.roomTopic, { RoomPowerLevelChanges(roomTopic: $0) }),
        ]
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if model.canEditRoles {
                Picker(selection: Binding(
                    get: { row.1 },
                    set: { model.applyPermissions(row.2($0)) }
                )) {
                    Text("Default").tag(Int64(0))
                    Text("Moderator").tag(Int64(50))
                    Text("Administrator").tag(Int64(100))
                    if ![0, 50, 100].contains(row.1) {
                        Text("Custom (\(row.1))").tag(row.1)
                    }
                } label: {
                    Text(row.0)
                }
            } else {
                LabeledContent {
                    Text(verbatim: roleName(forLevel: row.1))
                } label: {
                    Text(row.0)
                }
            }
        }
    }
}

private struct NotificationsFormiOS: View {
    @Bindable var model: RoomSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(get: { model.notificationMode },
                                                  set: { model.setNotificationMode($0) })) {
                    Text("Default — follow your global settings")
                        .tag(RoomSettingsModel.NotificationChoice.default_)
                    Text("All messages")
                        .tag(RoomSettingsModel.NotificationChoice.all)
                    Text("@mentions and keywords only")
                        .tag(RoomSettingsModel.NotificationChoice.mentions)
                    Text("Off")
                        .tag(RoomSettingsModel.NotificationChoice.mute)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            statusSectioniOS(model)
        }
    }
}

private struct PollHistoryFormiOS: View {
    let model: RoomSettingsModel

    private var polls: [(message: MessageItem, poll: PollItem)] {
        guard let timeline = model.scope.timeline(forRoomId: model.target.roomId) else { return [] }
        return timeline.entries.compactMap { entry in
            if case .message(let message) = entry, case .poll(let poll) = message.kind {
                return (message, poll)
            }
            return nil
        }
        .reversed()
    }

    var body: some View {
        Form {
            let all = polls
            Section {
                if all.isEmpty {
                    Text("No polls found in the loaded history.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(all, id: \.message.id) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "chart.bar.xaxis")
                                .foregroundStyle(item.poll.isEnded ? AnyShapeStyle(.secondary)
                                                                   : AnyShapeStyle(.tint))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.poll.question)
                                Text("\(item.message.timestamp, format: .dateTime.day().month().year()) — \(item.poll.isEnded ? String(localized: "Ended") : String(localized: "Active")) — ^[\(item.poll.totalVotes) vote](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Polls from the loaded timeline history.")
            }
        }
        .onDisappear { parkPollTimelineIfInactive(model) }
    }
}

private struct AdvancedFormiOS: View {
    let model: RoomSettingsModel

    private var isSpace: Bool { model.target.isSpace }

    var body: some View {
        Form {
            Section(isSpace ? "Space Information" : "Room Information") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSpace ? "Internal space ID" : "Internal room ID")
                    Text(model.target.roomId)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        Platform.copyToClipboard(model.target.roomId)
                    }
                }
                LabeledContent("Room version", value: model.roomVersion)
                LabeledContent("Members", value: String(model.memberCount))
            }
        }
    }
}

#endif
