import SwiftUI

enum NewChatSheet: Identifiable {
    case directMessage
    /// Optionally filed straight into a space.
    case room(spaceId: String?)
    /// Video room, optionally filed into a space.
    case videoRoom(spaceId: String?)
    case space
    case join

    var id: String {
        switch self {
        case .directMessage: "dm"
        case .room(let spaceId): "room-\(spaceId ?? "home")"
        case .videoRoom(let spaceId): "video-\(spaceId ?? "home")"
        case .space: "space"
        case .join: "join"
        }
    }
}

// MARK: - Invite to room / space

/// Search the directory and invite users into a room or space.
struct InviteSheet: View {
    let scope: SessionScope
    let roomId: String
    let roomName: String
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MatrixService.UserHit] = []
    @State private var isSearching = false
    @State private var invited: Set<String> = []
    @State private var busy: Set<String> = []
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        SheetChrome(title: String(localized: "Invite to \(roomName)"),
                    systemImage: "person.badge.plus",
                    // Once invites have gone out, Cancel gives way to a bold Done.
                    isCommitted: !invited.isEmpty) {
            #if os(iOS)
            Section("To") {
                TextField("Name or @user:server", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in search(newValue) }
                    // Search key skips the debounce.
                    .onSubmit { search(query, immediate: true) }
            }

            if isSearching || !results.isEmpty || hasDirectEntry {
                Section("Results") {
                    if isSearching, results.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    ForEach(results) { user in
                        HStack(spacing: 12) {
                            RoomAvatarView(name: user.name, isDirect: true, size: 40,
                                           avatarURL: user.avatarURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).lineLimit(1)
                                Text(user.id)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            inviteButton(userId: user.id)
                                .buttonStyle(.borderless)
                        }
                    }
                    // Full user IDs directory search may miss.
                    if hasDirectEntry {
                        HStack {
                            Text(query).lineLimit(1)
                            Spacer()
                            inviteButton(userId: directEntryUserId ?? query.trimmingCharacters(in: .whitespaces))
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            #else
            TextField("Search by name or @user:server", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, newValue in search(newValue) }

            if isSearching {
                ProgressView().controlSize(.small)
            }

            VStack(spacing: 2) {
                ForEach(results) { user in
                    HStack(spacing: 8) {
                        RoomAvatarView(name: user.name, isDirect: true, size: 26,
                                       avatarURL: user.avatarURL)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(user.name).lineLimit(1)
                            Text(user.id).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        inviteButton(userId: user.id)
                    }
                    .padding(6)
                }
            }

            // Full user IDs directory search may miss.
            if hasDirectEntry {
                HStack {
                    Text(query).lineLimit(1)
                    Spacer()
                    inviteButton(userId: directEntryUserId ?? query.trimmingCharacters(in: .whitespaces))
                }
                .padding(6)
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// A typed user id, normalized: `user:server` is accepted and the leading
    /// `@` added, so you don't have to type it. nil if it doesn't look like one.
    private var directEntryUserId: String? {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard raw.contains(":"), !raw.contains(" ") else { return nil }
        return raw.hasPrefix("@") ? raw : "@\(raw)"
    }

    private var hasDirectEntry: Bool { directEntryUserId != nil }

    /// Debounced directory search; `immediate` skips the debounce (keyboard
    /// Search key), running the query right away.
    private func search(_ newValue: String, immediate: Bool = false) {
        searchTask?.cancel()
        let term = newValue.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            // searchUsers doesn't observe cancellation; guard before publishing
            // so a superseded query's stale hits don't overwrite newer results.
            let hits = await scope.service.searchUsers(query: term)
            guard !Task.isCancelled else { return }
            results = hits
            isSearching = false
        }
    }

    @ViewBuilder
    private func inviteButton(userId: String) -> some View {
        if invited.contains(userId) {
            Label("Invited", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Invited \(userId)"))
        } else {
            Button("Invite") { invite(userId) }
                .controlSize(.small)
                .disabled(busy.contains(userId))
                .accessibilityLabel(Text("Invite \(userId)"))
        }
    }

    private func invite(_ userId: String) {
        guard let room = scope.roomList.ffiRoom(withId: roomId) else { return }
        busy.insert(userId)
        errorMessage = nil
        Task {
            defer { busy.remove(userId) }
            do {
                try await room.inviteUserById(userId: userId)
                invited.insert(userId)
            } catch {
                errorMessage = String(localized: "Couldn't invite \(userId): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - New DM

struct NewDirectMessageSheet: View {
    let scope: SessionScope
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MatrixService.UserHit] = []
    @State private var isSearching = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        SheetChrome(title: String(localized: "New Message"), systemImage: "square.and.pencil") {
            #if os(iOS)
            Section("To") {
                TextField("Name or @user:server", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in search(newValue) }
                    // Search key skips the debounce.
                    .onSubmit { search(query, immediate: true) }
            }

            if isSearching || !results.isEmpty || hasDirectEntry {
                Section("Results") {
                    if isSearching, results.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    ForEach(results) { user in
                        Button {
                            startDm(with: user.id)
                        } label: {
                            HStack(spacing: 12) {
                                RoomAvatarView(name: user.name, isDirect: true, size: 40,
                                               avatarURL: user.avatarURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(user.id)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .disabled(isCreating)
                    }
                    // Full user IDs directory search may miss.
                    if hasDirectEntry {
                        Button("Message \(query)") {
                            startDm(with: directEntryUserId ?? query.trimmingCharacters(in: .whitespaces))
                        }
                        .disabled(isCreating)
                    }
                }
            }

            if isCreating {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Starting chat…").foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            #else
            TextField("Search by name or @user:server", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, newValue in search(newValue) }

            if isSearching {
                ProgressView().controlSize(.small)
            }

            VStack(spacing: 2) {
                ForEach(results) { user in
                    Button {
                        startDm(with: user.id)
                    } label: {
                        HStack(spacing: 8) {
                            RoomAvatarView(name: user.name, isDirect: true, size: 26,
                                           avatarURL: user.avatarURL)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(user.name).lineLimit(1)
                                Text(user.id).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Full user IDs directory search may miss.
            if hasDirectEntry {
                Button("Message \(query)") {
                    startDm(with: directEntryUserId ?? query.trimmingCharacters(in: .whitespaces))
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            if isCreating {
                ProgressView().controlSize(.small)
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// A typed user id, normalized: `user:server` is accepted and the leading
    /// `@` added, so you don't have to type it. nil if it doesn't look like one.
    private var directEntryUserId: String? {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard raw.contains(":"), !raw.contains(" ") else { return nil }
        return raw.hasPrefix("@") ? raw : "@\(raw)"
    }

    private var hasDirectEntry: Bool { directEntryUserId != nil }

    /// Debounced directory search; `immediate` skips the debounce (keyboard
    /// Search key), running the query right away.
    private func search(_ newValue: String, immediate: Bool = false) {
        searchTask?.cancel()
        let term = newValue.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            // searchUsers doesn't observe cancellation; guard before publishing
            // so a superseded query's stale hits don't overwrite newer results.
            let hits = await scope.service.searchUsers(query: term)
            guard !Task.isCancelled else { return }
            results = hits
            isSearching = false
        }
    }

    private func startDm(with userId: String) {
        guard !isCreating else { return }
        isCreating = true
        Task {
            do {
                let roomId = try await scope.service.startDm(userId: userId)
                open(roomId)
                dismiss()
            } catch {
                errorMessage = String(localized: "Couldn't start the conversation: \(error.localizedDescription)")
                isCreating = false
            }
        }
    }
}

// MARK: - New room / space

struct NewRoomSheet: View {
    enum Visibility: Hashable {
        case spaceMembers, privateRoom, publicRoom
    }

    let scope: SessionScope
    let isSpace: Bool
    /// When set, the created room is filed into this space.
    var destinationSpaceId: String? = nil
    /// A sub-space acting as a category; changes labels only.
    var isSection: Bool = false
    var isVideoRoom: Bool = false
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var topic = ""
    @State private var visibility: Visibility = .privateRoom
    @State private var isEncrypted = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(scope: SessionScope, isSpace: Bool, destinationSpaceId: String? = nil,
         isSection: Bool = false, isVideoRoom: Bool = false, open: @escaping (String) -> Void) {
        self.scope = scope
        self.isSpace = isSpace
        self.destinationSpaceId = destinationSpaceId
        self.isSection = isSection
        self.isVideoRoom = isVideoRoom
        self.open = open
        // Inside a space, default to "visible to space members".
        _visibility = State(initialValue: destinationSpaceId != nil ? .spaceMembers : .privateRoom)
    }

    var body: some View {
        SheetChrome(title: isSection ? String(localized: "New Section")
                        : isSpace ? String(localized: "New Space")
                        : isVideoRoom ? String(localized: "New Video Room")
                        : String(localized: "New Room"),
                    systemImage: isSection ? "folder" : isSpace ? "square.grid.2x2"
                        : isVideoRoom ? "video" : "number",
                    primaryTitle: isCreating ? String(localized: "Creating…")
                        : String(localized: "Create"),
                    primaryDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating,
                    primaryAction: create) {
            #if os(iOS)
            Section {
                TextField("Name", text: $name)
                TextField("Topic (optional)", text: $topic)
            }

            Section("Visibility") {
                Picker("Visibility", selection: $visibility) {
                    if destinationSpaceId != nil {
                        Label("Visible to space members", systemImage: "person.2")
                            .tag(Visibility.spaceMembers)
                    }
                    Label(isSpace ? "Private (invite only)" : "Private room (invite only)",
                          systemImage: "lock")
                        .tag(Visibility.privateRoom)
                    Label(isSpace ? "Public" : "Public room", systemImage: "globe")
                        .tag(Visibility.publicRoom)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if !isSpace && !isVideoRoom {
                Section {
                    Toggle("End-to-end encrypted", isOn: encryptionToggle)
                        .disabled(visibility == .publicRoom)
                } footer: {
                    Text("Encryption can't be turned off later. Public rooms can't be encrypted.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            #else
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Topic (optional)", text: $topic)
                    .textFieldStyle(.roundedBorder)

                Picker("Visibility", selection: $visibility) {
                    if destinationSpaceId != nil {
                        Label("Visible to space members", systemImage: "person.2")
                            .tag(Visibility.spaceMembers)
                    }
                    Label(isSpace ? "Private (invite only)" : "Private room (invite only)",
                          systemImage: "lock")
                        .tag(Visibility.privateRoom)
                    Label(isSpace ? "Public" : "Public room", systemImage: "globe")
                        .tag(Visibility.publicRoom)
                }
                .labelsHidden()

                if !isSpace && !isVideoRoom {
                    Toggle("End-to-end encrypted", isOn: encryptionToggle)
                        .disabled(visibility == .publicRoom)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            // iOS gets these in the nav bar via SheetChrome.
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isCreating ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// Public rooms can't be encrypted, but `isEncrypted` intent is preserved so
    /// Public→Private restores it. Shown off + disabled while public; effective
    /// encryption is derived at create time.
    private var encryptionToggle: Binding<Bool> {
        Binding(
            get: { visibility != .publicRoom && isEncrypted },
            set: { isEncrypted = $0 }
        )
    }

    private func create() {
        isCreating = true
        Task {
            do {
                let serviceVisibility: MatrixService.NewRoomVisibility = switch visibility {
                case .spaceMembers: .spaceMembers(spaceId: destinationSpaceId ?? "")
                case .privateRoom: .privateRoom
                case .publicRoom: .publicRoom
                }
                let roomId: String
                if isVideoRoom {
                    roomId = try await scope.service.createVideoRoom(
                        name: name.trimmingCharacters(in: .whitespaces),
                        topic: topic,
                        visibility: serviceVisibility
                    )
                    // Flag it locally now; space listings only refresh later.
                    scope.roomList.noteVideoRoom(roomId)
                } else {
                    roomId = try await scope.service.createRoom(
                        name: name.trimmingCharacters(in: .whitespaces),
                        topic: topic,
                        visibility: serviceVisibility,
                        isEncrypted: !isSpace && visibility != .publicRoom && isEncrypted,
                        isSpace: isSpace
                    )
                }
                if let destinationSpaceId {
                    await scope.roomList.fileRoom(roomId, intoSpace: destinationSpaceId)
                }
                open(roomId)
                dismiss()
            } catch {
                errorMessage = String(localized: "Couldn't create: \(error.localizedDescription)")
                isCreating = false
            }
        }
    }
}

// MARK: - Join by address

struct JoinRoomSheet: View {
    let scope: SessionScope
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        SheetChrome(title: String(localized: "Join Room"), systemImage: "arrow.right.circle",
                    primaryTitle: isJoining ? String(localized: "Joining…")
                        : String(localized: "Join"),
                    primaryDisabled: address.trimmingCharacters(in: .whitespaces).isEmpty || isJoining,
                    primaryAction: join) {
            #if os(iOS)
            Section {
                TextField("#room:server", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .onSubmit(join)
            } footer: {
                Text("Enter a room address like #room:server, or an internal room ID like !roomid:server.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            #else
            TextField("#room:server or !roomid:server", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(join)

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            // iOS gets these in the nav bar via SheetChrome.
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isJoining ? "Joining…" : "Join") { join() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isJoining)
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func join() {
        guard !isJoining else { return }
        isJoining = true
        Task {
            do {
                let roomId = try await scope.service.joinRoom(
                    address: address.trimmingCharacters(in: .whitespaces))
                open(roomId)
                dismiss()
            } catch {
                errorMessage = String(localized: "Couldn't join: \(error.localizedDescription)")
                isJoining = false
            }
        }
    }
}

// MARK: - Shared chrome

/// Shared sheet scaffolding. macOS: a fixed-width card with an in-content title,
/// consumers supplying their own buttons. iOS: a NavigationStack + grouped Form,
/// with Cancel and the optional primary action as toolbar items.
private struct SheetChrome<Content: View>: View {
    let title: String
    let systemImage: String
    /// iOS-only primary toolbar action; macOS keeps the in-content buttons.
    var primaryTitle: String? = nil
    var primaryDisabled: Bool = false
    var primaryAction: (() -> Void)? = nil
    /// iOS-only: once committed, Cancel is replaced by a bold "Done".
    var isCommitted: Bool = false
    @ViewBuilder let content: Content

    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            content
        }
        .padding(20)
        .frame(width: 400)
        #else
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isCommitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if let primaryTitle, let primaryAction {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(primaryTitle, action: primaryAction)
                                .disabled(primaryDisabled)
                        }
                    }
                }
            }
        }
        #endif
    }
}
