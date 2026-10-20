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
        require(backend.calls.isEmpty, "Rendering Settings and the dashboard must not read the IPinfo token")
        require(profileBackend.calls.count <= 1 && profileBackend.calls.allSatisfy { $0 == "read" },
                "Opening the profile view may read the proxy info once, and only read it")
        require(await client.calls.isEmpty, "Refresh and Test must not load credentials implicitly")
        print("PASS: startup, status, activation, refresh and Test make no Keychain calls; the profile view reads the proxy info at most once; IPinfo waits without quota use")

        try profileButtonRowChecks()
        try dockIconChecks(output: output)

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

    /// Load proxy info, Save and Remove form one row (an HStack with no fallback) that fits the
    /// profile form's narrowest value column: about 472 pt column − GroupBox insets − 110 pt label
    /// − 12 pt spacing ≈ 326 pt. 320 pt leaves a margin.
    @MainActor
    static func profileButtonRowChecks() throws {
        let host = NSHostingView(rootView: ProxyInfoActionRow(load: {}, save: {}, remove: {}))
        let size = host.fittingSize
        require(size.width > 200 && size.width <= 320,
                "The proxy-info button row must fit the 320 pt value column in one row (needs \(size.width) pt)")
        require(size.height < 40, "The proxy-info buttons must share one row (height \(size.height) pt)")
        print("PASS: Load proxy info, Save and Remove share one \(Int(size.width)) pt row, within the narrowest value column")
    }

    /// The Dock icon is the menu-bar label itself: one render per visible change, none otherwise.
    /// Writes `menubar-<state>.png` and `dock-<state>.png` side by side for visual comparison.
    @MainActor
    static func dockIconChecks(output: URL) throws {
        let now = Date()
        let singapore = ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                                       provider: .ipWhois, checkedAt: now)
        let japan = ExitIPSnapshot(ipAddress: "198.51.100.7", countryCode: "JP", countryName: "Japan",
                                   provider: .ipWhois, checkedAt: now)
        let changed = ExitIPSnapshot(ipAddress: "198.51.100.7", countryCode: "JP", countryName: "Japan",
                                     provider: .ipWhois, checkedAt: now,
                                     countryChange: CountryChange(previousCode: "SG", previousName: "Singapore",
                                                                  changedAt: now, highlightUntil: now.addingTimeInterval(600)))
        let stale = ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                                   provider: .ipWhois, checkedAt: now.addingTimeInterval(-7_200))
        func label(_ snapshot: ExitIPSnapshot?, _ style: MenuBarDisplayStyle = .flag,
                   error: Bool = false) -> MenuBarCountryLabel {
            MenuBarCountryLabel(snapshot: snapshot, displayStyle: style, refreshInterval: .fifteenMinutes,
                                indicators: MonitorIndicatorState(errorMessage: error ? "Lookup failed" : nil,
                                                                  suppressLocation: error),
                                date: now)
        }
        let dock = DockIconController()
        let states: [(String, MenuBarCountryLabel, Bool)] = [
            ("flag-sg", label(singapore), true), ("flag-jp", label(japan), true),
            ("changed", label(changed), true), ("error", label(singapore, error: true), true),
            ("stale", label(stale), true), ("locating", label(nil), true),
            ("code", label(singapore, .code), true), ("name-dark", label(singapore, .name), false),
        ]
        for (name, menuBar, light) in states {
            require(dock.update(label: menuBar, darkAppearance: !light, apply: false), "\(name) must render a new icon")
            require(!dock.update(label: menuBar, darkAppearance: !light, apply: false), "An unchanged \(name) must not re-render")
            guard let image = dock.image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fatalError("No Dock icon for \(name)")
            }
            require(cgImage.width == 512 && cgImage.height == 512, "\(name) icon must be a 512 × 512 square")
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let visible = stride(from: 0, to: 512, by: 8).reduce(0) { count, x in
                count + stride(from: 0, to: 512, by: 8).filter { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 }.count
            }
            require(visible > 40, "\(name) icon must draw the label, not an empty canvas")
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent("dock-\(name).png"))
            let renderer = ImageRenderer(content: menuBar.fixedSize().environment(\.colorScheme, light ? .light : .dark))
            renderer.scale = 4
            if let small = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent("menubar-\(name).png"))
            }
        }
        require(dock.update(label: label(singapore), darkAppearance: true, apply: false),
                "A menu-bar appearance change must re-render")
        print("PASS: the Dock icon re-renders the menu-bar label only when its flag, error, change, stale, style or appearance changes")
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
