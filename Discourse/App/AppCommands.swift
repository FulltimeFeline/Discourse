import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message…") {
                appState.newChatSheet = .directMessage
            }
            .keyboardShortcut("n")
            .disabled(!isActive)

            Button("New Room…") {
                appState.newChatSheet = .room(spaceId: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!isActive)

            Button("New Space…") {
                appState.newChatSheet = .space
            }
            .disabled(!isActive)

            Button("Join Room…") {
                appState.newChatSheet = .join
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!isActive)

            Divider()

            Button("Jump to Room…") {
                appState.isQuickSwitcherPresented = true
            }
            .keyboardShortcut("k")
            .disabled(!isActive)
        }

        #if os(macOS)
        CommandGroup(after: .sidebar) {
            Button("Filter Rooms") {
                appState.sidebarFilterFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!isActive)

            Button("Toggle Details") {
                // TimelineView's details column observes this same key.
                let defaults = UserDefaults.standard
                defaults.set(!defaults.bool(forKey: "showsDetailsColumn"),
                             forKey: "showsDetailsColumn")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!isActive)

            Divider()
        }

        CommandMenu("Go") {
            Button("Next Room") {
                navigate { $0.roomId(offsetBy: 1, from: $0.activeRoomId) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!isActive)

            Button("Previous Room") {
                navigate { $0.roomId(offsetBy: -1, from: $0.activeRoomId) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!isActive)

            Divider()

            Button("Next Unread") {
                navigate { $0.nextUnreadRoomId(from: $0.activeRoomId, forward: true) }
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!isActive)

            Button("Previous Unread") {
                navigate { $0.nextUnreadRoomId(from: $0.activeRoomId, forward: false) }
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!isActive)

            Divider()

            Button("Home") {
                selectSpace(nil)
            }
            .keyboardShortcut("0")
            .disabled(!isActive)

            ForEach(Array(spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                Button(space.name) {
                    selectSpace(space.id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        #endif

        CommandGroup(after: .appSettings) {
            Button("Sign Out…") {
                // Menus can't present dialogs; the main window watches this flag.
                appState.isSignOutConfirmPresented = true
            }
            .disabled(!isActive)
        }
    }

    private var isActive: Bool {
        if case .active = appState.phase { return true }
        return false
    }

    private var scope: SessionScope? {
        if case .active(let scope) = appState.phase { return scope }
        return nil
    }

    private var spaces: [RoomListViewModel.SpaceItem] {
        // Rail's persisted drag order, so Cmd-1…9 match what's on screen.
        scope?.roomList.orderedSpaces ?? []
    }

    private func navigate(_ pick: (RoomListViewModel) -> String?) {
        guard let scope, let roomId = pick(scope.roomList) else { return }
        appState.pendingRoomNavigation = roomId
    }

    private func selectSpace(_ spaceId: String?) {
        guard let scope else { return }
        Task { await scope.roomList.selectSpace(spaceId) }
    }
}
