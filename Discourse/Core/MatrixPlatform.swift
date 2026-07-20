import Foundation
@preconcurrency import MatrixRustSDK

/// One-time Rust SDK platform init; must run before any `ClientBuilder`.
enum MatrixPlatform {
    private static let initialized: Void = {
        do {
            try initPlatform(
                config: TracingConfiguration(
                    logLevel: .info,
                    traceLogPacks: [],
                    extraTargets: [],
                    writeToStdoutOrSystem: true,
                    writeToFiles: nil,
                    sentryConfig: nil
                ),
                useLightweightTokioRuntime: false
            )
        } catch {
            assertionFailure("Matrix platform init failed: \(error)")
        }
    }()

    static func initializeOnce() {
        _ = initialized
    }
}
