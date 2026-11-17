import Combine
import Foundation

@MainActor
final class DaemonService: NSObject, NSXPCListenerDelegate {
    private let storage: FilePreferenceStorage
    let engine: MonitoringEngine
    private let provider: TailscaleProviderService
    private let instanceID = UUID()
    private var settings: MachineSettings
    private var revision: Int
    private var initialized: Bool
    private var sessions: [UUID: DaemonSession] = [:]
    private var observation: AnyCancellable?
    private var publicationPending = false
    private var lastAuthorization: ExitIPAuthorizationState = .unavailable
    private var lastError: String?
    private var allowlistEventID: UUID?
    private var errorEventID: UUID?
    private var lastManualRequest = Date.distantPast
    private var mutationInProgress = false
    private let authorize: @Sendable (Data?) -> Bool

    init(storage: FilePreferenceStorage, observeSystem: Bool = true,
         credentials: any CredentialBackend = SystemCredentials(),
         client: any PublicIPLookupClientProtocol = PublicIPLookupClient(),
         authorize: @escaping @Sendable (Data?) -> Bool = ServiceAuthorization.validate) throws {
        self.storage = storage
        self.authorize = authorize
        if let data = storage.data(forKey: "service.settings") {
            settings = try JSONDecoder().decode(MachineSettings.self, from: data).validated()
            initialized = true
        } else {
            settings = MachineSettings()
            initialized = false
        }
        revision = storage.integer(forKey: "service.revision")
        engine = MonitoringEngine(
            preferencesStore: storage, observeSystem: observeSystem,
            snapshotStore: SnapshotStore(defaults: storage), cooldownStore: ProviderCooldownStore(defaults: storage),
            refreshAttemptStore: RefreshAttemptStore(defaults: storage), lookupBudgetStore: LookupBudgetStore(defaults: storage),
            indicatorStore: IndicatorStore(defaults: storage), allowedIPStore: AllowedIPStore(defaults: storage),
            providerHealthStore: ProviderHealthStore(defaults: storage), diagnosticPreferencesStore: DiagnosticPreferencesStore(defaults: storage),
            client: client, ipinfoCredentials: CredentialSession(service: CredentialService(backend: credentials),
                                                               account: SecureTokenStore.ipinfoLiteAccount))
        provider = TailscaleProviderService()
        super.init()
        RuntimeLog.shared.configure(settings.diagnostics)
        observation = engine.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.schedulePublication() }
        }
        provider.changed = { [weak self] in self?.schedulePublication() }
    }

    func start() async {
        guard initialized else { return }
        _ = await engine.ipinfoCredentials.load()
        engine.start()
        provider.setEnabled(settings.tailscaleProviderEnabled)
        schedulePublication()
        RuntimeLog.shared.info("daemon_ready", fields: ["instance": instanceID.uuidString])
    }

    func stop() {
        engine.stop()
        provider.setEnabled(false)
        for session in sessions.values { session.connection.invalidate() }
        sessions.removeAll()
        RuntimeLog.shared.info("daemon_stopped")
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = DaemonSession(service: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: ExitIPDaemonProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ExitIPDaemonObserver.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak session] in
            guard let id = session?.id else { return }
            Task { @MainActor [weak self] in self?.sessions.removeValue(forKey: id) }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        return true
    }

    func handle(_ request: DaemonRequest, session: DaemonSession) async -> DaemonResponse {
        await handle(request, uid: session.uid, session: session)
    }

    // The UID overload is internal for isolated tests; only the kernel-derived session entry is exported.
    func handle(_ request: DaemonRequest, uid: uid_t, session: DaemonSession? = nil) async -> DaemonResponse {
        guard request.protocolVersion == ExitIPService.protocolVersion else { return DaemonResponse(failure: .incompatible) }
        do {
            switch request.command {
            case .state: return DaemonResponse(state: state(for: uid))
            case .subscribe:
                guard let session else { throw DaemonFailure.invalidRequest }
                guard sessions.count < 128 || sessions[session.id] != nil else { throw DaemonFailure.unavailable }
                sessions[session.id] = session
            case .refresh, .testProvider:
                if request.command == .testProvider {
                    guard let selected = request.provider, settings.providerPool.contains(selected) else { throw DaemonFailure.invalidRequest }
                }
                guard initialized else { throw DaemonFailure.invalidRequest }
                // Concurrent users share the same in-flight lookup and cannot create a request storm.
                if Date().timeIntervalSince(lastManualRequest) >= 1 {
                    lastManualRequest = Date()
                    let selected = request.provider
                    Task { [engine] in
                        if request.command == .testProvider, let selected { await engine.testProvider(selected) }
                        else { await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .manual) }
                    }
                }
            case .presentation:
                guard let value = request.presentation else { throw DaemonFailure.invalidRequest }
                try storage.update(["user.\(uid).presentation": try JSONEncoder().encode(value)])
                RuntimeLog.shared.info("user_presentation_changed", fields: ["uid": String(uid)])
            case .configure, .initialize, .setToken, .removeToken:
                guard authorize(request.authorization) else { throw DaemonFailure.unauthorized }
                guard !mutationInProgress, request.expectedRevision == revision else { throw DaemonFailure.conflict }
                mutationInProgress = true
                defer { mutationInProgress = false }
                if request.command == .initialize || request.command == .configure {
                    if request.command == .initialize, initialized { throw DaemonFailure.alreadyInitialized }
                    guard request.command == .initialize || initialized else { throw DaemonFailure.invalidRequest }
                    guard let next = request.migration?.settings ?? request.settings else { throw DaemonFailure.invalidRequest }
                    let validated = try next.validated()
                    var updates: [String: Any?] = [
                        "service.settings": try JSONEncoder().encode(validated), "service.revision": revision + 1,
                        ExitIPPreferenceKey.provider: validated.provider.rawValue,
                        ExitIPPreferenceKey.providerPool: validated.providerPool.map(\.rawValue).joined(separator: ","),
                        ExitIPPreferenceKey.refreshInterval: validated.refreshInterval.rawValue,
                        ExitIPPreferenceKey.allowedIPs: try JSONEncoder().encode(validated.allowlist),
                        ExitIPPreferenceKey.diagnostics: try JSONEncoder().encode(validated.diagnostics)
                    ]
                    if request.command == .initialize, let migration = request.migration {
                        updates[ExitIPPreferenceKey.lookupBudget] = try JSONEncoder().encode(migration.budget)
                        if let snapshot = migration.snapshot { updates[ExitIPPreferenceKey.snapshot] = try JSONEncoder().encode(snapshot) }
                        for (provider, date) in migration.attempts { updates[ExitIPPreferenceKey.lastRefreshAttemptPrefix + provider.rawValue] = date }
                        for (provider, date) in migration.cooldowns { updates[ExitIPPreferenceKey.providerCooldownPrefix + provider.rawValue] = date }
                    }
                    try storage.update(updates)
                    let wasInitialized = initialized
                    settings = validated
                    revision += 1
                    initialized = true
                    engine.apply(settings.monitoring)
                    engine.setAllowedIPList(settings.allowlist)
                    engine.applyDiagnosticPreferences(settings.diagnostics)
                    RuntimeLog.shared.configure(settings.diagnostics)
                    if wasInitialized { provider.setEnabled(settings.tailscaleProviderEnabled) }
                    else { engine.reloadBeforeStart(); await start() }
                    RuntimeLog.shared.info(wasInitialized ? "shared_settings_changed" : "shared_settings_initialized",
                                           fields: ["uid": String(uid), "revision": String(revision)])
                } else {
                    guard initialized else { throw DaemonFailure.invalidRequest }
                    if request.command == .setToken {
                        guard let token = request.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !token.isEmpty, token.utf8.count <= 4096 else { throw DaemonFailure.invalidRequest }
                        guard await engine.saveIPinfoToken(token) else { throw DaemonFailure.credential }
                    } else {
                        guard await engine.removeIPinfoToken() else { throw DaemonFailure.credential }
                    }
                    try storage.update(["service.revision": revision + 1])
                    revision += 1
                    RuntimeLog.shared.info("shared_credential_changed", fields: ["uid": String(uid)])
                }
            case .events:
                return DaemonResponse(state: state(for: uid), events: RuntimeLog.shared.recentLines())
            }
            publish()
            return DaemonResponse(state: state(for: uid))
        } catch let failure as DaemonFailure {
            return DaemonResponse(state: state(for: uid), failure: failure)
        } catch {
            RuntimeLog.shared.error("daemon_storage_failed", fields: ["error": error.localizedDescription])
            return DaemonResponse(state: state(for: uid), failure: .storage)
        }
    }

    func state(for uid: uid_t) -> DaemonState {
        let presentation = storage.data(forKey: "user.\(uid).presentation")
            .flatMap { try? JSONDecoder().decode(UserPresentationPreferences.self, from: $0) } ?? UserPresentationPreferences()
        let cooldowns = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
            engine.pausedUntil(provider).map { (provider, $0) }
        })
        return DaemonState(instanceID: instanceID, build: "3.0", initialized: initialized, revision: revision,
                           settings: settings, presentation: presentation, snapshot: engine.snapshot, status: engine.status,
                           indicators: engine.indicators, authorizationState: engine.authorizationState,
                           providerHealth: engine.providerHealth, budget: engine.lookupBudget, nextProvider: engine.preferences.provider, cooldowns: cooldowns,
                           hasIPinfoToken: !engine.isIPinfoTokenUnavailable, credentialError: engine.ipinfoCredentials.errorMessage,
                           allowlistEventID: allowlistEventID, errorEventID: errorEventID,
                           providerStatus: provider.status, providerError: provider.error, storageError: storage.lastError)
    }

    private func schedulePublication() {
        guard !publicationPending else { return }
        publicationPending = true
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }

    private func publish() {
        publicationPending = false
        if engine.authorizationState != lastAuthorization {
            lastAuthorization = engine.authorizationState
            allowlistEventID = engine.authorizationState.isNotAllowed ? UUID() : nil
        }
        if engine.indicators.errorMessage != lastError {
            lastError = engine.indicators.errorMessage
            errorEventID = lastError == nil ? nil : UUID()
        }
        for session in sessions.values {
            guard let data = try? JSONEncoder().encode(state(for: session.uid)) else { continue }
            (session.connection.remoteObjectProxyWithErrorHandler { _ in session.connection.invalidate() } as? ExitIPDaemonObserver)?.changed(data)
        }
    }
}

final class DaemonSession: NSObject, ExitIPDaemonProtocol, @unchecked Sendable {
    let id = UUID()
    let uid: uid_t
    let connection: NSXPCConnection
    private let service: DaemonService
    init(service: DaemonService, connection: NSXPCConnection) {
        self.service = service
        self.connection = connection
        uid = connection.effectiveUserIdentifier
    }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= ExitIPService.maximumMessageSize,
              let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data())
            return
        }
        Task { @MainActor in
            let response = await service.handle(request, session: self)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
