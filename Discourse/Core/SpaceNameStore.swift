import Foundation

/// A `roomId → spaceName` map shared with the notification service extension
/// via the App Group. The NSE can't cheaply resolve a room's parent space
/// itself (that needs the full space hierarchy), so the app — which already
/// has it — persists the mapping for the NSE to read when titling a push.
enum SpaceNameStore {
    private static let key = "roomSpaceNames"
    private static let avatarsKey = "roomSpaceAvatars"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: PushConfig.appGroup)
    }

    static func save(_ map: [String: String]) {
        defaults?.set(map, forKey: key)
    }

    static func spaceName(forRoom roomId: String) -> String? {
        (defaults?.dictionary(forKey: key) as? [String: String])?[roomId]
    }

    /// `roomId → space avatar mxc URL`, so the NSE can show the parent space's
    /// pfp on a room-in-space push.
    static func saveAvatars(_ map: [String: String]) {
        defaults?.set(map, forKey: avatarsKey)
    }

    static func spaceAvatar(forRoom roomId: String) -> String? {
        (defaults?.dictionary(forKey: avatarsKey) as? [String: String])?[roomId]
    }

    private static let roomAvatarsKey = "roomNotificationAvatars"

    /// `roomId → the mxc URL to show on that room's notification`, resolved by
    /// the app per its rule (DM → other person, room-in-space → space, else the
    /// room). The push item's own avatar fields are unreliable in the NSE, so
    /// this app-provided map is the primary source.
    static func saveRoomAvatars(_ map: [String: String]) {
        defaults?.set(map, forKey: roomAvatarsKey)
    }

    static func roomAvatar(forRoom roomId: String) -> String? {
        (defaults?.dictionary(forKey: roomAvatarsKey) as? [String: String])?[roomId]
    }
}
