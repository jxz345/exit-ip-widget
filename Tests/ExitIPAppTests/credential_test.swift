import AppKit
import SwiftUI

/// Native integration checks compile the real app with a separate entry point and isolated defaults.
/// No real Keychain operations, network calls, visible windows, or provider installation occur.
@main
enum CredentialAppTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let defaults = ExitIPAppGroup.defaults
        defer { defaults.removePersistentDomain(forName: ExitIPAppGroup.identifier) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        defaults.removePersistentDomain(forName: ExitIPAppGroup.identifier)
        MonitoringPreferences(provider: .ipinfoLite, providerPool: [.ipinfoLite]).save()
        let oldSnapshot = snapshot(.ipWhois)
        SnapshotStore().save(oldSnapshot)
        let backend = MemoryCredentials()
        let credentials = CredentialSession(service: CredentialService(backend: backend), account: "token")
        let client = RecordingClient()
        let monitor = PublicIPMonitor(client: client, ipinfoCredentials: credentials)
        monitor.start()
        try await settle()
        require(monitor.status == .waitingForIPinfoToken, "IPinfo-only startup must wait for an explicit load")
        require(monitor.snapshot == oldSnapshot, "Waiting must preserve the snapshot")
        require(await client.calls.isEmpty, "Startup must spend no IPinfo request")
        require(monitor.lookupBudget.callsToday(for: .ipinfoLite) == 0, "Startup must spend no quota")
        for _ in 0..<10 { _ = monitor.ipinfoCredentialStatus; _ = monitor.isIPinfoTokenUnavailable }
        monitor.applicationDidBecomeActive()
        await monitor.refresh(force: true, trigger: .periodic)
        await monitor.testProvider(.ipinfoLite)

        let profileBackend = MemoryCredentials()
        let profile = CredentialSession(service: CredentialService(backend: profileBackend), account: "profile")
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            try render(ClashVergeProfileSection(providerInstalled: false, credentials: profile),
                       size: NSSize(width: 500, height: 640), dark: dark,
                       to: output.appendingPathComponent("profile-\(mode).png"))
            try render(SettingsView(monitor: monitor), size: NSSize(width: 560, height: 1300), dark: dark,
                       to: output.appendingPathComponent("settings-\(mode).png"))
        }
        try await settle()
        require(backend.calls.isEmpty && profileBackend.calls.isEmpty, "Rendering/opening credential views must not read storage")
        require(await client.calls.isEmpty, "Refresh and Test must not load credentials implicitly")
        print("PASS: startup, status, window rendering, activation, refresh and Test make no Keychain calls; IPinfo waits without quota use")

        let pausedUntil = Date().addingTimeInterval(300)
        ProviderCooldownStore().save(retryNotBefore: pausedUntil, for: .ipinfoLite)
        require(await monitor.loadIPinfoToken(), "Explicit Load should succeed")
        try await settle()
        require(backend.calls == ["read"], "Load should read exactly once")
        require(ProviderCooldownStore().retryNotBefore(for: .ipinfoLite) == pausedUntil, "Load must preserve the provider pause")
        require(await client.calls.isEmpty, "Load must not bypass a provider pause")
        ProviderCooldownStore().clear(for: .ipinfoLite)
        await monitor.refresh(force: true)
        let loadedCalls = await client.calls
        require(!loadedCalls.isEmpty && loadedCalls.allSatisfy { $0.provider == .ipinfoLite && $0.ipinfoToken == "test-token" },
                "Automatic monitoring must use the loaded token")
        await monitor.testProvider(.ipinfoLite)
        require(backend.calls == ["read"], "Subsequent lookup must use memory")
        require(await client.calls.count > loadedCalls.count, "Provider Test must use the loaded token")

        let countBeforeRemoval = await client.calls.count
        require(await monitor.removeIPinfoToken(), "Explicit Remove should succeed")
        await monitor.refresh(force: true)
        require(await client.calls.count == countBeforeRemoval, "Remove and a tokenless refresh must spend no lookup")
        require(monitor.ipinfoToken == nil && monitor.status == .waitingForIPinfoToken, "Remove must clear the cached token")
        require(monitor.snapshot != nil, "Remove must preserve the last result")
        require(backend.calls == ["read", "delete"], "Only explicit actions may access storage")
        ProviderCooldownStore().save(retryNotBefore: pausedUntil, for: .ipinfoLite)
        require(await monitor.saveIPinfoToken("  replacement-token  "), "Explicit Save should succeed")
        require(ProviderCooldownStore().retryNotBefore(for: .ipinfoLite) == nil, "Save must clear the old credential's pause")
        try await settle()
        await monitor.testProvider(.ipinfoLite)
        require(await client.calls.last?.ipinfoToken == "replacement-token", "Save must update the token used for lookup")
        require(backend.calls == ["read", "delete", "save"], "Save must not reread Keychain")
        monitor.stop()
        print("PASS: explicit Load/Save enables cached IPinfo use; Remove clears the cache without a request")

        defaults.removePersistentDomain(forName: ExitIPAppGroup.identifier)
        MonitoringPreferences(provider: .ipinfoLite, providerPool: [.ipinfoLite, .ipWhois]).save()
        let mixedBackend = MemoryCredentials()
        let mixedClient = RecordingClient()
        let mixed = PublicIPMonitor(client: mixedClient, ipinfoCredentials:
            CredentialSession(service: CredentialService(backend: mixedBackend), account: "token"))
        mixed.start()
        try await settle()
        let mixedCalls = await mixedClient.calls
        require(!mixedCalls.isEmpty && mixedCalls.allSatisfy { $0.provider == .ipWhois && $0.ipinfoToken == nil },
                "A mixed pool must use its anonymous provider while IPinfo is not loaded")
        require(mixedBackend.calls.isEmpty, "Mixed rotation must not query Keychain")
        mixed.stop()
        print("PASS: mixed pools continue anonymous monitoring without reading the saved IPinfo token")
    }

    static func snapshot(_ provider: ProviderID) -> ExitIPSnapshot {
        ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: provider)
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    @MainActor
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to path: URL) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: path)
    }
}

private actor RecordingClient: PublicIPLookupClientProtocol {
    private(set) var calls: [LookupConfiguration] = []
    func lookup(configuration: LookupConfiguration) async throws -> ExitIPSnapshot {
        calls.append(configuration)
        return CredentialAppTests.snapshot(configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> ExitIPSnapshot {
        CredentialAppTests.snapshot(.ipWhois)
    }
}

private final class MemoryCredentials: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []
    private var value: String? = "test-token"
    var calls: [String] { lock.withLock { operations } }
    func read(account: String) throws -> String? { lock.withLock { operations.append("read"); return value } }
    func save(_ value: String, account: String) throws { lock.withLock { operations.append("save"); self.value = value } }
    func delete(account: String) throws { lock.withLock { operations.append("delete"); value = nil } }
}
