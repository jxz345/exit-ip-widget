import Foundation

public enum ExitIPAppGroup {
    /// Replace this value with the App Group registered for both Xcode targets.
    #if EXIT_IP_TEST_HOST
    public static let identifier = ProcessInfo.processInfo.environment["EXIT_IP_TEST_APP_GROUP"]!
    #else
    public static let identifier = "group.com.example.exitipmonitor"
    #endif

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

public enum ExitIPPreferenceKey {
    public static let snapshot = "exit-ip.snapshot.v1"
    public static let provider = "exit-ip.provider.v1"
    public static let providerPool = "exit-ip.provider-pool.v1"
    public static let allowedIPs = "exit-ip.allowed-ips.v1"
    public static let refreshInterval = "exit-ip.refresh-interval.v1"
    public static let menuBarDisplayStyle = "exit-ip.menu-bar-display-style.v1"
    public static let highlightCountryChanges = "exit-ip.highlight-country-changes.v1"
    public static let providerCooldownPrefix = "exit-ip.provider-cooldown.v1."
    /// Superseded by the per-provider `lastRefreshAttemptPrefix`; only removed on `RefreshAttemptStore.clear()`.
    public static let legacyLastRefreshAttempt = "exit-ip.last-refresh-attempt.v1"
    public static let lastRefreshAttemptPrefix = "exit-ip.last-refresh-attempt.v2."
    public static let indicatorState = "exit-ip.indicator-state.v1"
    public static let lookupBudget = "exit-ip.lookup-budget.v1"
    public static let providerHealthPrefix = "exit-ip.provider-health.v1."
    public static let diagnostics = "exit-ip.diagnostics.v1"
    /// Set once the dashboard has been shown on the app's first launch.
    public static let firstLaunchDashboardShown = "exit-ip.first-launch-dashboard-shown.v1"
    /// The user's Launch at login choice (absent: never chosen). Re-applied at every launch.
    public static let launchAtLogin = "exit-ip.launch-at-login.v1"
}
