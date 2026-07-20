import SwiftUI

/// ⌘K jump-to-room palette; Enter opens the highlighted room.
struct QuickSwitcherView: View {
    let rooms: [RoomSummary]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    /// Recomputed only on query change; read several times per body pass.
    @State private var matches: [RoomSummary]
    @FocusState private var isFocused: Bool

    init(rooms: [RoomSummary], open: @escaping (String) -> Void) {
        self.rooms = rooms
        self.open = open
        // Seed so the first body pass (before onAppear) isn't empty.
        _matches = State(initialValue: Array(rooms.filter { !$0.isSpace && !$0.isInvited }.prefix(8)))
    }

    /// openRoom needs a joined timeline; spaces and pending invites have none.
    private var eligibleRooms: [RoomSummary] {
        rooms.filter { !$0.isSpace && !$0.isInvited }
    }

    private func recomputeMatches() {
        guard !query.isEmpty else {
            matches = Array(eligibleRooms.prefix(8))
            return
        }
        let q = RoomSummary.foldedForSearch(query)
        // Prefix matches outrank contains matches; order preserved within each.
        var prefixMatches: [RoomSummary] = []
        var containsMatches: [RoomSummary] = []
        for room in eligibleRooms {
            if room.foldedName.hasPrefix(q) {
                prefixMatches.append(room)
                if prefixMatches.count == 8 { break }
            } else if containsMatches.count < 8, room.foldedName.contains(q) {
                containsMatches.append(room)
            }
        }
        matches = Array((prefixMatches + containsMatches).prefix(8))
    }

    var body: some View {
        #if os(macOS)
        palette
            .frame(width: 440)
        #else
        palette
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
    }

    private var palette: some View {
        VStack(spacing: 0) {
            TextField("Jump to room…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($isFocused)
                .onSubmit(openHighlighted)
                .onChange(of: query) {
                    highlighted = 0
                    recomputeMatches()
                }
                // Rooms keep syncing while open; refresh so the list doesn't freeze.
                .onChange(of: rooms) {
                    highlighted = min(highlighted, max(0, matches.count - 1))
                    recomputeMatches()
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                #endif

            Divider()

            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, room in
                        Button {
                            open(room.id)
                            dismiss()
                        } label: {
                            resultRow(room: room, isHighlighted: index == highlighted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(room.hasUnread ? Text("Unread") : Text(verbatim: ""))
                        .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(8)
            }
        }
        .onAppear {
            isFocused = true
            recomputeMatches()
        }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, matches.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        #if os(macOS)
        // Escape closes the palette even while the text field has focus.
        .onExitCommand { dismiss() }
        #endif
    }

    private func resultRow(room: RoomSummary, isHighlighted: Bool) -> some View {
        let row = HStack(spacing: 8) {
            RoomAvatarView(name: room.name, isDirect: room.isDirect, size: 22,
                           avatarURL: room.avatarURL)
            Text(room.name)
                .lineLimit(1)
            Spacer()
            if room.isMentioned {
                // Red for a ping, matching the sidebar/rail signal.
                Circle().fill(.red).frame(width: 8, height: 8)
            } else if room.hasUnread {
                Circle().fill(.tint).frame(width: 8, height: 8)
            }
        }
        #if os(iOS)
        // Touch-sized rows; macOS keeps its compact palette density.
        return row
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        #else
        return row
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        #endif
    }

    private func openHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        open(matches[highlighted].id)
        dismiss()
    }
}
