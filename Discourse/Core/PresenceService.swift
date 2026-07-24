import SwiftUI

/// User presence (online/idle/offline). The Rust SDK doesn't surface presence,
/// so this polls the C-S endpoint directly with the session's access token.
@MainActor
@Observable
final class PresenceService {
    enum State: String {
        case online, offline, unavailable

        var color: Color {
            switch self {
            case .online: .green
            case .unavailable: .orange
            case .offline: Color.gray.opacity(0.6)
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .online: "Online"
            case .unavailable: "Idle"
            case .offline: "Offline"
            }
        }
    }

    struct Entry {
        var state: State
        var lastActiveAgo: TimeInterval?
        var fetchedAt: Date
        /// The `status_msg` — Commet and friends store the user's custom status
        /// here (not in a profile field).
        var statusMessage: String?
    }

    /// One user's observable presence, boxed so an update re-renders only that
    /// user's dots.
    @MainActor
    @Observable
    final class UserPresence {
        var entry: Entry?
    }

    private static let pollInterval: TimeInterval = 20

    /// Boxes are created on first read and live for the session (stable
    /// identity so views keep observing the same object).
    @ObservationIgnored private var users: [String: UserPresence] = [:]
    /// Refcounts of visible dots per user; keys are what the poll loop fetches.
    @ObservationIgnored private var watchers: [String: Int] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let baseURL: URL?
    private let accessToken: String
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Homeservers with presence disabled 403 every call; stop asking.
    @ObservationIgnored private var unsupported = false
    /// True while backgrounded and the poll loop is parked; watchers persist.
    @ObservationIgnored private var isPaused = false

    /// Signed-in user, so own-presence polling can be suppressed when "share
    /// presence" is off.
    private let ownUserId: String?

    init(homeserverUrl: String, accessToken: String, ownUserId: String? = nil) {
        self.baseURL = URL(string: homeserverUrl)
        self.accessToken = accessToken
        self.ownUserId = ownUserId
    }

    private func user(_ userId: String) -> UserPresence {
        if let existing = users[userId] { return existing }
        let box = UserPresence()
        users[userId] = box
        return box
    }

    func state(of userId: String) -> State? {
        user(userId).entry?.state
    }

    /// The user's custom status message (Matrix presence `status_msg`), which is
    /// where Commet-family clients keep their status. nil when unset/unfetched.
    func statusMessage(of userId: String) -> String? {
        user(userId).entry?.statusMessage
    }

    /// "Online", "Idle", or how long ago they were last seen.
    func detailText(of userId: String) -> String? {
        guard let entry = user(userId).entry else { return nil }
        switch entry.state {
        case .online: return String(localized: "Online")
        case .unavailable: return String(localized: "Idle")
        case .offline:
            if let ago = entry.lastActiveAgo, ago > 0 {
                let formatted = Duration.seconds(ago).formatted(
                    .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1))
                return String(localized: "Last active \(formatted) ago")
            }
            return String(localized: "Offline")
        }
    }

    /// A dot became visible: fetch if stale and keep the user in the poll loop
    /// until the matching `unregister`.
    func register(_ userId: String) {
        watchers[userId, default: 0] += 1
        refresh(userId)
        startPollingIfNeeded()
    }

    func unregister(_ userId: String) {
        guard let count = watchers[userId] else { return }
        if count <= 1 { watchers[userId] = nil } else { watchers[userId] = count - 1 }
        if watchers.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Stops the poll while backgrounded; watchers are kept for `resume()`.
    func pause() {
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
    }

    /// Restarts the poll after `pause()` if any dots remain registered.
    func resume() {
        isPaused = false
        guard !watchers.isEmpty else { return }
        startPollingIfNeeded()
    }

    /// One timer for every visible dot, not a loop per dot.
    private func startPollingIfNeeded() {
        guard pollTask == nil, !unsupported, !isPaused else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !self.unsupported else { return }
                for userId in self.watchers.keys {
                    // Below the poll period, so each tick fetches unless an
                    // ad-hoc refresh just did.
                    self.fetch(userId, maxAge: Self.pollInterval * 0.75)
                }
            }
        }
    }

    /// Fetches unless a recent result is cached; cheap to call repeatedly from
    /// rows.
    func refresh(_ userId: String) {
        fetch(userId, maxAge: Self.pollInterval * 1.25)
    }

    private func fetch(_ userId: String, maxAge: TimeInterval) {
        guard !unsupported, let baseURL else { return }
        // With sharing off, don't poll our own status: each GET is activity the
        // server reads as "online".
        if userId == ownUserId, !Preferences.shared.sharePresence { return }
        let box = user(userId)
        if let entry = box.entry, Date().timeIntervalSince(entry.fetchedAt) < maxAge { return }
        guard !inFlight.contains(userId) else { return }
        inFlight.insert(userId)
        let url = baseURL.appendingPathComponent("_matrix/client/v3/presence/\(userId)/status")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        Task {
            defer { inFlight.remove(userId) }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 403 {
                // Presence disabled server-side; don't keep hammering it.
                unsupported = true
                pollTask?.cancel()
                pollTask = nil
                return
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let presence = (json["presence"] as? String).flatMap(State.init(rawValue:))
            else { return }
            let ago = (json["last_active_ago"] as? Double).map { $0 / 1000 }
            let statusMsg = (json["status_msg"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            box.entry = Entry(state: presence, lastActiveAgo: ago, fetchedAt: Date(),
                              statusMessage: statusMsg)
        }
    }
}

// MARK: - Environment plumbing

private struct PresenceServiceKey: EnvironmentKey {
    static let defaultValue: PresenceService? = nil
}

extension EnvironmentValues {
    var presenceService: PresenceService? {
        get { self[PresenceServiceKey.self] }
        set { self[PresenceServiceKey.self] = newValue }
    }
}

/// Presence dot pinned to an avatar's bottom-trailing corner; registers with
/// the poll loop while visible.
struct PresenceDot: View {
    let userId: String
    var size: CGFloat = 10
    @Environment(\.presenceService) private var presence

    var body: some View {
        ZStack {
            if let presence, let state = presence.state(of: userId) {
                Circle()
                    .fill(state.color)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(.background, lineWidth: size * 0.18))
                    .help(state.label)
                    .accessibilityLabel(state.label)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: presence?.state(of: userId))
        .task(id: userId) {
            guard let presence else { return }
            presence.register(userId)
            defer { presence.unregister(userId) }
            // Park until cancelled (view gone / userId changed).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

extension View {
    /// Overlays a presence dot on an avatar.
    func presenceIndicator(userId: String?, size: CGFloat = 10) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let userId {
                PresenceDot(userId: userId, size: size)
            }
        }
    }
}
