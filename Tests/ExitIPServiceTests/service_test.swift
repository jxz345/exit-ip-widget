import Foundation
import Security

@main
struct ServiceTests {
    @MainActor
    static func main() async throws {
        let access = try SystemCredentials.ownerAccess()
        var owner: uid_t = 0, group: gid_t = 0, type: SecAccessOwnerType = 0
        var acl: CFArray?
        require(SecAccessCopyOwnerAndACL(access, &owner, &group, &type, &acl) == errSecSuccess,
                "credential access policy must be inspectable")
        require(owner == getuid() && type == UInt32(kSecUseOnlyUID), "credential ACL must restrict access to the daemon's UID")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FilePreferenceStorage(url: directory.appendingPathComponent("state.plist"))
        let client = RecordingLookup()
        let credentials = MemorySystemCredentials()
        let service = try DaemonService(storage: storage, observeSystem: false, credentials: credentials, client: client,
                                        authorize: { $0 == Data("authorized".utf8) })
        require(!service.state(for: 501).initialized, "new service must await explicit initialization")
        require(await client.count == 0, "uninitialized service must not spend quota")
        var initialize = DaemonRequest(.initialize)
        initialize.expectedRevision = 0
        initialize.settings = MachineSettings(preferences: .init(provider: .ipinfoLite, providerPool: [.ipinfoLite]))
        require(await service.handle(initialize, uid: 501).failure == .unauthorized, "configuration must require authorization")
        var migratedBudget = LookupBudget()
        for _ in 0..<20 { migratedBudget.recordCall(to: .ipinfoLite) }
        initialize.migration = MigrationState(settings: initialize.settings!, budget: migratedBudget, attempts: [:], cooldowns: [:],
            snapshot: ExitIPSnapshot(ipAddress: "192.0.2.9", countryCode: "SG", countryName: "Singapore", provider: .ipinfoLite))
        initialize.authorization = Data("authorized".utf8)
        require(await service.handle(initialize, uid: 501).failure == nil, "authorized initialization must succeed")
        try await Task.sleep(for: .milliseconds(350))
        require(await client.count == 1, "daemon must load its System Keychain token and look up once")
        require(service.state(for: 501).budget.callsToday(for: .ipinfoLite) == 21, "initialization must retain the migrating user’s consumed quota")
        require(credentials.reads == 1, "daemon startup must read the System Keychain once")
        require(service.state(for: 502).hasIPinfoToken, "other users receive token availability")
        let wire = try JSONEncoder().encode(service.state(for: 502))
        require(!String(decoding: wire, as: UTF8.self).contains("daemon-test-secret"), "state must never contain the saved token")
        initialize.expectedRevision = 1
        require(await service.handle(initialize, uid: 502).failure == .alreadyInitialized, "later users cannot overwrite migration")

        var presentation = DaemonRequest(.presentation)
        var personal = UserPresentationPreferences()
        personal.displayStyle = .name
        personal.highlightCountryChanges = false
        presentation.presentation = personal
        require(await service.handle(presentation, uid: 501).failure == nil, "personal appearance requires no administrator")
        require(service.state(for: 501).presentation.displayStyle == .name, "request updates caller preferences")
        require(service.state(for: 502).presentation.displayStyle == .flag, "different users retain independent preferences")

        // Exercise NSXPC encoding, kernel caller identity and asynchronous replies without launchd.
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let remote = try await DaemonRPC.call(DaemonRequest(.state), connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        require(remote.state?.instanceID == service.state(for: getuid()).instanceID, "XPC must reach this service")
        personal.displayStyle = .name
        presentation.presentation = personal
        _ = try await DaemonRPC.call(presentation, connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        require(service.state(for: getuid()).presentation.displayStyle == .name, "XPC must use the caller's kernel UID")
        var wrongVersion = DaemonRequest(.state)
        wrongVersion.protocolVersion = 99
        do {
            _ = try await DaemonRPC.call(wrongVersion, connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
            fatalError("XPC accepted an incompatible version")
        } catch DaemonFailure.incompatible {}

        var update = DaemonRequest(.configure)
        update.authorization = Data("authorized".utf8)
        update.expectedRevision = 0
        var settings = service.state(for: 501).settings
        settings.allowlist = AllowedIPList(addresses: ["192.0.2.20"])
        update.settings = settings
        require(await service.handle(update, uid: 501).failure == .conflict, "stale edits must fail")
        update.expectedRevision = 1
        require(await service.handle(update, uid: 501).failure == nil, "current revision must commit")
        require(service.state(for: 502).settings.allowlist.contains("192.0.2.20"), "configuration must be visible to all users")
        require(service.state(for: 502).authorizationState.isNotAllowed, "shared allowlist must reevaluate the latest verified IP")

        let count = await client.count
        async let first = service.handle(DaemonRequest(.refresh), uid: 501)
        async let second = service.handle(DaemonRequest(.refresh), uid: 502)
        _ = await (first, second)
        try await Task.sleep(for: .milliseconds(350))
        require(await client.count == count + 1, "concurrent user refreshes must produce one lookup")

        var forbidden = DaemonRequest(.removeToken)
        forbidden.expectedRevision = 2
        require(await service.handle(forbidden, uid: 502).failure == .unauthorized, "standard users cannot remove shared credentials")
        var incompatible = DaemonRequest(.state)
        incompatible.protocolVersion = 99
        require(await service.handle(incompatible, uid: 501).failure == .incompatible, "protocol mismatch must be explicit")
        service.stop()
        let restored = try DaemonService(storage: FilePreferenceStorage(url: directory.appendingPathComponent("state.plist")),
                                        observeSystem: false, credentials: credentials, client: client)
        require(restored.state(for: 501).revision == 2, "settings revision must survive restart")
        require(restored.state(for: 501).presentation.displayStyle == .name, "personal preferences must survive restart")
        require(restored.state(for: 502).presentation.displayStyle == .flag, "restart must retain user isolation")
        require(restored.state(for: 501).budget.callsToday(for: .ipinfoLite) >= 2, "provider budget must survive restart")
        let normal = await Task.detached { BoundedProcess.run("/usr/bin/printf", ["hello"]) }.value
        require(normal.status == 0 && normal.text == "hello", "probe must capture output")
        let childFile = directory.appendingPathComponent("child.pid")
        let timeout = await Task.detached {
            BoundedProcess.run("/bin/bash", ["-c", "sleep 30 & echo $! > \"$1\"; wait", "probe", childFile.path], timeout: 0.2)
        }.value
        require(timeout.status == 124, "stalled probes must time out")
        let child = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await Task.sleep(for: .milliseconds(200))
        require(kill(child, 0) != 0 && errno == ESRCH, "timeout must terminate the child as well as the parent")
        let flood = await Task.detached { BoundedProcess.run("/usr/bin/yes", [], timeout: 2) }.value
        require(flood.status == 125, "probe output must be bounded")
        print("PASS: real XPC transport, initialization, authorization, secret isolation, per-user state, concurrent refresh, revision conflicts, restart persistence and bounded subprocesses")
    }
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
}

private actor RecordingLookup: PublicIPLookupClientProtocol {
    private(set) var count = 0
    func lookup(configuration: LookupConfiguration) async throws -> ExitIPSnapshot {
        count += 1
        try await Task.sleep(for: .milliseconds(100))
        return ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> ExitIPSnapshot {
        ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
    }
}

private final class MemorySystemCredentials: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var value: String? = "daemon-test-secret"
    var reads: Int { lock.withLock { count } }
    func read(account: String) throws -> String? { lock.withLock { count += 1; return value } }
    func save(_ value: String, account: String) throws { lock.withLock { self.value = value } }
    func delete(account: String) throws { lock.withLock { value = nil } }
}
