import Foundation

/// Allowlist result for the last verified address. The allowlist only warns; it never blocks traffic.
public enum ExitIPAuthorizationState: Codable, Equatable, Sendable {
    /// The allowlist is empty (no warnings) or no address has been verified this session.
    case unavailable
    case allowed
    case notAllowed(String)

    public var isNotAllowed: Bool {
        if case .notAllowed = self { return true }
        return false
    }
}


public enum MonitoringStatus: Codable, Equatable, Sendable {
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


public enum ExitIPService {
    public static let label = "com.example.exitipmonitor.daemon"
    public static let protocolVersion = 1
    public static let executable = "/Library/PrivilegedHelperTools/com.example.exitipmonitor.daemon"
    public static let plist = "/Library/LaunchDaemons/\(label).plist"
    public static let support = URL(fileURLWithPath: "/Library/Application Support/ExitIPMonitor", isDirectory: true)
    public static let storageURL = support.appendingPathComponent("Service/state.plist")
    public static let logDirectory = URL(fileURLWithPath: "/Library/Logs/ExitIPMonitor", isDirectory: true)
    public static let settingsRight = "com.example.exitipmonitor.configure"
    public static let maximumMessageSize = 1_048_576
}

public struct MachineSettings: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var providerPool: [ProviderID]
    public var refreshInterval: RefreshInterval
    public var allowlist: AllowedIPList
    public var diagnostics: DiagnosticPreferences
    public var tailscaleProviderEnabled: Bool

    public init(preferences: MonitoringPreferences = MonitoringPreferences(), allowlist: AllowedIPList = AllowedIPList(),
                diagnostics: DiagnosticPreferences = DiagnosticPreferences(), tailscaleProviderEnabled: Bool = false) {
        provider = preferences.provider
        providerPool = preferences.providerPool
        refreshInterval = preferences.refreshInterval
        self.allowlist = allowlist
        self.diagnostics = diagnostics
        self.tailscaleProviderEnabled = tailscaleProviderEnabled
    }

    public var monitoring: MonitoringPreferences {
        MonitoringPreferences(provider: provider, providerPool: providerPool, refreshInterval: refreshInterval)
    }

    public func validated() throws -> MachineSettings {
        guard !providerPool.isEmpty, providerPool.count <= ProviderID.allCases.count,
              Set(providerPool).count == providerPool.count, providerPool.contains(provider),
              [1, 7, 30].contains(diagnostics.retentionDays), allowlist.addresses.count <= 1024,
              allowlist.addresses.allSatisfy({ IPAddressValidator.normalize($0) == $0 }) else {
            throw DaemonFailure.invalidRequest
        }
        return self
    }
}

public struct UserPresentationPreferences: Codable, Equatable, Sendable {
    public var imported = false
    public var displayStyle: MenuBarDisplayStyle = .flag
    public var highlightCountryChanges = true
    public var dismissedCountryChange: Date?
    public var dismissedError: UUID?
    public var seenAllowlistEvent: UUID?
    public init() {}
}

public struct MigrationState: Codable, Sendable {
    public var settings: MachineSettings
    public var budget: LookupBudget
    public var attempts: [ProviderID: Date]
    public var cooldowns: [ProviderID: Date]
    public var snapshot: ExitIPSnapshot?
    public init(settings: MachineSettings, budget: LookupBudget, attempts: [ProviderID: Date], cooldowns: [ProviderID: Date], snapshot: ExitIPSnapshot? = nil) {
        self.settings = settings
        self.budget = budget
        self.attempts = attempts
        self.cooldowns = cooldowns
        self.snapshot = snapshot
    }
}

public struct DaemonState: Codable, Sendable {
    public var protocolVersion = ExitIPService.protocolVersion
    public var instanceID: UUID
    public var build: String
    public var initialized: Bool
    public var revision: Int
    public var settings: MachineSettings
    public var presentation: UserPresentationPreferences
    public var snapshot: ExitIPSnapshot?
    public var status: MonitoringStatus
    public var indicators: MonitorIndicatorState
    public var authorizationState: ExitIPAuthorizationState
    public var providerHealth: [ProviderID: ProviderHealthRecord]
    public var budget: LookupBudget
    public var nextProvider: ProviderID
    public var cooldowns: [ProviderID: Date]
    public var hasIPinfoToken: Bool
    public var credentialError: String?
    public var allowlistEventID: UUID?
    public var errorEventID: UUID?
    public var providerStatus: TailscaleVergeStatus?
    public var providerError: String?
    public var storageError: String?

    public var preferences: MonitoringPreferences {
        var preferences = settings.monitoring
        preferences.menuBarDisplayStyle = presentation.displayStyle
        preferences.highlightCountryChanges = presentation.highlightCountryChanges
        return preferences
    }

    public var presentedSnapshot: ExitIPSnapshot? {
        guard var result = snapshot else { return nil }
        if !presentation.highlightCountryChanges || result.countryChange?.changedAt == presentation.dismissedCountryChange {
            result.countryChange = nil
        }
        return result
    }

    public var presentedIndicators: MonitorIndicatorState {
        var result = indicators
        if let errorEventID, presentation.dismissedError == errorEventID { result.errorMessage = nil }
        return result
    }
}

public enum DaemonCommand: String, Codable, Sendable {
    case state, subscribe, refresh, testProvider, configure, initialize, presentation, setToken, removeToken, events
}

public struct DaemonRequest: Codable, Sendable {
    public var protocolVersion = ExitIPService.protocolVersion
    public var command: DaemonCommand
    public var expectedRevision: Int?
    public var settings: MachineSettings?
    public var presentation: UserPresentationPreferences?
    public var migration: MigrationState?
    public var provider: ProviderID?
    public var token: String?
    public var authorization: Data?
    public init(_ command: DaemonCommand) { self.command = command }
}

public enum DaemonFailure: String, Error, Codable, LocalizedError, Sendable {
    case unavailable, incompatible, unauthorized, conflict, invalidRequest, storage, credential, alreadyInitialized
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The background service is unavailable. Install or repair it in the dashboard."
        case .incompatible: "The app and background service need matching versions. Update or repair the installation."
        case .unauthorized: "Administrator authentication is required to change shared settings."
        case .conflict: "Another user changed the shared settings. Review the latest values and try again."
        case .invalidRequest: "The requested settings are invalid."
        case .storage: "The background service could not save its state. Check the service log."
        case .credential: "The System Keychain operation failed. Check the credential status and try again."
        case .alreadyInitialized: "Shared settings have already been initialized and were not overwritten."
        }
    }
}

public struct DaemonResponse: Codable, Sendable {
    public var state: DaemonState?
    public var failure: DaemonFailure?
    public var events: [String]?
    public init(state: DaemonState? = nil, failure: DaemonFailure? = nil, events: [String]? = nil) {
        self.state = state
        self.failure = failure
        self.events = events
    }
}
