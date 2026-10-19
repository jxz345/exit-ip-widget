import AppKit
import Combine
import Foundation
import Network
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

    /// Allowlist result for the last verified address. The allowlist only warns; it never blocks traffic.
    enum ExitIPAuthorizationState: Equatable {
        /// The allowlist is empty (no warnings) or no address has been verified this session.
        case unavailable
        case allowed
        case notAllowed(String)
    }

    /// Why a refresh was requested; written to the runtime log so event-driven behavior can be audited.
    enum RefreshTrigger: String {
        case startup
        case manual
        case periodic
        case networkPath = "network_path"
        case networkConfiguration = "network_configuration"
        case routeChange = "route_change"
        case systemWake = "system_wake"
        case screensWake = "screens_wake"
        case sessionActive = "session_active"
        case appActive = "app_active"
        case queued
        /// One follow-up lookup at the end of an event window for events merged after the immediate one.
        case trailing
        case retry
        case recheck
        case providerChanged = "provider_changed"
        case settingsChanged = "settings_changed"

        /// How much API quota the trigger justifies (see `LookupBudget`). `.queued`, `.recheck`, and
        /// `.trailing` normally pass the urgency of the requests they stand in for (`refresh(urgency:)`);
        /// this is only their fallback.
        var urgency: RefreshUrgency {
            switch self {
            case .manual, .providerChanged, .settingsChanged:
                .manual
            case .periodic, .appActive, .screensWake, .sessionActive:
                .routine
            case .retry:
                .followUp
            case .startup, .networkPath, .networkConfiguration, .routeChange, .systemWake, .queued, .trailing, .recheck:
                .networkChange
            }
        }
    }

    enum Status: Equatable {
        case idle
        case refreshing
        case ready
        case awaitingConfirmation(String)
        /// Every enabled provider is paused or out of daily budget; lookups resume at the date.
        case coolingDown(Date)
        /// One provider refused requests and is paused until the date; rotation uses the others meanwhile.
        case providerPaused(ProviderID, Date)
        case waitingForMinimumInterval(Date)
        case waitingForIPinfoToken
        case failed(String)
    }

    @Published private(set) var snapshot: ExitIPSnapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var preferences: MonitoringPreferences
    @Published private(set) var indicators: MonitorIndicatorState
    @Published private(set) var allowedIPList: AllowedIPList
    @Published private(set) var authorizationState: ExitIPAuthorizationState = .unavailable
    @Published private(set) var providerHealth: [ProviderID: ProviderHealthRecord]
    @Published private(set) var lookupBudget: LookupBudget
    @Published private(set) var diagnosticPreferences: DiagnosticPreferences
    @Published private(set) var simulationMessage: String?
    @Published private(set) var displayDate = Date.now
    private var displayTimer: Timer?

    private let snapshotStore: SnapshotStore
    private let cooldownStore: ProviderCooldownStore
    private let refreshAttemptStore: RefreshAttemptStore
    private let lookupBudgetStore: LookupBudgetStore
    private let indicatorStore: IndicatorStore
    private let allowedIPStore: AllowedIPStore
    private let providerHealthStore: ProviderHealthStore
    private let diagnosticPreferencesStore: DiagnosticPreferencesStore
    private let client: any PublicIPLookupClientProtocol
    private let now: @Sendable () -> Date
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.example.exitipmonitor.network-path")
    private lazy var configurationObserver = NetworkConfigurationObserver { [weak self] in
        Task { @MainActor [weak self] in
            self?.handleEventTrigger(.networkConfiguration)
        }
    }
    private lazy var routeObserver = RouteChangeObserver { [weak self] in
        Task { @MainActor [weak self] in
            self?.handleEventTrigger(.routeChange)
        }
    }
    private var refreshTimer: Timer?
    private var retryTask: Task<Void, Never>?
    /// Leading-plus-trailing throttle shared by every event-driven trigger.
    private var eventWindow = EventRefreshWindow()
    private var eventWindowTask: Task<Void, Never>?
    private var minimumIntervalTask: Task<Void, Never>?
    private var highlightExpiryTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var receivedInitialPath = false
    private var lastPathSignature: NetworkPathSignature?
    private var consecutiveFailures = 0
    private var temporarilyFailedProviders: Set<ProviderID> = []
    private var isRefreshing = false
    /// Highest urgency among requests folded into the post-lookup `.recheck`; `nil` when none is owed.
    private var recheckUrgency: RefreshUrgency?
    /// The single pending `.queued` refresh (boundary + highest urgency).
    private var pendingRefresh = PendingRefresh()
    private var hasVerifiedAddressThisSession = false
    /// The address the allowlist warning window was last opened for, so it opens once per address.
    private var warningPresentedForAddress: String?
    let ipinfoCredentials: CredentialSession
    private var isStarted = false
    private var lifecycleGeneration = 0

    init(
        snapshotStore: SnapshotStore = SnapshotStore(),
        cooldownStore: ProviderCooldownStore = ProviderCooldownStore(),
        refreshAttemptStore: RefreshAttemptStore = RefreshAttemptStore(),
        lookupBudgetStore: LookupBudgetStore = LookupBudgetStore(),
        indicatorStore: IndicatorStore = IndicatorStore(),
        allowedIPStore: AllowedIPStore = AllowedIPStore(),
        providerHealthStore: ProviderHealthStore = ProviderHealthStore(),
        diagnosticPreferencesStore: DiagnosticPreferencesStore = DiagnosticPreferencesStore(),
        client: any PublicIPLookupClientProtocol = PublicIPLookupClient(),
        ipinfoCredentials: CredentialSession? = nil,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.snapshotStore = snapshotStore
        self.cooldownStore = cooldownStore
        self.refreshAttemptStore = refreshAttemptStore
        self.lookupBudgetStore = lookupBudgetStore
        self.indicatorStore = indicatorStore
        self.allowedIPStore = allowedIPStore
        self.providerHealthStore = providerHealthStore
        self.diagnosticPreferencesStore = diagnosticPreferencesStore
        self.client = client
        self.ipinfoCredentials = ipinfoCredentials ?? AppCredentials.makeSession(account: SecureTokenStore.ipinfoLiteAccount)
        self.now = now
        self.snapshot = snapshotStore.load()
        self.indicators = indicatorStore.load()
        self.allowedIPList = allowedIPStore.load()
        self.preferences = MonitoringPreferences.load()
        self.providerHealth = providerHealthStore.loadAll()
        self.lookupBudget = lookupBudgetStore.load(now: now())
        self.diagnosticPreferences = diagnosticPreferencesStore.load()
    }

    private var currentDate: Date { now() }

    private func secondsUntil(_ date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(currentDate))
    }

    var isCoolingDown: Bool {
        if case .coolingDown = status { return true }
        return false
    }

    var isRefreshDeferred: Bool {
        switch status {
        case .coolingDown, .waitingForMinimumInterval:
            true
        default:
            false
        }
    }

    func start() {
        guard refreshTimer == nil else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        RuntimeLog.shared.info("monitor_started")
        startNetworkPathMonitoring()
        configurationObserver.start()
        routeObserver.start()
        startWorkspaceMonitoring()
        schedulePeriodicRefresh()
        displayDate = currentDate
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayDate = self.currentDate
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        scheduleHighlightExpiry()
        // Startup is an intentional exception to the persisted spacing gate: every
        // launch gets one immediate check, while subsequent events remain gated.
        Task {
            await refresh(force: true, bypassMinimumInterval: true, trigger: .startup)
        }
    }

    func stop() {
        RuntimeLog.shared.info("monitor_stopped")
        isStarted = false
        lifecycleGeneration &+= 1
        recheckUrgency = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        displayTimer?.invalidate()
        displayTimer = nil
        retryTask?.cancel()
        eventWindowTask?.cancel()
        eventWindowTask = nil
        eventWindow.reset()
        minimumIntervalTask?.cancel()
        minimumIntervalTask = nil
        pendingRefresh = PendingRefresh()
        highlightExpiryTask?.cancel()
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceNotificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        configurationObserver.stop()
        routeObserver.stop()
        pathMonitor.cancel()
    }

    func setAllowedIPList(_ list: AllowedIPList) {
        allowedIPList = list
        allowedIPStore.save(list)
        warningPresentedForAddress = nil
        if hasVerifiedAddressThisSession {
            evaluateAuthorization(for: snapshot?.ipAddress)
        }
    }

    func addAllowedIP(_ value: String) -> Bool {
        var updated = allowedIPList
        guard updated.insert(value) else { return false }
        setAllowedIPList(updated)
        return true
    }

    func removeAllowedIP(_ value: String) {
        var updated = allowedIPList
        guard updated.remove(value) else { return }
        setAllowedIPList(updated)
    }

    func loadIPinfoToken() async -> Bool {
        guard await ipinfoCredentials.load() else { return false }
        ipinfoCredentialChanged(requestRefresh: true)
        return true
    }

    /// A saved token may resolve an authentication pause, so clear it and check with the new credential.
    func saveIPinfoToken(_ token: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, await ipinfoCredentials.save(token) else { return false }
        cooldownStore.clear(for: .ipinfoLite)
        ipinfoCredentialChanged(requestRefresh: true)
        return true
    }

    /// Without a token IPinfo Lite can only fail, so rotation skips it (like a pause) instead of
    /// producing a lookup error that would hide the location. The old credential's pause no longer
    /// applies. No lookup is spent: the current result is still valid.
    func removeIPinfoToken() async -> Bool {
        guard await ipinfoCredentials.remove() else { return false }
        cooldownStore.clear(for: .ipinfoLite)
        RuntimeLog.shared.info("ipinfo_token_removed")
        ipinfoCredentialChanged(requestRefresh: false)
        return true
    }

    private func ipinfoCredentialChanged(requestRefresh: Bool) {
        objectWillChange.send()
        if ipinfoToken == nil {
            if preferences.provider == .ipinfoLite, advanceProvider(after: .ipinfoLite) == nil {
                status = .waitingForIPinfoToken
            }
        } else if requestRefresh, isStarted, preferences.providerPool.contains(.ipinfoLite) {
            Task { await refresh(force: true, trigger: .settingsChanged) }
        }
    }

    /// These are memory-only checks, including during view rendering and automatic refresh.
    var ipinfoToken: String? {
        guard let token = ipinfoCredentials.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    var isIPinfoTokenUnavailable: Bool { ipinfoToken == nil }

    var ipinfoCredentialStatus: String {
        if ipinfoCredentials.isBusy { return "Waiting for Keychain…" }
        if ipinfoToken != nil { return "Token available for this session" }
        switch ipinfoCredentials.state {
        case .notLoaded: return "Saved token not loaded"
        case .loading: return "Waiting for Keychain…"
        case .missing, .available: return "No saved token found"
        case .failed: return "Keychain access failed; try Load again"
        }
    }

    func applicationDidBecomeActive() {
        handleEventTrigger(.appActive)
    }

    func apply(_ updatedPreferences: MonitoringPreferences) {
        let providerChanged = preferences.provider != updatedPreferences.provider
        preferences = updatedPreferences
        updatedPreferences.save()
        if !updatedPreferences.highlightCountryChanges {
            dismissCountryChangeHighlight()
        }
        schedulePeriodicRefresh()
        reloadSystemSurfaces(reloadWidget: false)
        if providerChanged {
            retryTask?.cancel()
            Task { await refresh(force: true, trigger: .providerChanged) }
        }
    }

    func applyDiagnosticPreferences(_ updated: DiagnosticPreferences) {
        diagnosticPreferences = updated
        diagnosticPreferencesStore.save(updated)
        RuntimeLog.shared.info("diagnostic_preferences_changed", fields: [
            "fullIPAddresses": String(updated.includeFullIPAddresses),
            "retentionDays": String(updated.retentionDays)
        ])
    }

    /// Tests exactly `provider`, bypassing the spacing gate. A paused or budget-exhausted provider is not
    /// called (and rotation must not quietly test another one instead): honoring the pause is not optional.
    func testProvider(_ provider: ProviderID) async {
        guard preferences.providerPool.contains(provider) else { return }
        if provider == .ipinfoLite, isIPinfoTokenUnavailable {
            RuntimeLog.shared.info("provider_test_skipped", fields: ["provider": provider.rawValue, "reason": "token_unavailable"])
            return
        }
        let now = currentDate
        if let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > now {
            status = .providerPaused(provider, retryNotBefore)
            RuntimeLog.shared.info("provider_test_skipped", fields: [
                "provider": provider.rawValue,
                "reason": "provider_paused",
                "resumeAt": retryNotBefore.formatted(.iso8601)
            ])
            return
        }
        if lookupBudgetStore.load(now: now).isExhausted(provider, now: now) {
            let resetAt = LookupBudget.budgetResetDate(after: now)
            status = .coolingDown(resetAt)
            RuntimeLog.shared.info("provider_test_skipped", fields: [
                "provider": provider.rawValue,
                "reason": "daily_budget",
                "resumeAt": resetAt.formatted(.iso8601)
            ])
            return
        }
        await refresh(force: true, bypassMinimumInterval: true, trigger: .manual, preferredProvider: provider)
    }

    func runDebugSimulation(_ scenario: DebugSimulationScenario) {
        simulationMessage = "Simulation: \(scenario.displayName)"
        RuntimeLog.shared.info("debug_simulation_started", fields: ["scenario": scenario.rawValue])
        switch scenario {
        case .transportFailure:
            status = .failed("Simulated network transport failure")
            setError("Simulated transport failure")
        case .malformedResponse:
            status = .failed("Simulated malformed provider response")
            setError("Simulated malformed provider response")
        case .rateLimit:
            status = .providerPaused(preferences.provider, currentDate.addingTimeInterval(3600))
        case .countryDisagreement:
            status = .awaitingConfirmation("Simulated country disagreement; the last verified location remains active.")
        case .notAllowedAddress:
            authorizationState = .notAllowed(snapshot?.ipAddress ?? "203.0.113.8")
        }
        objectWillChange.send()
    }

    func clearDebugSimulation() {
        guard simulationMessage != nil else { return }
        simulationMessage = nil
        clearError()
        authorizationState = .unavailable
        if hasVerifiedAddressThisSession {
            evaluateAuthorization(for: snapshot?.ipAddress)
        } else {
            authorizationState = .unavailable
        }
        status = snapshot == nil ? .idle : .ready
        RuntimeLog.shared.info("debug_simulation_cleared")
        objectWillChange.send()
    }

    func setCountryChangeHighlightsEnabled(_ enabled: Bool) {
        var updatedPreferences = preferences
        updatedPreferences.highlightCountryChanges = enabled
        apply(updatedPreferences)
    }

    func refresh(
        force: Bool = false,
        bypassMinimumInterval: Bool = false,
        trigger: RefreshTrigger = .manual,
        urgency urgencyOverride: RefreshUrgency? = nil,
        preferredProvider: ProviderID? = nil
    ) async {
        let urgency = urgencyOverride ?? trigger.urgency
        RuntimeLog.shared.info("refresh_requested", fields: [
            "trigger": trigger.rawValue,
            "urgency": urgency.logName,
            "force": String(force),
            "startupBypass": String(bypassMinimumInterval),
            "provider": (preferredProvider ?? preferences.provider).rawValue
        ])
        guard !isRefreshing else {
            // A proxy or tunnel can finish changing while an earlier lookup is in
            // flight. Re-evaluate once that lookup completes, keeping the highest urgency;
            // the per-provider gap sends the recheck to the next pool provider.
            // Routine triggers don't need a recheck: the in-flight lookup already answers them.
            if force, urgency >= .followUp {
                recheckUrgency = max(recheckUrgency ?? urgency, urgency)
            }
            RuntimeLog.shared.info("refresh_coalesced_in_flight", fields: ["trigger": trigger.rawValue])
            return
        }
        var activeProvider = preferredProvider ?? preferences.provider
        let refreshGeneration = lifecycleGeneration
        // No credential read, network request, quota charge, or missing-token error is needed.
        // Keep the last verified snapshot visible until the user explicitly loads/saves a token.
        if isIPinfoTokenUnavailable,
           preferredProvider == .ipinfoLite || preferences.providerPool.allSatisfy({ $0 == .ipinfoLite }) {
            status = .waitingForIPinfoToken
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": "token_unavailable"])
            return
        }
        if !force, let snapshot,
           currentDate.timeIntervalSince(snapshot.checkedAt) < Double(preferences.refreshInterval.rawValue) {
            return
        }

        var budget = lookupBudgetStore.load(now: currentDate)
        // One shared decision covers refusal cooldowns, daily budgets, the per-provider gap, and the burst
        // allowance. A paused provider is skipped by normal rotation; the refused request itself was never
        // retried elsewhere. Startup bypasses the gap and the burst allowance once.
        let cooldowns = providerCooldowns()
        let decision = RefreshGate.decide(
            urgency: urgency,
            pool: preferences.providerPool,
            preferred: activeProvider,
            lastAttempts: refreshAttemptStore.lastAttempts(),
            excluded: ineligibleProviders(keeping: activeProvider),
            cooldowns: cooldowns,
            budget: &budget,
            lastSuccess: snapshot?.checkedAt,
            bypassLimits: bypassMinimumInterval,
            now: currentDate
        )
        lookupBudgetStore.save(budget)
        lookupBudget = budget
        switch decision {
        case .run(let provider, let rotatedFrom):
            if let rotatedFrom {
                let event = if budget.isExhausted(rotatedFrom) {
                    "provider_rotated_daily_budget"
                } else if let pausedUntil = cooldowns[rotatedFrom], pausedUntil > currentDate {
                    "provider_rotated_cooldown"
                } else {
                    "provider_rotated_spacing"
                }
                RuntimeLog.shared.info(event, fields: [
                    "from": rotatedFrom.rawValue,
                    "to": provider.rawValue,
                    "trigger": trigger.rawValue
                ])
                selectProvider(provider)
                activeProvider = provider
            }
        case .queue(let date, let reason):
            queueRefresh(at: date, urgency: urgency, trigger: trigger, reason: reason)
            return
        case .skip(let reason):
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": reason])
            return
        case .dailyBudgetExhausted(let resetAt):
            status = .coolingDown(resetAt)
            RuntimeLog.shared.info("lookup_daily_budget_exhausted", fields: [
                "provider": activeProvider.rawValue,
                "resetAt": resetAt.formatted(.iso8601)
            ])
            scheduleRetry(after: secondsUntil(resetAt))
            return
        case .allProvidersPaused(let resumeAt):
            // A pause is not an exit-IP error: the last verified result stays visible.
            status = .coolingDown(resumeAt)
            RuntimeLog.shared.info("lookup_all_providers_paused", fields: [
                "trigger": trigger.rawValue,
                "resumeAt": resumeAt.formatted(.iso8601)
            ])
            scheduleRetry(after: secondsUntil(resumeAt))
            return
        }

        // This lookup answers every earlier request, so a pending queued lookup is no longer needed.
        if let superseded = pendingRefresh.supersede() {
            minimumIntervalTask?.cancel()
            minimumIntervalTask = nil
            RuntimeLog.shared.info("refresh_queue_superseded", fields: [
                "trigger": trigger.rawValue,
                "notBefore": superseded.formatted(.iso8601)
            ])
        }
        refreshAttemptStore.recordAttempt(for: activeProvider, at: currentDate)
        updateProviderHealth(activeProvider) { record in
            record.lastAttempt = currentDate
        }
        isRefreshing = true
        status = .refreshing
        RuntimeLog.shared.info("lookup_started", fields: ["provider": activeProvider.rawValue])
        defer {
            isRefreshing = false
            if let urgency = recheckUrgency {
                recheckUrgency = nil
                Task { await self.refresh(force: true, trigger: .recheck, urgency: urgency) }
            }
        }

        do {
            let token = activeProvider == .ipinfoLite ? ipinfoToken : nil
            var fetched = try await lookup(
                configuration: LookupConfiguration(provider: activeProvider, ipinfoToken: token)
            )
            guard isStarted, refreshGeneration == lifecycleGeneration else {
                RuntimeLog.shared.info("lookup_discarded_after_stop", fields: ["provider": activeProvider.rawValue])
                return
            }
            guard let normalizedIP = IPAddressValidator.normalize(fetched.ipAddress) else {
                throw LookupError.invalidResponse
            }
            fetched.ipAddress = normalizedIP
            consecutiveFailures = 0
            temporarilyFailedProviders.removeAll()
            cooldownStore.clear(for: activeProvider)

            if let previous = snapshot,
               previous.hasValidCountryCode,
               fetched.hasValidCountryCode,
               previous.countryCode != fetched.countryCode {
                let confirmationProvider = CountryChangeConfirmationPolicy.secondaryProvider(for: activeProvider)
                if lookupBudgetStore.load(now: currentDate).isExhausted(confirmationProvider, now: currentDate) {
                    let resetAt = LookupBudget.budgetResetDate(after: currentDate)
                    RuntimeLog.shared.info("confirmation_deferred", fields: [
                        "provider": confirmationProvider.rawValue,
                        "from": previous.countryCode,
                        "to": fetched.countryCode,
                        "reason": "daily_budget"
                    ])
                    status = .awaitingConfirmation(
                        "Country change \(previous.countryCode) → \(fetched.countryCode) awaits \(confirmationProvider.displayName), whose daily request budget resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
                    )
                    markFreshAddress(fetched.ipAddress)
                    scheduleRetry(after: secondsUntil(resetAt))
                    return
                }
                if let retryNotBefore = cooldownStore.retryNotBefore(for: confirmationProvider), retryNotBefore > currentDate {
                    RuntimeLog.shared.info("confirmation_deferred", fields: [
                        "provider": confirmationProvider.rawValue,
                        "from": previous.countryCode,
                        "to": fetched.countryCode,
                        "reason": "provider_paused"
                    ])
                    status = .awaitingConfirmation(
                        "Country change \(previous.countryCode) → \(fetched.countryCode) awaits \(confirmationProvider.displayName), which requested a pause until \(retryNotBefore.formatted(date: .omitted, time: .shortened))."
                    )
                    markFreshAddress(fetched.ipAddress)
                    scheduleRetry(after: secondsUntil(retryNotBefore))
                    return
                }
                cooldownStore.clear(for: confirmationProvider)
                RuntimeLog.shared.info("confirmation_started", fields: [
                    "primary": activeProvider.rawValue,
                    "provider": confirmationProvider.rawValue,
                    "from": previous.countryCode,
                    "to": fetched.countryCode
                ])
                updateProviderHealth(confirmationProvider) { record in
                    record.lastAttempt = currentDate
                }
                var confirmationBudget = lookupBudgetStore.load(now: currentDate)
                confirmationBudget.recordCall(to: confirmationProvider)
                lookupBudgetStore.save(confirmationBudget)
                lookupBudget = confirmationBudget
                refreshAttemptStore.recordAttempt(for: confirmationProvider, at: currentDate)
                do {
                    let confirmation = try await confirmCountryChange(
                        primaryProvider: activeProvider,
                        ipinfoToken: token
                    )
                    cooldownStore.clear(for: confirmationProvider)
                    updateProviderHealth(confirmationProvider) { record in
                        record.lastSuccess = currentDate
                        record.lastFailure = nil
                        record.lastError = nil
                        record.consecutiveFailures = 0
                    }
                    RuntimeLog.shared.info("confirmation_result", fields: [
                        "provider": confirmationProvider.rawValue,
                        "country": confirmation.countryCode,
                        "agrees": String(confirmation.countryCode == fetched.countryCode)
                    ])
                    guard confirmation.countryCode == fetched.countryCode else {
                        status = .awaitingConfirmation(
                            "Country change \(previous.countryCode) → \(fetched.countryCode) is unconfirmed: \(confirmationProvider.displayName) reports \(confirmation.countryName). Keeping the last verified location while checking the exit IP."
                        )
                        markFreshAddress(fetched.ipAddress)
                        return
                    }
                } catch {
                    updateProviderHealth(confirmationProvider) { record in
                        record.lastFailure = currentDate
                        record.lastError = lookupErrorCategory(error)
                        record.consecutiveFailures += 1
                    }
                    RuntimeLog.shared.error("confirmation_failed", fields: [
                        "provider": confirmationProvider.rawValue,
                        "category": lookupErrorCategory(error)
                    ])
                    if let lookupError = error as? LookupError, lookupError.pausesProvider {
                        let retryNotBefore = lookupError.retryAfter ?? currentDate.addingTimeInterval(RefreshPolicy.fallbackRateLimitCooldown)
                        cooldownStore.save(retryNotBefore: retryNotBefore, for: confirmationProvider)
                        scheduleRetry(after: secondsUntil(retryNotBefore))
                    }
                    status = .awaitingConfirmation(
                        "Country change \(previous.countryCode) → \(fetched.countryCode) needs confirmation from \(confirmationProvider.displayName). Keeping the last verified location while checking the exit IP."
                    )
                    markFreshAddress(fetched.ipAddress)
                    return
                }
            }

            commitVerifiedSnapshot(fetched)
            markFreshAddress(fetched.ipAddress)
            updateProviderHealth(activeProvider) { record in
                record.lastSuccess = currentDate
                record.lastError = nil
                record.consecutiveFailures = 0
            }
            RuntimeLog.shared.info("lookup_succeeded", fields: [
                "provider": fetched.provider.rawValue,
                "country": fetched.countryCode
            ])
        } catch {
            if error is CancellationError {
                RuntimeLog.shared.info("lookup_cancelled", fields: ["provider": activeProvider.rawValue])
                return
            }
            if let lookupError = error as? LookupError, lookupError.pausesProvider {
                updateProviderHealth(activeProvider) { record in
                    record.lastFailure = currentDate
                    record.lastError = lookupError.category
                    record.consecutiveFailures += 1
                }
                let retryNotBefore = lookupError.retryAfter ?? currentDate.addingTimeInterval(RefreshPolicy.fallbackRateLimitCooldown)
                cooldownStore.save(retryNotBefore: retryNotBefore, for: activeProvider)
                // A refusal pauses only this provider; it is not an exit-IP error, so the last verified
                // location stays visible. The refused request is not retried on another vendor; the next
                // trigger simply starts on the next pool provider, as after any lookup.
                RuntimeLog.shared.error("lookup_rate_limited", fields: [
                    "provider": activeProvider.rawValue,
                    "category": lookupError.category,
                    "retryNotBefore": retryNotBefore.formatted(.iso8601)
                ])
                if advanceProvider(after: activeProvider) != nil {
                    status = .providerPaused(activeProvider, retryNotBefore)
                } else {
                    status = .coolingDown(providerCooldowns().values.min() ?? retryNotBefore)
                }
                scheduleRetry(after: secondsUntil(retryNotBefore))
                return
            }
            consecutiveFailures += 1
            updateProviderHealth(activeProvider) { record in
                record.lastFailure = currentDate
                record.lastError = lookupErrorCategory(error)
                record.consecutiveFailures += 1
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            setError("Unable to check the exit IP with \(activeProvider.displayName): \(message)")
            RuntimeLog.shared.error("lookup_failed", fields: [
                "provider": activeProvider.rawValue,
                "message": message,
                "category": lookupErrorCategory(error)
            ])
            guard let lookupError = error as? LookupError,
                  lookupError.supportsResilienceRetry else {
                return
            }
            temporarilyFailedProviders.insert(activeProvider)
            if let nextProvider = advanceProvider(after: activeProvider) {
                RuntimeLog.shared.info("provider_rotated_after_failure", fields: [
                    "from": activeProvider.rawValue,
                    "to": nextProvider.rawValue,
                    "category": lookupErrorCategory(error)
                ])
                let delay = max(
                    RefreshPolicy.minimumRefreshSpacing,
                    lookupError.retryAfter.map(secondsUntil) ?? 0
                )
                scheduleRetry(after: delay)
            } else {
                temporarilyFailedProviders.removeAll()
                scheduleResilienceRetryIfAppropriate(for: error)
            }
        }
    }

    func clearError() {
        RuntimeLog.shared.info("error_cleared")
        indicators.errorMessage = nil
        indicatorStore.save(indicators)
        if case .failed = status {
            status = snapshot == nil ? .idle : .ready
        }
        objectWillChange.send()
        reloadSystemSurfaces()
    }

    func clearIndicators() {
        clearError()
        dismissCountryChangeHighlight()
    }

    func dismissCountryChangeHighlight() {
        RuntimeLog.shared.info("country_change_dismissed")
        guard var updated = snapshot else { return }
        updated.countryChange = nil
        snapshot = updated
        snapshotStore.save(updated)
        reloadSystemSurfaces()
        highlightExpiryTask?.cancel()
    }

    private func commitVerifiedSnapshot(_ fetched: ExitIPSnapshot) {
        var updated = CountryChangeDetector.applyingCountryChange(to: fetched, previous: snapshot)
        if !preferences.highlightCountryChanges {
            updated.countryChange = nil
        }
        let shouldReloadWidget = updated.hasWidgetContentChange(comparedTo: snapshot)
        snapshot = updated
        snapshotStore.save(updated)
        indicators = MonitorIndicatorState()
        indicatorStore.save(indicators)
        _ = advanceProvider(after: fetched.provider)
        status = .ready
        reloadSystemSurfaces(reloadWidget: shouldReloadWidget)
        scheduleHighlightExpiry()
    }

    private func markFreshAddress(_ address: String) {
        hasVerifiedAddressThisSession = true
        evaluateAuthorization(for: address)
    }

    /// Warn-only allowlist: an address outside a non-empty list opens the warning window once per address
    /// and shows a notice in the dashboard. It never blocks traffic, never sets the error
    /// indicator, and never hides the location. Only fresh, successful lookups reach this.
    private func evaluateAuthorization(for address: String?) {
        guard let address, !allowedIPList.isEmpty, !allowedIPList.contains(address) else {
            authorizationState = (address == nil || allowedIPList.isEmpty) ? .unavailable : .allowed
            warningPresentedForAddress = nil
            if AllowlistWarningWindowController.shared.isPresented {
                AllowlistWarningWindowController.shared.dismiss()
                RuntimeLog.shared.info("allowlist_warning_cleared")
            }
            return
        }
        authorizationState = .notAllowed(address)
        guard warningPresentedForAddress != address else { return }
        warningPresentedForAddress = address
        AllowlistWarningWindowController.shared.show(address: address)
        RuntimeLog.shared.info("allowlist_warning_presented", fields: ["ip": address])
    }

    private func setError(_ message: String) {
        RuntimeLog.shared.error("indicator_error_set", fields: ["message": message])
        indicators = MonitorIndicatorState(errorMessage: message, suppressLocation: true)
        indicatorStore.save(indicators)
        objectWillChange.send()
        reloadSystemSurfaces()
    }

    private func updateProviderHealth(_ provider: ProviderID, update: (inout ProviderHealthRecord) -> Void) {
        var record = providerHealth[provider] ?? ProviderHealthRecord()
        update(&record)
        providerHealth[provider] = record
        providerHealthStore.save(record, for: provider)
        RuntimeLog.shared.info("provider_health_changed", fields: [
            "provider": provider.rawValue,
            "consecutiveFailures": String(record.consecutiveFailures),
            "lastError": record.lastError ?? ""
        ])
    }

    /// Cancels cooperative provider clients after 15 seconds. Timeouts use the normal
    /// transport-failure rotation and backoff path. The HTTP session also bounds resource time.
    private func lookup(configuration: LookupConfiguration) async throws -> ExitIPSnapshot {
        let providerClient = client
        return try await withThrowingTaskGroup(of: ExitIPSnapshot.self) { group in
            group.addTask {
                return try await providerClient.lookup(configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LookupError.transport("The provider request timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func confirmCountryChange(
        primaryProvider: ProviderID,
        ipinfoToken: String?
    ) async throws -> ExitIPSnapshot {
        let providerClient = client
        return try await withThrowingTaskGroup(of: ExitIPSnapshot.self) { group in
            group.addTask {
                try await providerClient.confirmCountryChange(
                    primaryProvider: primaryProvider,
                    ipinfoToken: ipinfoToken
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LookupError.transport("The confirmation request timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func advanceProvider(after provider: ProviderID) -> ProviderID? {
        let pool = preferences.providerPool
        guard pool.count > 1, let index = pool.firstIndex(of: provider) else { return nil }
        guard case .use(let candidate) = RefreshPolicy.providerSelection(
            pool: pool,
            preferred: pool[(index + 1) % pool.count],
            lastAttempts: [:],
            excluded: ineligibleProviders(keeping: nil).union([provider])
        ) else { return nil }
        selectProvider(candidate)
        return candidate
    }

    /// Providers that pool rotation must skip: used-up daily budget, a refusal cooldown, or a temporary
    /// failure in the current rotation. `kept` (the active provider) is never excluded for a temporary
    /// failure, so a refresh can still start on it.
    private func ineligibleProviders(keeping kept: ProviderID?) -> Set<ProviderID> {
        let budget = lookupBudgetStore.load(now: currentDate)
        let now = currentDate
        let tokenUnavailable = isIPinfoTokenUnavailable
        return Set(preferences.providerPool.filter { candidate in
            if budget.isExhausted(candidate, now: now) { return true }
            if candidate == .ipinfoLite, tokenUnavailable { return true }
            if let retryNotBefore = cooldownStore.retryNotBefore(for: candidate), retryNotBefore > now { return true }
            if candidate == kept { return false }
            return temporarilyFailedProviders.contains(candidate)
        })
    }

    /// The refusal cooldown deadline for `provider`, if it is still paused. Read-only, for display.
    func pausedUntil(_ provider: ProviderID) -> Date? {
        guard let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > currentDate else { return nil }
        return retryNotBefore
    }

    /// Refusal deadlines still in the future, for the pool and the active provider.
    private func providerCooldowns() -> [ProviderID: Date] {
        let now = currentDate
        var cooldowns: [ProviderID: Date] = [:]
        for provider in Set(preferences.providerPool + [preferences.provider]) {
            if let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > now {
                cooldowns[provider] = retryNotBefore
            }
        }
        return cooldowns
    }

    private func selectProvider(_ provider: ProviderID) {
        var updated = preferences
        updated.provider = provider
        preferences = updated
        updated.save()
    }

    private func lookupErrorCategory(_ error: Error) -> String {
        (error as? LookupError)?.category ?? "unknown"
    }

    private func schedulePeriodicRefresh() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(preferences.refreshInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: true, trigger: .periodic)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func startWorkspaceMonitoring() {
        guard workspaceObservers.isEmpty else { return }

        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        let notifications: [(Notification.Name, RefreshTrigger)] = [
            (NSWorkspace.didWakeNotification, .systemWake),
            (NSWorkspace.screensDidWakeNotification, .screensWake),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)
        ]

        workspaceObservers = notifications.map { name, trigger in
            notificationCenter.addObserver(forName: name, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleEventTrigger(trigger)
                }
            }
        }
    }

    private func startNetworkPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkPathSignature(path)
            Task { @MainActor in
                guard let self else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                defer { self.receivedInitialPath = true }
                guard self.receivedInitialPath, path.status == .satisfied else { return }
                // NWPathMonitor also reports updates in which nothing observable changed. A network change
                // always spends a lookup, so only a different path counts; proxy, DNS, and route changes
                // that keep the same path are reported by the SystemConfiguration and routing observers.
                guard signature != previous else {
                    RuntimeLog.shared.info("network_path_unchanged")
                    return
                }
                self.handleEventTrigger(.networkPath)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /// Event-driven refreshes run immediately, then wait: events inside the following
    /// `RefreshPolicy.eventWindow` are merged into one trailing lookup at its end. The per-provider gap in
    /// `refresh` sends that trailing lookup to the next provider, so neither lookup has to queue.
    private func handleEventTrigger(_ trigger: RefreshTrigger) {
        switch eventWindow.register(trigger.urgency, now: currentDate) {
        case .runNow(let windowEndsAt):
            scheduleEventWindowEnd(at: windowEndsAt)
            Task { await refresh(force: true, trigger: trigger) }
        case .mergedIntoTrailing(let windowEndsAt):
            RuntimeLog.shared.info("refresh_event_merged", fields: [
                "trigger": trigger.rawValue,
                "trailingAt": windowEndsAt.formatted(.iso8601)
            ])
        case .absorbed:
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": "event_window"])
        }
    }

    private func scheduleEventWindowEnd(at date: Date) {
        eventWindowTask?.cancel()
        eventWindowTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.secondsUntil(date) ?? 0))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.eventWindowTask = nil
            guard let trailing = self.eventWindow.takeTrailing(now: self.currentDate) else { return }
            self.scheduleEventWindowEnd(at: trailing.windowEndsAt)
            await self.refresh(force: true, trigger: .trailing, urgency: trailing.urgency)
        }
    }

    private func queueRefresh(at date: Date, urgency: RefreshUrgency, trigger: RefreshTrigger, reason: String) {
        // Keep the earliest pending boundary; a later request must not postpone an earlier one.
        if pendingRefresh.enqueue(at: date, urgency: urgency) || minimumIntervalTask == nil {
            scheduleRefreshAfterMinimumInterval(pendingRefresh.notBefore ?? date)
        }
        status = .waitingForMinimumInterval(pendingRefresh.notBefore ?? date)
        RuntimeLog.shared.info("refresh_queued", fields: [
            "trigger": trigger.rawValue,
            "urgency": urgency.logName,
            "reason": reason,
            "notBefore": (pendingRefresh.notBefore ?? date).formatted(.iso8601)
        ])
    }

    private func scheduleRefreshAfterMinimumInterval(_ date: Date) {
        minimumIntervalTask?.cancel()
        minimumIntervalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.secondsUntil(date) ?? 0))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.minimumIntervalTask = nil
            let urgency = self.pendingRefresh.take() ?? .networkChange
            await self.refresh(force: true, trigger: .queued, urgency: urgency)
        }
    }

    private func scheduleResilienceRetryIfAppropriate(for error: Error) {
        guard let lookupError = error as? LookupError,
              lookupError.supportsResilienceRetry else { return }

        let delay: TimeInterval
        if let retryAfter = lookupError.retryAfter {
            delay = max(0, secondsUntil(retryAfter))
        } else {
            delay = RefreshPolicy.retryDelay(forConsecutiveFailure: consecutiveFailures)
        }

        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.retryTask = nil
            await self.refresh(force: true, trigger: .retry)
        }
    }

    private func scheduleHighlightExpiry() {
        highlightExpiryTask?.cancel()
        guard let snapshot,
              let highlightUntil = snapshot.countryChange?.highlightUntil,
              highlightUntil > currentDate else { return }

        highlightExpiryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.secondsUntil(highlightUntil)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.dismissCountryChangeHighlight()
        }
    }

    private func reloadSystemSurfaces(reloadWidget: Bool = true) {
        if reloadWidget {
            RuntimeLog.shared.info("widget_reload_requested")
            WidgetCenter.shared.reloadTimelines(ofKind: ExitIPSurfaceID.widget)
        }
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ExitIPSurfaceID.control)
        }
    }
}

/// The parts of an `NWPath` that can change the exit IP: reachability, the interfaces in use (and their
/// order), gateways, and address families.
private struct NetworkPathSignature: Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let gateways: [String]
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    init(_ path: NWPath) {
        status = String(describing: path.status)
        interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }
        gateways = path.gateways.map { String(describing: $0) }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }
}
