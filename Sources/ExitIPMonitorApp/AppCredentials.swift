import Foundation

@MainActor
enum AppCredentials {
    private static let service = CredentialService(backend: KeychainCredentialBackend())
    static let proxy = makeSession(account: ClashVergeProfile.keychainAccount)

    static func makeSession(account: String) -> CredentialSession {
        CredentialSession(service: service, account: account) { operation, outcome, duration in
            // Never include account values, credentials, or backend error descriptions.
            RuntimeLog.shared.info("keychain_operation", fields: [
                "operation": operation.rawValue,
                "outcome": outcome.rawValue,
                "duration_ms": String(Int(duration * 1_000))
            ])
        }
    }
}
