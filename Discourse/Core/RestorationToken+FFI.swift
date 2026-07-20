import Foundation
@preconcurrency import MatrixRustSDK

// FFI Session <-> Codable mirror. Shared by the app and the notification
// service extension, which both restore a client from a stored token.
extension RestorationToken.SessionData {
    init(from session: Session) {
        self.init(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData,
            slidingSyncVersion: session.slidingSyncVersion == .native ? "native" : "none"
        )
    }

    var ffiSession: Session {
        Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            deviceId: deviceId,
            homeserverUrl: homeserverUrl,
            oauthData: oauthData,
            slidingSyncVersion: slidingSyncVersion == "native" ? .native : .none
        )
    }
}
