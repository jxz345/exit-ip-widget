import Foundation
import Observation

/// Synchronous storage is confined to CredentialService's worker queue, never the main actor.
public protocol CredentialBackend: Sendable {
    func read(account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

public final class CredentialService: Sendable {
    private let backend: any CredentialBackend
    private let queue = DispatchQueue(label: "com.example.exitipmonitor.credentials")

    public init(backend: any CredentialBackend) {
        self.backend = backend
    }

    public func read(account: String) async throws -> String? {
        try await perform { try $0.read(account: account) }
    }

    public func save(_ value: String, account: String) async throws {
        try await perform { try $0.save(value, account: account) }
    }

    public func delete(account: String) async throws {
        try await perform { try $0.delete(account: account) }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (any CredentialBackend) throws -> Value
    ) async throws -> Value {
        // Security's synchronous calls cannot be cancelled. Keep ownership until they finish;
        // cancelling a caller must not allow a later save/delete to overtake an unfinished read.
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [backend] in
                continuation.resume(with: Result { try operation(backend) })
            }
        }
    }
}

/// In-memory state for one account. Construction and inspection never access storage.
/// Only load/save/remove calls perform I/O, plus `loadIfNotLoaded`, the dashboard's one automatic
/// read per session. Failed operations preserve the last value.
@MainActor
@Observable
public final class CredentialSession {
    public enum State: Equatable, Sendable {
        case notLoaded, loading, available, missing, failed
    }

    public enum Operation: String, Sendable {
        case load, save, remove
    }

    public enum Outcome: String, Sendable {
        case started, available, missing, saved, removed, failed
    }

    public private(set) var state: State = .notLoaded
    public private(set) var value: String?
    public private(set) var errorMessage: String?
    public var isBusy: Bool { state == .loading }

    private let service: CredentialService
    private let account: String
    private let report: (Operation, Outcome, TimeInterval) -> Void

    public init(
        service: CredentialService,
        account: String,
        report: @escaping (Operation, Outcome, TimeInterval) -> Void = { _, _, _ in }
    ) {
        self.service = service
        self.account = account
        self.report = report
    }

    @discardableResult
    public func load() async -> Bool {
        await perform(.load) { try await self.service.read(account: self.account) }
    }

    /// Reads only while nothing has been loaded this session: at most one automatic read, never
    /// overlapping an operation in progress and never retrying a failure (explicit `load` does).
    @discardableResult
    public func loadIfNotLoaded() async -> Bool {
        guard state == .notLoaded else { return state == .available || state == .missing }
        return await load()
    }

    @discardableResult
    public func save(_ value: String) async -> Bool {
        await perform(.save) {
            try await self.service.save(value, account: self.account)
            return value
        }
    }

    @discardableResult
    public func remove() async -> Bool {
        await perform(.remove) {
            try await self.service.delete(account: self.account)
            return nil
        }
    }

    private func perform(_ operation: Operation, work: () async throws -> String?) async -> Bool {
        guard !isBusy else { return false }
        state = .loading
        errorMessage = nil
        let started = ContinuousClock.now
        report(operation, .started, 0)
        do {
            value = try await work()
            state = value == nil ? .missing : .available
            let outcome: Outcome = switch operation {
            case .load: value == nil ? .missing : .available
            case .save: .saved
            case .remove: .removed
            }
            report(operation, outcome, seconds(since: started))
            return true
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            report(operation, .failed, seconds(since: started))
            return false
        }
    }

    private func seconds(since started: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
