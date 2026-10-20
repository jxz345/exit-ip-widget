import XCTest
@testable import ExitIPShared

@MainActor
final class CredentialSessionTests: XCTestCase {
    func testConstructionAndStatusInspectionDoNotAccessStorage() {
        let backend = TestCredentialBackend(value: "stored-token")
        let session = makeSession(backend)
        for _ in 0..<10 {
            XCTAssertEqual(session.state, .notLoaded)
            XCTAssertNil(session.value)
            XCTAssertFalse(session.isBusy)
        }
        XCTAssertEqual(backend.operations, [])
    }

    func testExplicitLoadCachesOnlyForThisSession() async {
        let backend = TestCredentialBackend(value: "stored-token")
        let session = makeSession(backend)
        let loaded = await session.load()
        XCTAssertTrue(loaded)
        for _ in 0..<10 { XCTAssertEqual(session.value, "stored-token") }
        XCTAssertEqual(session.state, .available)
        XCTAssertEqual(backend.operations, ["read"])
        let nextSession = makeSession(backend)
        XCTAssertNil(nextSession.value)
        XCTAssertEqual(nextSession.state, .notLoaded)
        XCTAssertEqual(backend.operations, ["read"])
    }

    func testMissingAndFailedReadsAreDifferentAndNeverDelete() async {
        let backend = TestCredentialBackend(value: nil)
        let session = makeSession(backend)
        let loaded = await session.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(session.state, .missing)
        backend.shouldFail = true
        let failed = await session.load()
        XCTAssertFalse(failed)
        XCTAssertEqual(session.state, .failed)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(backend.operations, ["read", "read"])
    }

    func testSaveUpdatesCacheAndSuccessfulRemovalClearsIt() async {
        let backend = TestCredentialBackend(value: nil)
        let session = makeSession(backend)
        let saved = await session.save("new-token")
        XCTAssertTrue(saved)
        XCTAssertEqual(session.value, "new-token")
        XCTAssertEqual(session.state, .available)
        XCTAssertEqual(backend.storedValue, "new-token")
        let removed = await session.remove()
        XCTAssertTrue(removed)
        XCTAssertNil(session.value)
        XCTAssertNil(backend.storedValue)
        XCTAssertEqual(session.state, .missing)
        XCTAssertEqual(backend.operations, ["save", "delete"])
        XCTAssertFalse(backend.usedMainThread)
    }

    func testFailedOperationsPreserveTheLastLoadedValue() async {
        let backend = TestCredentialBackend(value: "original")
        let session = makeSession(backend)
        _ = await session.load()
        backend.shouldFail = true
        let saved = await session.save("replacement")
        let removed = await session.remove()
        let loaded = await session.load()
        XCTAssertFalse(saved)
        XCTAssertFalse(removed)
        XCTAssertFalse(loaded)
        XCTAssertEqual(session.value, "original")
        XCTAssertEqual(backend.storedValue, "original")
        XCTAssertEqual(session.state, .failed)
    }

    func testBlockedReadLeavesMainActorResponsiveAndRejectsDuplicates() async throws {
        let backend = TestCredentialBackend(value: "loaded", blockRead: true)
        defer { backend.releaseRead() }
        let session = makeSession(backend)
        let loading = Task { await session.load() }
        try await waitForRead(backend)
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.state, .loading)
        // This code runs on the main actor while the synchronous backend is still blocked.
        var heartbeat = 0
        await Task { @MainActor in heartbeat += 1 }.value
        XCTAssertEqual(heartbeat, 1)
        let duplicate = await session.load()
        let save = await session.save("newer")
        let remove = await session.remove()
        XCTAssertFalse(duplicate)
        XCTAssertFalse(save)
        XCTAssertFalse(remove)
        XCTAssertEqual(backend.operations, ["read"])
        XCTAssertFalse(backend.usedMainThread)
        backend.releaseRead()
        let result = await loading.value
        XCTAssertTrue(result)
        XCTAssertEqual(session.value, "loaded")
    }

    func testCancellationDoesNotPretendTheNativeOperationFinished() async throws {
        let backend = TestCredentialBackend(value: "loaded", blockRead: true)
        defer { backend.releaseRead() }
        let session = makeSession(backend)
        let loading = Task { await session.load() }
        try await waitForRead(backend)
        loading.cancel()
        await Task.yield()
        XCTAssertTrue(session.isBusy)
        let removed = await session.remove()
        XCTAssertFalse(removed)
        backend.releaseRead()
        _ = await loading.value
        XCTAssertEqual(session.state, .available)
        XCTAssertEqual(backend.operations, ["read"])
    }

    func testSharedWorkerSerializesOperationsAcrossAccounts() async throws {
        let backend = TestCredentialBackend(value: "original", blockRead: true)
        defer { backend.releaseRead() }
        let service = CredentialService(backend: backend)
        let profile = CredentialSession(service: service, account: "profile")
        let token = CredentialSession(service: service, account: "token")
        let loading = Task { await profile.load() }
        try await waitForRead(backend)
        let saving = Task { await token.save("new-token") }
        let deadline = Date().addingTimeInterval(2)
        while !token.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(token.isBusy)
        XCTAssertEqual(backend.operations, ["read"])
        backend.releaseRead()
        _ = await loading.value
        _ = await saving.value
        XCTAssertEqual(backend.operations, ["read", "save"])
        XCTAssertEqual(profile.value, "original")
        XCTAssertEqual(token.value, "new-token")
    }

    func testOperationReportsContainOnlyOperationOutcomeAndDuration() async {
        let backend = TestCredentialBackend(value: "secret-test-value")
        var events: [(CredentialSession.Operation, CredentialSession.Outcome, TimeInterval)] = []
        let session = CredentialSession(service: CredentialService(backend: backend), account: "test") {
            events.append(($0, $1, $2))
        }
        _ = await session.load()
        XCTAssertEqual(events.map(\.0), [.load, .load])
        XCTAssertEqual(events.map(\.1), [.started, .available])
        XCTAssertTrue(events.allSatisfy { $0.2 >= 0 })
    }

    func testAutomaticLoadReadsOncePerSessionAndNeverRetriesAFailure() async {
        let backend = TestCredentialBackend(value: "stored-profile")
        let session = makeSession(backend)
        let first = await session.loadIfNotLoaded()
        let second = await session.loadIfNotLoaded()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(session.value, "stored-profile")
        XCTAssertEqual(backend.operations, ["read"])
        // An explicit Load still reads again.
        await session.load()
        XCTAssertEqual(backend.operations, ["read", "read"])

        let missingBackend = TestCredentialBackend(value: nil)
        let missing = makeSession(missingBackend)
        await missing.loadIfNotLoaded()
        let missingAgain = await missing.loadIfNotLoaded()
        XCTAssertTrue(missingAgain)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missingBackend.operations, ["read"])

        let failingBackend = TestCredentialBackend(value: "stored-profile")
        failingBackend.shouldFail = true
        let failing = makeSession(failingBackend)
        let failed = await failing.loadIfNotLoaded()
        let notRetried = await failing.loadIfNotLoaded()
        XCTAssertFalse(failed)
        XCTAssertFalse(notRetried)
        XCTAssertEqual(failing.state, .failed)
        XCTAssertEqual(failingBackend.operations, ["read"])
    }

    func testAutomaticLoadDoesNotOverlapAnOperationInProgress() async throws {
        let backend = TestCredentialBackend(value: "stored-profile", blockRead: true)
        let session = makeSession(backend)
        let pending = Task { await session.load() }
        let deadline = Date().addingTimeInterval(2)
        while !session.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let overlapping = await session.loadIfNotLoaded()
        XCTAssertFalse(overlapping)
        backend.releaseRead()
        _ = await pending.value
        XCTAssertEqual(backend.operations, ["read"])
        XCTAssertEqual(session.state, .available)
    }

    private func makeSession(_ backend: TestCredentialBackend) -> CredentialSession {
        CredentialSession(service: CredentialService(backend: backend), account: "test")
    }

    private func waitForRead(_ backend: TestCredentialBackend) async throws {
        let deadline = Date().addingTimeInterval(2)
        while backend.operations.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.operations, ["read"])
    }
}

private final class TestCredentialBackend: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let readGate: DispatchSemaphore?
    private var value: String?
    private var calls: [String] = []
    private var mainThread = false
    private var failing = false

    init(value: String?, blockRead: Bool = false) {
        self.value = value
        self.readGate = blockRead ? DispatchSemaphore(value: 0) : nil
    }

    var operations: [String] { lock.withLock { calls } }
    var storedValue: String? { lock.withLock { value } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    var shouldFail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func releaseRead() { readGate?.signal() }

    func read(account: String) throws -> String? {
        try record("read")
        if let readGate, readGate.wait(timeout: .now() + 5) == .timedOut { throw TestFailure.timeout }
        return lock.withLock { value }
    }

    func save(_ value: String, account: String) throws {
        try record("save")
        lock.withLock { self.value = value }
    }

    func delete(account: String) throws {
        try record("delete")
        lock.withLock { value = nil }
    }

    private func record(_ operation: String) throws {
        try lock.withLock {
            calls.append(operation)
            mainThread = mainThread || Thread.isMainThread
            if failing { throw TestFailure.denied }
        }
    }

    private enum TestFailure: Error { case denied, timeout }
}
