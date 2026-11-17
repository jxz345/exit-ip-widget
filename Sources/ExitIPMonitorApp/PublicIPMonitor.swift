import AppKit
import Combine
import Foundation
import Security
import SystemConfiguration
import WidgetKit

@MainActor
final class PublicIPMonitor: ObservableObject {
    enum DebugSimulationScenario: String, CaseIterable, Identifiable {
        case transportFailure
        case malformedResponse
        case rateLimit
        case countryDisagreement
        case notAllowedAddress

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .transportFailure: "Transport failure"
            case .malformedResponse: "Malformed response"
            case .rateLimit: "HTTP 429 rate limit"
            case .countryDisagreement: "Country confirmation disagreement"
            case .notAllowedAddress: "Exit IP not on the allowlist"
            }
        }
    }

    typealias Status = MonitoringStatus
    enum RefreshTrigger { case manual, periodic, startup }
    @Published private(set) var snapshot: ExitIPSnapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var preferences = MonitoringPreferences.load()
    @Published private(set) var indicators = MonitorIndicatorState(suppressLocation: true)
    @Published private(set) var allowedIPList = AllowedIPList()
    @Published private(set) var authorizationState: ExitIPAuthorizationState = .unavailable
    @Published private(set) var providerHealth: [ProviderID: ProviderHealthRecord] = [:]
    @Published private(set) var lookupBudget = LookupBudget()
    @Published private(set) var diagnosticPreferences = DiagnosticPreferences()
    @Published private(set) var simulationMessage: String?
    @Published private(set) var displayDate = Date.now
    @Published private(set) var daemonState: DaemonState?
    @Published private(set) var connected = false
    @Published private(set) var serviceMessage: String? = "Connecting to background service…"
    @Published private(set) var operationError: String?
    @Published private(set) var isChangingSettings = false
    @Published private(set) var isCredentialBusy = false
    let ipinfoCredentials = AppCredentials.makeSession(account: SecureTokenStore.ipinfoLiteAccount)
    private var subscription: DaemonSubscription?
    private var reconnectTask: Task<Void, Never>?
    private var displayTimer: Timer?
    private var sessionObservers: [NSObjectProtocol] = []
    private var warningPresented: UUID?
    private var authorization: AuthorizationBox?
    private var heartbeat: Task<Void, Never>?
    private var localPresentationImported = false
    private var started = false
    private var connectionGeneration = 0

    var isCoolingDown: Bool { if case .coolingDown = status { true } else { false } }
    var isRefreshDeferred: Bool {
        switch status { case .coolingDown, .waitingForMinimumInterval: true; default: false }
    }
    var nextProvider: ProviderID { daemonState?.nextProvider ?? preferences.provider }
    var isIPinfoTokenUnavailable: Bool { daemonState?.hasIPinfoToken != true }
    var ipinfoToken: String? { nil } // Saved machine credentials never leave the daemon.
    var ipinfoCredentialStatus: String {
        if isCredentialBusy { return "Updating System Keychain…" }
        if let error = daemonState?.credentialError { return error }
        return isIPinfoTokenUnavailable ? "No shared IPinfo token" : "Shared token available to background monitoring"
    }

    func start() {
        guard !started else { return }
        started = true
        connect()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                if self.connected { _ = await self.send(DaemonRequest(.state)) }
            }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayDate = .now }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            })
        }
        RuntimeLog.shared.info("daemon_client_started")
    }

    func stop() {
        started = false
        subscription?.invalidate(); subscription = nil
        reconnectTask?.cancel(); reconnectTask = nil
        displayTimer?.invalidate(); displayTimer = nil
        sessionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sessionObservers.removeAll()
        heartbeat?.cancel(); heartbeat = nil
        authorization = nil
        RuntimeLog.shared.info("daemon_client_stopped")
    }

    private func connect() {
        guard started else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        subscription?.invalidate()
        subscription = DaemonSubscription { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.connectionGeneration == generation else { return }
                switch event {
                case .state(let state): self.receive(state)
                case .failed(let failure): self.disconnected(); self.serviceMessage = failure.localizedDescription
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.started, self.connectionGeneration == generation, !self.connected else { return }
            self.disconnected()
        }
    }

    private func disconnected() {
        guard started else { return }
        connected = false
        serviceMessage = DaemonFailure.unavailable.localizedDescription
        indicators = MonitorIndicatorState(errorMessage: "Background service unavailable; cached data is stale", suppressLocation: true)
        status = .failed(serviceMessage!)
        showWarningIfNeeded()
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    func receive(_ state: DaemonState) {
        guard state.protocolVersion == ExitIPService.protocolVersion else {
            disconnected(); serviceMessage = DaemonFailure.incompatible.localizedDescription; return
        }
        let oldSnapshot = snapshot, oldIndicators = indicators
        daemonState = state
        connected = true
        reconnectTask?.cancel(); reconnectTask = nil
        serviceMessage = state.storageError ?? (state.initialized ? nil : "Set up shared monitoring using this account’s existing settings.")
        preferences = state.preferences
        snapshot = state.presentedSnapshot
        status = state.status
        indicators = state.presentedIndicators
        allowedIPList = state.settings.allowlist
        authorizationState = state.authorizationState
        providerHealth = state.providerHealth
        lookupBudget = state.budget
        diagnosticPreferences = state.settings.diagnostics
        RuntimeLog.shared.configure(state.settings.diagnostics)
        if snapshot?.hasWidgetContentChange(comparedTo: oldSnapshot) == true || oldIndicators != indicators {
            reloadSurfaces()
        }
        // Import appearance once per UID in the service. A widget or another account cannot seed it.
        if !state.presentation.imported, !localPresentationImported {
            localPresentationImported = true
            let old = MonitoringPreferences.load()
            var presentation = state.presentation
            presentation.imported = true
            presentation.displayStyle = old.menuBarDisplayStyle
            presentation.highlightCountryChanges = old.highlightCountryChanges
            var request = DaemonRequest(.presentation)
            request.presentation = presentation
            Task { [weak self] in
                guard let self else { return }
                guard self.connected else { self.localPresentationImported = false; return }
                if !(await self.send(request)) { self.localPresentationImported = false }
            }
        } else if state.presentation.imported {
            showWarningIfNeeded()
        }
    }

    private var isActiveSession: Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        return uid == getuid()
    }

    private func showWarningIfNeeded() {
        guard connected, !indicators.suppressLocation,
              let state = daemonState, state.initialized, let event = state.allowlistEventID,
              case .notAllowed(let address) = authorizationState,
              state.snapshot?.isStale(threshold: Double(state.settings.refreshInterval.rawValue * 2)) == false else {
            if warningPresented != nil { RuntimeLog.shared.info("allowlist_warning_cleared") }
            AllowlistWarningWindowController.shared.dismiss(); warningPresented = nil; return
        }
        guard isActiveSession, warningPresented != event, state.presentation.seenAllowlistEvent != event else { return }
        warningPresented = event
        RuntimeLog.shared.info("allowlist_warning_presented", fields: ["ip": address])
        AllowlistWarningWindowController.shared.show(address: address)
        var presentation = state.presentation
        presentation.seenAllowlistEvent = event
        updatePresentation(presentation)
    }

    func applicationDidBecomeActive() {
        guard started else { return }
        Task {
            _ = await send(DaemonRequest(.state))
            showWarningIfNeeded()
        }
    }

    @discardableResult
    private func send(_ request: DaemonRequest) async -> Bool {
        do {
            let response = try await DaemonRPC.call(request, timeout: isCredentialBusy ? 30 : 8)
            if let state = response.state { receive(state) }
            if request.command != .state { operationError = nil }
            return true
        } catch {
            operationError = error.localizedDescription
            if let failure = error as? DaemonFailure, failure == .unavailable { disconnected() }
            // A stale editor must see the winning revision before retrying.
            if let response = try? await DaemonRPC.call(DaemonRequest(.state)), let state = response.state { receive(state) }
            return false
        }
    }

    private func updatePresentation(_ presentation: UserPresentationPreferences, completion: (() -> Void)? = nil) {
        var request = DaemonRequest(.presentation)
        request.presentation = presentation
        Task { if await send(request) { completion?(); reloadSurfaces() } }
    }

    func apply(_ updated: MonitoringPreferences) {
        guard let state = daemonState else { return }
        if updated.menuBarDisplayStyle != preferences.menuBarDisplayStyle || updated.highlightCountryChanges != preferences.highlightCountryChanges {
            var presentation = state.presentation
            presentation.displayStyle = updated.menuBarDisplayStyle
            presentation.highlightCountryChanges = updated.highlightCountryChanges
            updatePresentation(presentation)
        }
        if updated.provider != preferences.provider || updated.providerPool != preferences.providerPool || updated.refreshInterval != preferences.refreshInterval {
            var settings = state.settings
            settings.provider = updated.provider
            settings.providerPool = updated.providerPool
            if !settings.providerPool.contains(updated.provider) { settings.providerPool.insert(updated.provider, at: 0) }
            settings.refreshInterval = updated.refreshInterval
            configure(settings)
        }
    }

    func setAllowedIPList(_ list: AllowedIPList) {
        guard var settings = daemonState?.settings else { return }
        settings.allowlist = list; configure(settings)
    }
    func addAllowedIP(_ value: String) -> Bool {
        var list = allowedIPList
        guard list.insert(value) else { return false }
        setAllowedIPList(list); return true
    }
    func removeAllowedIP(_ value: String) { var list = allowedIPList; if list.remove(value) { setAllowedIPList(list) } }
    func applyDiagnosticPreferences(_ preferences: DiagnosticPreferences) {
        guard var settings = daemonState?.settings else { return }
        settings.diagnostics = preferences; configure(settings)
    }
    func setProviderEnabled(_ enabled: Bool) {
        guard var settings = daemonState?.settings else { return }
        settings.tailscaleProviderEnabled = enabled; configure(settings)
    }
    private func configure(_ settings: MachineSettings) {
        var request = DaemonRequest(.configure)
        request.settings = settings
        Task { _ = await privileged(request) }
    }

    func initializeSharedSettings() async {
        let defaults = ExitIPAppGroup.defaults
        let legacyProvider = FileManager.default.fileExists(atPath: TailscaleVergeProvider.monitorPlistPath)
            || FileManager.default.fileExists(atPath: ExitIPService.support.appendingPathComponent("legacy-provider-enabled").path)
            || FileManager.default.fileExists(atPath: "/Library/Preferences/com.example.exitipmonitor.legacy-provider-enabled")
            || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ExitIPMonitor/legacy-provider-enabled").path)
        let settings = MachineSettings(preferences: MonitoringPreferences.load(), allowlist: AllowedIPStore().load(),
                                       diagnostics: DiagnosticPreferencesStore().load(), tailscaleProviderEnabled: legacyProvider)
        var request = DaemonRequest(.initialize)
        request.migration = MigrationState(settings: settings, budget: LookupBudgetStore().load(),
            attempts: RefreshAttemptStore().lastAttempts(), cooldowns: Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
                ProviderCooldownStore(defaults: defaults).retryNotBefore(for: provider).map { (provider, $0) }
            }), snapshot: SnapshotStore().load())
        _ = await privileged(request)
    }

    private func privileged(_ request: DaemonRequest) async -> Bool {
        guard connected, let state = daemonState else {
            operationError = DaemonFailure.unavailable.localizedDescription
            return false
        }
        guard !isChangingSettings else { return false }
        isChangingSettings = true
        defer { isChangingSettings = false }
        var request = request
        request.expectedRevision = state.revision
        do {
            request.authorization = try await authorizationData()
            return await send(request)
        } catch { operationError = error.localizedDescription; return false }
    }

    private func authorizationData() async throws -> Data {
        // The Security Agent owns all credential UI. No passwords enter this process.
        if authorization == nil {
            var value: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [], &value) == errAuthorizationSuccess, let value else { throw DaemonFailure.unauthorized }
            authorization = AuthorizationBox(value)
        }
        guard let box = authorization else { throw DaemonFailure.unauthorized }
        return try await Task.detached(priority: .userInitiated) {
            try ExitIPService.settingsRight.withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                let status = withUnsafeMutablePointer(to: &item) { pointer in
                    var rights = AuthorizationRights(count: 1, items: pointer)
                    return AuthorizationCopyRights(box.value, &rights, nil, [.interactionAllowed, .extendRights], nil)
                }
                guard status == errAuthorizationSuccess else { throw DaemonFailure.unauthorized }
                var external = AuthorizationExternalForm()
                guard AuthorizationMakeExternalForm(box.value, &external) == errAuthorizationSuccess else { throw DaemonFailure.unauthorized }
                return withUnsafeBytes(of: &external) { Data($0) }
            }
        }.value
    }

    func loadIPinfoToken() async -> Bool {
        guard !isCredentialBusy else { return false }
        guard await ipinfoCredentials.load(), let token = ipinfoCredentials.value else {
            operationError = ipinfoCredentials.errorMessage ?? "No IPinfo token was found in this account’s Keychain."; return false
        }
        return await saveIPinfoToken(token)
    }
    func saveIPinfoToken(_ token: String) async -> Bool {
        guard !isCredentialBusy else { return false }
        isCredentialBusy = true; defer { isCredentialBusy = false }
        var request = DaemonRequest(.setToken); request.token = token
        return await privileged(request)
    }
    func removeIPinfoToken() async -> Bool {
        guard !isCredentialBusy else { return false }
        isCredentialBusy = true; defer { isCredentialBusy = false }
        return await privileged(DaemonRequest(.removeToken))
    }
    func refresh(force: Bool = false, bypassMinimumInterval: Bool = false, trigger: RefreshTrigger = .manual) async {
        _ = await send(DaemonRequest(.refresh))
    }
    func testProvider(_ provider: ProviderID) async { var request = DaemonRequest(.testProvider); request.provider = provider; _ = await send(request) }
    func pausedUntil(_ provider: ProviderID) -> Date? { daemonState?.cooldowns[provider] }
    func setCountryChangeHighlightsEnabled(_ enabled: Bool) { var updated = preferences; updated.highlightCountryChanges = enabled; apply(updated) }
    func dismissCountryChangeHighlight() {
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedCountryChange = daemonState?.snapshot?.countryChange?.changedAt
        updatePresentation(presentation) { RuntimeLog.shared.info("country_change_dismissed") }
    }
    func clearError() {
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedError = daemonState?.errorEventID
        updatePresentation(presentation) { RuntimeLog.shared.info("error_cleared") }
    }
    func clearIndicators() {
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedError = daemonState?.errorEventID
        presentation.dismissedCountryChange = daemonState?.snapshot?.countryChange?.changedAt
        updatePresentation(presentation)
    }
    func runDebugSimulation(_ scenario: DebugSimulationScenario) {
        simulationMessage = "Simulation: \(scenario.displayName)"
        switch scenario {
        case .transportFailure, .malformedResponse: indicators = .init(errorMessage: scenario.displayName, suppressLocation: true)
        case .rateLimit: status = .providerPaused(preferences.provider, Date().addingTimeInterval(3600))
        case .countryDisagreement: status = .awaitingConfirmation("Simulated country disagreement")
        case .notAllowedAddress: authorizationState = .notAllowed("203.0.113.8")
        }
    }
    func clearDebugSimulation() { simulationMessage = nil; if let state = daemonState { receive(state) } }
    private func reloadSurfaces() {
        RuntimeLog.shared.info("widget_reload_requested")
        WidgetCenter.shared.reloadTimelines(ofKind: ExitIPSurfaceID.widget)
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: ExitIPSurfaceID.control) }
    }
}

private final class AuthorizationBox: @unchecked Sendable {
    let value: AuthorizationRef
    init(_ value: AuthorizationRef) { self.value = value }
    deinit { AuthorizationFree(value, [.destroyRights]) }
}
