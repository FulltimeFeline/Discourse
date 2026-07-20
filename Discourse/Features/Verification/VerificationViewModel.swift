import Foundation
import Observation
@preconcurrency import MatrixRustSDK

/// Drives the verify-session sheet: SAS emoji verification against another
/// signed-in device, or recovery-key entry.
@MainActor
@Observable
final class VerificationViewModel {
    enum Step: Equatable {
        case intro
        case waitingForOtherDevice
        case comparingEmojis([VerificationEmoji])
        case confirming
        case done
        case failed(String)
        case recoveryKeyEntry
        case recovering
    }

    private(set) var step: Step = .intro
    var recoveryKey = ""

    private let service: MatrixService
    private var controller: SessionVerificationController?
    private var bridge: SessionVerificationDelegateBridge?
    private var eventTask: Task<Void, Never>?

    init(service: MatrixService) {
        self.service = service
    }

    // MARK: Device verification

    func beginDeviceVerification() async {
        do {
            try await attachController()
            try await controller?.requestDeviceVerification()
            step = .waitingForOtherDevice
        } catch {
            step = .failed("Couldn't start verification: \(error.localizedDescription)")
        }
    }

    /// Accepts a verification request initiated from another device.
    func beginIncomingVerification(senderId: String, flowId: String) async {
        do {
            try await attachController()
            try await controller?.acknowledgeVerificationRequest(senderId: senderId, flowId: flowId)
            try await controller?.acceptVerificationRequest()
            step = .waitingForOtherDevice
        } catch {
            step = .failed("Couldn't accept the verification request: \(error.localizedDescription)")
        }
    }

    private func attachController() async throws {
        let controller = try await service.sessionVerificationController()
        self.controller = controller
        let bridge = SessionVerificationDelegateBridge()
        self.bridge = bridge
        controller.setDelegate(delegate: bridge)
        eventTask = Task { [weak self] in
            for await event in bridge.stream {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: VerificationEvent) async {
        switch event {
        case .requestReceived:
            break // only originate or explicitly accept here
        case .acceptedByOtherDevice:
            try? await controller?.startSasVerification()
        case .sasStarted:
            break // emojis follow
        case .emojis(let emojis):
            step = .comparingEmojis(emojis)
        case .failed:
            step = .failed("Verification failed. Try again from the other device too.")
        case .cancelled:
            step = .failed("Verification was cancelled.")
        case .finished:
            step = .done
        }
    }

    func emojisMatch() {
        step = .confirming
        Task { try? await controller?.approveVerification() }
    }

    func emojisDontMatch() {
        Task { try? await controller?.declineVerification() }
        step = .failed("Verification declined — the emojis didn't match.")
    }

    func cancel() {
        Task { try? await controller?.cancelVerification() }
        cleanUp()
    }

    // MARK: Recovery key

    func showRecoveryKeyEntry() {
        step = .recoveryKeyEntry
    }

    func submitRecoveryKey() async {
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        step = .recovering
        do {
            try await service.recover(recoveryKey: key)
            step = .done
        } catch {
            step = .failed("That recovery key didn't work. Check it and try again.")
        }
    }

    func reset() {
        cleanUp()
        step = .intro
        recoveryKey = ""
    }

    private func cleanUp() {
        eventTask?.cancel()
        eventTask = nil
        controller?.setDelegate(delegate: nil)
        controller = nil
        bridge = nil
    }
}
