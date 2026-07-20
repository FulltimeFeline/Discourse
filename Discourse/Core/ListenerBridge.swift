import Foundation
@preconcurrency import MatrixRustSDK

/// Adapters turning UniFFI listener callbacks (fired on Rust/tokio threads)
/// into `AsyncStream`s that view models iterate from the main actor.
///
/// Callers MUST retain the SDK `TaskHandle` from registration — dropping it
/// silently cancels the subscription.

final class RoomListEntriesBridge: RoomListEntriesListener {
    let stream: AsyncStream<[RoomListEntriesUpdate]>
    private let continuation: AsyncStream<[RoomListEntriesUpdate]>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        continuation.yield(roomEntriesUpdate)
    }
}

final class RoomListLoadingStateBridge: RoomListLoadingStateListener {
    let stream: AsyncStream<RoomListLoadingState>
    private let continuation: AsyncStream<RoomListLoadingState>.Continuation

    init() {
        // Latest-value-only; superseded values aren't worth buffering.
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func onUpdate(state: RoomListLoadingState) {
        continuation.yield(state)
    }
}

final class SyncServiceStateBridge: SyncServiceStateObserver {
    let stream: AsyncStream<SyncServiceState>
    private let continuation: AsyncStream<SyncServiceState>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func onUpdate(state: SyncServiceState) {
        continuation.yield(state)
    }
}

final class TimelineDiffBridge: TimelineListener {
    let stream: AsyncStream<[TimelineDiff]>
    private let continuation: AsyncStream<[TimelineDiff]>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func onUpdate(diff: [TimelineDiff]) {
        continuation.yield(diff)
    }
}

final class TypingNotificationsBridge: TypingNotificationsListener {
    let stream: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation

    init() {
        // Each update is the full typing set; only the newest matters.
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func call(typingUserIds: [String]) {
        continuation.yield(typingUserIds)
    }
}

final class JoinedSpacesBridge: SpaceServiceJoinedSpacesListener {
    let stream: AsyncStream<[SpaceListUpdate]>
    private let continuation: AsyncStream<[SpaceListUpdate]>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func onUpdate(roomUpdates: [SpaceListUpdate]) {
        continuation.yield(roomUpdates)
    }
}

final class VerificationStateBridge: VerificationStateListener {
    let stream: AsyncStream<VerificationState>
    private let continuation: AsyncStream<VerificationState>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func onUpdate(status: VerificationState) {
        continuation.yield(status)
    }
}

/// Events from the interactive session-verification (SAS) flow.
enum VerificationEvent {
    case requestReceived(senderId: String, flowId: String)
    case acceptedByOtherDevice
    case sasStarted
    case emojis([VerificationEmoji])
    case failed
    case cancelled
    case finished
}

struct VerificationEmoji: Hashable {
    let symbol: String
    let description: String
}

final class SessionVerificationDelegateBridge: SessionVerificationControllerDelegate {
    let stream: AsyncStream<VerificationEvent>
    private let continuation: AsyncStream<VerificationEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        continuation.yield(.requestReceived(senderId: details.senderProfile.userId,
                                            flowId: details.flowId))
    }

    func didAcceptVerificationRequest() {
        continuation.yield(.acceptedByOtherDevice)
    }

    func didStartSasVerification() {
        continuation.yield(.sasStarted)
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        if case .emojis(let emojis, _) = data {
            continuation.yield(.emojis(emojis.map {
                VerificationEmoji(symbol: $0.symbol(), description: $0.description())
            }))
        }
    }

    func didFail() { continuation.yield(.failed) }
    func didCancel() { continuation.yield(.cancelled) }
    func didFinish() { continuation.yield(.finished) }
}

final class RoomInfoBridge: RoomInfoListener {
    let stream: AsyncStream<RoomInfo>
    private let continuation: AsyncStream<RoomInfo>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func call(roomInfo: RoomInfo) {
        continuation.yield(roomInfo)
    }
}

/// The SDK's auth-error callback; yields `isSoftLogout` so the app can drop
/// into re-auth instead of retrying restore forever.
final class ClientDelegateBridge: ClientDelegate {
    let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func didReceiveAuthError(isSoftLogout: Bool) {
        continuation.yield(isSoftLogout)
    }

    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}

/// Fires when the send queue disables itself for a room after a send error.
/// The value is unused; any error is a cue to re-enable once healthy.
final class SendQueueErrorBridge: SendQueueRoomErrorListener {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func onError(roomId: String, error: ClientError) {
        continuation.yield(())
    }
}
