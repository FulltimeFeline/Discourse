import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class LoginViewModel {
    enum Stage {
        case server, methods
    }

    enum BrowserLoginKind {
        case oauth, sso
    }

    var stage: Stage = .server
    var homeserver = "matrix.org"
    var username = ""
    var password = ""
    var isBusy = false
    var errorMessage: String?

    private var pending: PendingLogin?
    private let webAuth = WebAuthSession()

    var supportsPassword: Bool { pending?.supportsPassword ?? false }
    var supportsOAuth: Bool { pending?.supportsOAuth ?? false }
    var supportsSso: Bool { pending?.supportsSso ?? false }

    var homeserverDisplayName: String {
        homeserver.trimmingCharacters(in: .whitespaces).isEmpty ? "matrix.org" : homeserver.trimmingCharacters(in: .whitespaces)
    }

    var canSubmitPassword: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    // MARK: Stage transitions

    func discoverMethods() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            pending = try await MatrixService.prepare(homeserver: homeserverDisplayName)
            stage = .methods
        } catch {
            errorMessage = String(localized: "Couldn't reach \(homeserverDisplayName): \(error.localizedDescription)")
        }
    }

    func backToServerEntry() {
        pending = nil
        errorMessage = nil
        password = ""
        stage = .server
    }

    // MARK: Auth methods

    func passwordLogin() async -> (MatrixService, RestorationToken)? {
        guard let pending, canSubmitPassword, !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            return try await pending.finishWithPassword(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password)
        } catch {
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    func browserLogin(kind: BrowserLoginKind) async -> (MatrixService, RestorationToken)? {
        guard let pending, !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let url = switch kind {
            case .oauth: try await pending.startOAuth()
            case .sso: try await pending.startSso()
            }
            let callback = try await webAuth.authenticate(url: url, callbackScheme: PendingLogin.callbackScheme)
            return switch kind {
            case .oauth: try await pending.finishOAuth(callbackUrl: callback)
            case .sso: try await pending.finishSso(callbackUrl: callback)
            }
        } catch {
            if kind == .oauth {
                await pending.abortOAuth()
            }
            if !isUserCancellation(error) {
                errorMessage = String(localized: "Sign-in failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: Helpers

    private func isUserCancellation(_ error: Error) -> Bool {
        if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func friendlyMessage(for error: Error) -> String {
        if let serviceError = error as? MatrixServiceError {
            return serviceError.localizedDescription
        }
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("forbidden") || text.contains("M_FORBIDDEN") {
            return String(localized: "Incorrect username or password.")
        }
        return String(localized: "Sign-in failed: \(error.localizedDescription)")
    }
}
