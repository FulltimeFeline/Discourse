import SwiftUI

/// Lazily fetches and caches each user's profile (pronouns, avatar, display
/// name) so the timeline, member list, profiles, and call-participant strips can
/// show them without re-hitting the homeserver per row. Observing views
/// re-render when a fetch lands.
@MainActor
@Observable
final class PronounsStore {
    private let service: MatrixService
    /// userId → fetched profile (a stored entry means "fetched", so we don't
    /// keep re-requesting even when fields are empty).
    private var cache: [String: MatrixService.ProfileInfo] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Set by AppState after both are built: the status comes from presence
    /// `status_msg` (where Commet stores it), with the profile field as fallback.
    weak var presence: PresenceService?

    init(service: MatrixService) {
        self.service = service
    }

    private func ensure(_ userId: String) {
        guard cache[userId] == nil, !inFlight.contains(userId) else { return }
        inFlight.insert(userId)
        Task {
            let info = await service.fetchProfile(userId: userId) ?? .init()
            cache[userId] = info
            inFlight.remove(userId)
        }
    }

    /// The cached pronouns, kicking off a fetch on first miss (returns nil until
    /// it lands, then the observation update fills it in).
    func pronouns(for userId: String) -> String? {
        ensure(userId)
        return cache[userId]?.pronouns
    }

    /// The cached avatar mxc URL (for call-participant strips etc.).
    func avatarURL(for userId: String) -> String? {
        ensure(userId)
        return cache[userId]?.avatarURL
    }

    func displayName(for userId: String) -> String? {
        ensure(userId)
        return cache[userId]?.displayName
    }

    func bio(for userId: String) -> String? { ensure(userId); return cache[userId]?.bio }
    /// The user's status. Presence `status_msg` (Commet's store) is preferred;
    /// the `chat.commet.profile_status` profile field is the fallback.
    ///
    /// Gating: when we KNOW the user's presence, show the status only while
    /// they're connected (online/idle), hidden when offline. When presence is
    /// unknown — either not fetched yet or the homeserver has presence disabled
    /// (Tuwunel returns 404/400) — we can't gate, so we still show the
    /// profile-field status rather than hiding everything.
    func status(for userId: String) -> String? {
        let state = presence?.state(of: userId)
        // Known offline → hide.
        if state == .offline { return nil }
        // Known connected → prefer the live presence status message.
        if state == .online || state == .unavailable,
           let msg = presence?.statusMessage(of: userId), !msg.isEmpty {
            return msg
        }
        // Connected without a presence message, or presence unknown (not fetched
        // / homeserver has it disabled): fall back to the profile field.
        ensure(userId)
        return cache[userId]?.status
    }
    func bannerURL(for userId: String) -> String? { ensure(userId); return cache[userId]?.bannerURL }
    func timezone(for userId: String) -> String? { ensure(userId); return cache[userId]?.timezone }
    func socialLinks(for userId: String) -> [MatrixService.SocialLink] {
        ensure(userId); return cache[userId]?.socialLinks ?? []
    }

    /// Updates the cached pronouns immediately after the local user edits their
    /// own, so the change shows without waiting for a re-fetch.
    func setLocal(_ pronouns: String?, for userId: String) {
        var info = cache[userId] ?? .init()
        info.pronouns = pronouns
        cache[userId] = info
    }

    /// Drops the cached profile so the next access re-fetches — used after the
    /// local user edits their bio/status/timezone/banner.
    func invalidate(_ userId: String) {
        cache[userId] = nil
        inFlight.remove(userId)
    }
}

private struct PronounsStoreKey: EnvironmentKey {
    static let defaultValue: PronounsStore? = nil
}

extension EnvironmentValues {
    var pronounsStore: PronounsStore? {
        get { self[PronounsStoreKey.self] }
        set { self[PronounsStoreKey.self] = newValue }
    }
}
