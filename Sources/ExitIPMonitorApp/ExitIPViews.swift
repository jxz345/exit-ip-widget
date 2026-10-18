import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarCountryLabel: View {
    let snapshot: ExitIPSnapshot?
    let displayStyle: MenuBarDisplayStyle
    let refreshInterval: RefreshInterval
    let indicators: MonitorIndicatorState
    let date: Date

    var body: some View {
        let isChanged = !indicators.suppressLocation && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        HStack(spacing: 3) {
            if indicators.suppressLocation {
                // A stop sign in place of the flag; text styles also say so in words.
                Image(systemName: ExitIPIndicatorSymbol.lookupError)
                if displayStyle != .flag {
                    Text("Exit IP error")
                        .lineLimit(1)
                }
            } else {
                Text(statusLabel(at: date))
                    .lineLimit(1)
                    .fontWeight(isChanged ? .bold : .regular)
            }
            if isChanged {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Country changed")
            }
        }
        .padding(.horizontal, isChanged ? 4 : 0)
        .padding(.vertical, isChanged ? 2 : 0)
        .background(isChanged ? Color.yellow.opacity(0.24) : .clear, in: Capsule())
        .accessibilityLabel(accessibilityText(at: date))
    }

    private func accessibilityText(at date: Date) -> String {
        if indicators.suppressLocation { return "Exit IP error" }
        guard let snapshot else { return "Exit IP location unavailable" }
        let stale = snapshot.isStale(at: date, threshold: Double(refreshInterval.rawValue * 2))
        if snapshot.isCountryChangeHighlighted(at: date) {
            return "Exit IP country changed from \(snapshot.countryChange?.previousName ?? "previous location") to \(snapshot.countryName)" + (stale ? ", data is stale" : "")
        }
        return "Exit IP country: \(snapshot.countryName)" + (stale ? ", data is stale" : "")
    }

    private func statusLabel(at date: Date) -> String {
        guard !indicators.suppressLocation else { return "Exit IP error" }
        guard let snapshot else { return "Locating" }
        let label = snapshot.menuBarLabel(style: displayStyle)
        return snapshot.isStale(at: date, threshold: Double(refreshInterval.rawValue * 2)) ? "Stale · \(label)" : label
    }
}

struct StatusPopoverView: View {
    @ObservedObject var monitor: PublicIPMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .notAllowed(let address) = monitor.authorizationState {
                AllowlistNotice(address: address)
            }
            SnapshotHeader(snapshot: monitor.snapshot, indicators: monitor.indicators)
            StaleDataNotice(
                snapshot: monitor.indicators.suppressLocation ? nil : monitor.snapshot,
                refreshInterval: monitor.preferences.refreshInterval,
                date: monitor.displayDate
            )
            Divider()
            SnapshotDetails(snapshot: monitor.indicators.suppressLocation ? nil : monitor.snapshot)
            Text(MonitoringRules.summary(interval: monitor.preferences.refreshInterval))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = monitor.indicators.errorMessage {
                IndicatorErrorView(message: errorMessage, clear: monitor.clearError)
            }

            if !monitor.indicators.suppressLocation,
               let snapshot = monitor.snapshot,
               let change = snapshot.countryChange,
               change.isHighlighted() {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Country changed from \(change.previousName) to \(snapshot.countryName)",
                        systemImage: "mappin.and.ellipse"
                    )
                    .font(.footnote.weight(.semibold))

                    HStack {
                        Button("Dismiss") { monitor.dismissCountryChangeHighlight() }
                            .buttonStyle(.borderless)
                        Button("Turn Off Highlights") { monitor.setCountryChangeHighlightsEnabled(false) }
                            .buttonStyle(.borderless)
                    }
                    .font(.footnote)
                }
                .padding(10)
                .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }

            if case .failed(let message) = monitor.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if case .awaitingConfirmation(let message) = monitor.status {
                Label(message, systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if case .coolingDown(let retryNotBefore) = monitor.status {
                Label(
                    "All providers paused until \(retryNotBefore.formatted(date: .omitted, time: .shortened))",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if case .providerPaused(let provider, let retryNotBefore) = monitor.status {
                Label(
                    "\(provider.displayName) paused until \(retryNotBefore.formatted(date: .omitted, time: .shortened)); using the next provider",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if case .waitingForMinimumInterval(let nextAllowed) = monitor.status {
                Label(
                    "Refresh queued for \(nextAllowed.formatted(date: .omitted, time: .standard))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    ExitIPAppDelegate.showSettings()
                } label: {
                    Image(systemName: "gear")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                Button("Open Dashboard") {
                    ExitIPAppDelegate.showDashboard()
                }
                Spacer()
                Button {
                    Task { await monitor.refresh(force: true) }
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.status == .refreshing)
            }

            Button("Clear indicators") { monitor.clearIndicators() }
                .buttonStyle(.borderless)
                .disabled(monitor.indicators.errorMessage == nil && monitor.snapshot?.countryChange == nil)

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Exit IP", systemImage: "power")
            }
        }
        .padding()
        .frame(width: 360)
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @State private var allowedIPInput = ""
    @State private var allowedIPStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Everything fits at the default size; scrolling only matters in a small window, and
            // the footer (Settings, status) stays visible either way.
            ScrollView {
                content
                    .padding(20)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            notices
            header
            // Two columns when the window is wide enough (the default), stacked otherwise.
            // ViewThatFits compares ideal widths, so each column states one (2 × 440 + 16).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    leftColumn
                        .frame(minWidth: 420, idealWidth: 440, maxWidth: .infinity, alignment: .topLeading)
                    rightColumn
                        .frame(minWidth: 420, idealWidth: 440, maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    leftColumn
                    rightColumn
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notices: some View {
        if case .notAllowed(let address) = monitor.authorizationState {
            AllowlistNotice(address: address)
        }
        if let errorMessage = monitor.indicators.errorMessage {
            IndicatorErrorView(message: errorMessage, clear: monitor.clearError)
        }
        if let snapshot = monitor.snapshot, !monitor.indicators.suppressLocation,
           let change = snapshot.countryChange, change.isHighlighted() {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                Text("Country changed from \(change.previousName) to \(snapshot.countryName)")
                Spacer()
                Button("Dismiss") { monitor.dismissCountryChangeHighlight() }
                    .buttonStyle(.borderless)
                Button("Turn Off Highlights") { monitor.setCountryChangeHighlightsEnabled(false) }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            SnapshotHeader(snapshot: monitor.snapshot, indicators: monitor.indicators)
            StaleDataNotice(
                snapshot: monitor.indicators.suppressLocation ? nil : monitor.snapshot,
                refreshInterval: monitor.preferences.refreshInterval,
                date: monitor.displayDate
            )
            Spacer()
            Button {
                Task { await monitor.refresh(force: true) }
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
            }
            .disabled(monitor.status == .refreshing)
        }
    }

    /// The exit IP itself, the allowlist that judges it, and (with the Tailscale daemon) the profile.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = monitor.snapshot {
                DashboardGroup("Current exit IP") {
                    DetailGrid {
                        DetailRow(label: "Public IP", value: snapshot.ipAddress)
                        if !monitor.indicators.suppressLocation {
                            DetailRow(label: "Country", value: "\(snapshot.countryFlag) \(snapshot.countryName) (\(snapshot.countryCode))")
                            DetailRow(label: "Location", value: snapshot.locationSummary.isEmpty ? "Not supplied by \(snapshot.provider.displayName)" : snapshot.locationSummary)
                        }
                        DetailRow(label: "Network", value: [snapshot.autonomousSystem, snapshot.organization].compactMap { $0 }.joined(separator: " · "))
                        DetailRow(label: "Timezone", value: snapshot.timezone ?? "Not supplied")
                        GridRow {
                            DetailLabel(text: "Updated")
                            HStack(spacing: 4) {
                                Text(lastUpdatedText(snapshot.checkedAt))
                                    .textSelection(.enabled)
                                Text("·")
                                Text(snapshot.checkedAt, style: .relative)
                                Text("ago")
                            }
                        }
                        DetailRow(label: "Source", value: snapshot.provider.displayName)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No public IP result yet",
                    systemImage: "network",
                    description: Text("The app will check when it can reach the selected service.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }

            DashboardGroup("Allowed exit IPs") {
                ForEach(monitor.allowedIPList.addresses, id: \.self) { address in
                    HStack {
                        Text(address).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) { monitor.removeAllowedIP(address) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("IPv4 or IPv6 address", text: $allowedIPInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        if monitor.addAllowedIP(allowedIPInput) {
                            allowedIPInput = ""
                            allowedIPStatus = nil
                        } else {
                            allowedIPStatus = "Enter a valid, non-duplicate IP address."
                        }
                    }
                }
                if let allowedIPStatus {
                    Text(allowedIPStatus)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                GroupCaption("Warns when a verified exit IP isn't listed. An empty list turns warnings off.")
            }

            if TailscaleVergeProvider.isInstalled() {
                ClashVergeProfileSection()
            }
        }
    }

    /// How the app is running: refresh setup, provider rotation, and the optional Tailscale daemon.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardGroup("Monitoring") {
                MonitoringSummary(monitor: monitor)
            }
            TailscaleVergeProviderSection()
            if TailscaleVergeProvider.isInstalled() {
                ClashVergeApplySteps()
            }
        }
    }

    /// The time alone for today's results, with the date otherwise.
    private func lastUpdatedText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .standard)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    ExitIPAppDelegate.showSettings()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                Button("Clear indicators") { monitor.clearIndicators() }
                    .buttonStyle(.borderless)
                    .disabled(monitor.indicators.errorMessage == nil && monitor.snapshot?.countryChange == nil)
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Exit IP", systemImage: "power")
                }
            }
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch monitor.status {
        case .idle: "Waiting for the first lookup"
        case .refreshing: "Checking the current public exit IP…"
        case .ready: MonitoringRules.summary(interval: monitor.preferences.refreshInterval)
        case .awaitingConfirmation(let message): message
        case .coolingDown(let retryNotBefore): "Every enabled provider is paused or out of its daily budget. Lookups resume at \(retryNotBefore.formatted(date: .abbreviated, time: .shortened)); the last verified result stays shown."
        case .providerPaused(let provider, let retryNotBefore): "\(provider.displayName) refused requests (rate limit, quota, or credentials) and is paused until \(retryNotBefore.formatted(date: .abbreviated, time: .shortened)). The next check uses another enabled provider."
        case .waitingForMinimumInterval(let nextAllowed): "A refresh is queued for \(nextAllowed.formatted(date: .omitted, time: .standard)) to honor the 5-second minimum interval."
        case .failed(let message): message
        }
    }
}

/// Shown in the popover and dashboard while the verified exit IP is outside the allowlist. Warn-only.
private struct AllowlistNotice: View {
    let address: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Exit IP not on the allowlist", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Verified exit IP \(address) is not in the allowed list. The connection is not blocked.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct StaleDataNotice: View {
    let snapshot: ExitIPSnapshot?
    let refreshInterval: RefreshInterval
    let date: Date

    var body: some View {
        if let snapshot, snapshot.isStale(at: date, threshold: Double(refreshInterval.rawValue * 2)) {
            Label(
                "Last verified \(snapshot.checkedAt.formatted(.relative(presentation: .named))); refresh is overdue",
                systemImage: "clock.badge.exclamationmark"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }
    }
}

private struct SnapshotHeader: View {
    let snapshot: ExitIPSnapshot?
    let indicators: MonitorIndicatorState

    var body: some View {
        HStack(spacing: 12) {
            if indicators.suppressLocation {
                // A stop sign in place of the flag while the exit IP can't be verified.
                Image(systemName: ExitIPIndicatorSymbol.lookupError)
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Exit IP error")
            } else {
                Text(snapshot?.countryFlag ?? "🌐")
                    .font(.system(size: 34))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(indicators.suppressLocation ? "Exit IP unavailable" : (snapshot?.countryName ?? "Locating exit IP"))
                    .font(.title3.weight(.semibold))
                Text(snapshot?.ipAddress ?? "No result yet")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IndicatorErrorView: View {
    let message: String
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Button("Clear error", action: clear)
                .buttonStyle(.borderless)
        }
        .font(.footnote)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SnapshotDetails: View {
    let snapshot: ExitIPSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let location = snapshot?.locationSummary, !location.isEmpty {
                Text(location)
                    .font(.callout)
            } else {
                Text("Location detail unavailable")
                    .font(.callout)
            }
            if let organization = snapshot?.organization {
                Text(organization)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let checkedAt = snapshot?.checkedAt {
                Text("Last updated \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(checkedAt.formatted(.relative(presentation: .named)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Every dashboard group's label column has this width, so labels and values line up down the page.
private let dashboardLabelWidth: CGFloat = 110

/// A dashboard group: a GroupBox with leading-aligned content and one spacing rule.
private struct DashboardGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}

/// The label/value grid used by every dashboard group.
private struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: dashboardLabelWidth, alignment: .leading)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            DetailLabel(text: label)
            Text(value.isEmpty ? "Not supplied" : value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A path or URL on one line (middle-truncated, full value as a tooltip) with its actions at the end.
private struct PathRow<Actions: View>: View {
    let label: String
    let value: String
    @ViewBuilder let actions: Actions

    init(label: String, value: String, @ViewBuilder actions: () -> Actions) {
        self.label = label
        self.value = value
        self.actions = actions()
    }

    var body: some View {
        GridRow {
            DetailLabel(text: label)
            HStack(spacing: 8) {
                Text(value)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
                    .controlSize(.small)
            }
        }
    }
}

/// The one explanatory line at the bottom of a group.
private struct GroupCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Opens a file read-only in TextEdit; `.yaml` has no default viewer on a stock Mac.
@MainActor
private func openInTextEdit(_ url: URL) {
    NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration())
}

/// Launch-at-login toggle shared by the dashboard and Settings. State is always read back from
/// `SMAppService`, so both windows (and changes made in System Settings) stay in agreement.
private struct LaunchAtLoginControl: View {
    /// The dashboard's one-row form: toggle and Login Items button side by side, explanation as help.
    var compact = false
    @State private var serviceStatus = SMAppService.mainApp.status
    @State private var errorMessage: String?

    private static let explanation = "When enabled, the menu-bar app starts at user login and checks immediately. Later event and manual checks use the 5-second minimum interval."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                HStack {
                    toggle
                    Spacer()
                    Button("Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                .help(Self.explanation)
            } else {
                toggle
                Text(Self.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !compact {
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        .onAppear { serviceStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            serviceStatus = SMAppService.mainApp.status
        }
    }

    private var toggle: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { serviceStatus == .enabled },
            set: { setEnabled($0) }
        ))
    }

    private var statusMessage: String? {
        if let errorMessage { return errorMessage }
        return serviceStatus == .requiresApproval ? "macOS requires approval in Login Items Settings." : nil
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        serviceStatus = SMAppService.mainApp.status
    }
}

/// Read-only summary of the monitoring configuration for the dashboard; edits happen in Settings.
private struct MonitoringSummary: View {
    @ObservedObject var monitor: PublicIPMonitor

    var body: some View {
        DetailGrid {
            // Multi-line values: top-align (same font as the label) so wrapping can't misplace the baseline.
            GridRow(alignment: .top) {
                DetailLabel(text: "Schedule")
                Text(MonitoringRules.summary(interval: monitor.preferences.refreshInterval))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DetailRow(label: "Highlights", value: monitor.preferences.highlightCountryChanges ? "On" : "Off")
            GridRow(alignment: .top) {
                DetailLabel(text: "Providers")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(monitor.preferences.providerPool.enumerated()), id: \.offset) { index, provider in
                        Text("\(index + 1). \(provider.displayName)\(providerState(provider))")
                            .fontWeight(provider == monitor.preferences.provider ? .semibold : .regular)
                    }
                }
            }
            // A checkbox has no text baseline; center this row so it can't shift the grid.
            GridRow(alignment: .center) {
                DetailLabel(text: "Login")
                LaunchAtLoginControl(compact: true)
            }
        }
        HStack {
            Button("Edit in Settings…") { ExitIPAppDelegate.showSettings() }
            Button("Event Log…") { ExitIPAppDelegate.showEventLog() }
        }
        .controlSize(.small)
    }

    private func providerState(_ provider: ProviderID) -> String {
        var notes: [String] = []
        if provider == monitor.preferences.provider { notes.append("next") }
        if provider == .ipinfoLite, monitor.isIPinfoMissingToken {
            notes.append("skipped: no token")
        } else if let pausedUntil = monitor.pausedUntil(provider) {
            notes.append("paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))")
        } else if monitor.lookupBudget.isExhausted(provider) {
            notes.append("daily budget used")
        }
        if let budget = LookupBudget.dailyBudget(for: provider) {
            notes.append("\(monitor.lookupBudget.callsToday(for: provider))/\(budget) today")
        }
        return notes.isEmpty ? "" : " · " + notes.joined(separator: " · ")
    }
}

/// Shown only while the optional Tailscale → Clash Verge daemon is installed (Sources/ExitIPDaemon):
/// where the provider file Clash reads lives, and where it is served. Reads the daemon's state file
/// every 2 seconds while visible; the app makes no request to the daemon.
private struct TailscaleVergeProviderSection: View {
    @State private var installed = false
    @State private var status: TailscaleVergeStatus?

    var body: some View {
        // A VStack rather than a Group, so the polling task runs even while nothing is shown.
        VStack(alignment: .leading, spacing: 0) {
            if installed, let status {
                DashboardGroup("Tailscale → Clash Verge provider") {
                    DetailGrid {
                        GridRow {
                            DetailLabel(text: "Status")
                            HStack(spacing: 4) {
                                Label(status.summary, systemImage: status.isDirect ? "checkmark.circle" : "xmark.octagon")
                                    .foregroundStyle(status.isDirect ? Color.primary : Color.orange)
                                if let checkedAt = status.checkedAt {
                                    Group {
                                        Text("·")
                                        Text(checkedAt, style: .relative)
                                        Text("ago")
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        PathRow(label: "Provider file", value: TailscaleVergeProvider.providerFileURL.path) {
                            Button("Open") { openInTextEdit(TailscaleVergeProvider.providerFileURL) }
                            Button("Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([TailscaleVergeProvider.providerFileURL])
                            }
                        }
                        PathRow(label: "Served at", value: TailscaleVergeProvider.providerURL.absoluteString) {
                            Button("Browser") { NSWorkspace.shared.open(TailscaleVergeProvider.providerURL) }
                            Button("JSON") { NSWorkspace.shared.open(TailscaleVergeProvider.statusURL) }
                        }
                        GridRow(alignment: .top) {
                            DetailLabel(text: "Clash Verge")
                            if let vergeURL = ClashVergeApp.url {
                                HStack(spacing: 8) {
                                    Text("Installed")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Open") { ClashVergeApp.open(vergeURL) }
                                        .controlSize(.small)
                                }
                            } else {
                                Text(ClashVergeApp.missingNote)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    GroupCaption("The provider file is never imported: your profile's tailscale-live provider fetches it every 3 seconds.")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reload() {
        installed = TailscaleVergeProvider.isInstalled()
        guard installed else { status = nil; return }
        let text = try? String(contentsOf: TailscaleVergeProvider.stateFileURL, encoding: .utf8)
        status = TailscaleVergeStatus.evaluate(stateText: text, now: Date())
    }
}

/// The full Clash Verge profile the app maintains: the proxy is entered here and kept in the Keychain,
/// and the app writes ~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml (0600) for
/// you to import into Clash Verge as its one Local profile. Nothing here writes into Clash Verge.
private struct ClashVergeProfileSection: View {
    @State private var name = ""
    @State private var type: ClashProxySettings.ProxyType = .socks5
    @State private var server = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var fileExists = false
    @State private var loaded = false

    var body: some View {
        DashboardGroup("Clash Verge profile") {
            DetailGrid {
                GridRow {
                    DetailLabel(text: "Name")
                    HStack(spacing: 8) {
                        TextField("e.g. MP-SG", text: $name)
                        Text("Type").foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                        Picker("Type", selection: $type) {
                            ForEach(ClashProxySettings.ProxyType.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                GridRow {
                    DetailLabel(text: "Server")
                    HStack(spacing: 8) {
                        TextField("IP address or host name", text: $server)
                        Text("Port").foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                        TextField("1080", text: $port).frame(width: 110)
                    }
                }
                GridRow {
                    DetailLabel(text: "Username")
                    HStack(spacing: 8) {
                        TextField("optional", text: $username)
                        Text("Password").foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                        SecureField("optional", text: $password).frame(width: 110)
                    }
                }
                GridRow {
                    DetailLabel(text: "")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button("Save Profile") { save() }
                            Button("Remove", role: .destructive) { remove() }
                                .disabled(!fileExists && name.isEmpty && server.isEmpty)
                        }
                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(messageIsError ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if fileExists {
                    PathRow(label: "Profile file", value: (ClashVergeProfile.fileURL.path as NSString).abbreviatingWithTildeInPath) {
                        Button("Open") { openInTextEdit(ClashVergeProfile.fileURL) }
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([ClashVergeProfile.fileURL]) }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            GroupCaption("The proxy is kept in the Keychain; the profile file is readable only by you.")
        }
        .task { load() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let settings = loadClashProxySettings() {
            name = settings.name
            type = settings.type
            server = settings.server
            port = String(settings.port)
            username = settings.username
            password = settings.password
        }
        refreshFileState()
    }

    private func refreshFileState() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: ClashVergeProfile.fileURL.path)
        fileExists = attributes != nil
        if message == nil, let modified = attributes?[.modificationDate] as? Date {
            show("Written \(modified.formatted(date: .abbreviated, time: .shortened)) · import it in Clash Verge", error: false)
        }
    }

    private func save() {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            show(ClashProxySettings.ValidationError.invalidPort.localizedDescription, error: true)
            return
        }
        let entered = ClashProxySettings(name: name, type: type, server: server, port: portNumber,
                                         username: username, password: password)
        do {
            let settings = try entered.validated()
            try SecureTokenStore.save(ClashVergeProfile.encode(settings), account: ClashVergeProfile.keychainAccount)
            let outcome = try maintainClashVergeProfile(settings)
            name = settings.name
            server = settings.server
            show(outcome == .written
                 ? "Written \(Date().formatted(date: .omitted, time: .shortened)) · import it in Clash Verge"
                 : "Already up to date", error: false)
        } catch {
            RuntimeLog.shared.error("clash_profile_write_failed", fields: ["error": error.localizedDescription])
            show(error.localizedDescription, error: true)
        }
        refreshFileState()
    }

    /// Deletes the saved proxy and the generated file (the profile Clash Verge imported is its own copy).
    private func remove() {
        do {
            try SecureTokenStore.delete(account: ClashVergeProfile.keychainAccount)
            if FileManager.default.fileExists(atPath: ClashVergeProfile.fileURL.path) {
                try FileManager.default.removeItem(at: ClashVergeProfile.fileURL)
            }
            name = ""
            server = ""
            port = ""
            username = ""
            password = ""
            type = .socks5
            show("Removed · Clash Verge keeps its own imported copy", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
        refreshFileState()
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

/// Clash Verge Rev, if installed. The app only launches it and never writes into it.
private enum ClashVergeApp {
    static let missingNote = "Clash Verge Rev isn't installed: nothing uses this provider until you install it and import the profile."

    static var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.clash-verge-rev.clash-verge-rev")
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// How to apply the app's profile in Clash Verge Rev, with the labels Clash Verge itself uses. The
/// provider file is never imported: the profile's proxy-providers entry fetches it.
private struct ClashVergeApplySteps: View {
    var body: some View {
        DashboardGroup("Apply in Clash Verge") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
                step(1, "Save Profile (left) writes the profile file.")
                step(2, "Clash Verge → Profiles → New. In Create Profile, set Type to Local, Choose File → clash-verge-profile.yaml, then Save.")
                step(3, "Right-click the new profile → Select. Clash Verge reloads once.")
                step(4, "Proxies → Proxy Provider → tailscale-live lists TS-NATIVE, and Status above reads Direct.")
            }
            HStack(alignment: .firstTextBaseline) {
                if let vergeURL = ClashVergeApp.url {
                    GroupCaption("Import again after changing the proxy. Tailscale reconnects need nothing.")
                    Spacer()
                    Button("Open Clash Verge") { ClashVergeApp.open(vergeURL) }
                        .controlSize(.small)
                } else {
                    GroupCaption("Install Clash Verge Rev first, then follow steps 2–4. Import again after changing the proxy.")
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        GridRow {
            Text("\(number)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @State private var ipinfoToken = ""
    @State private var tokenStatus: String?
    @State private var diagnostics = DiagnosticPreferences()
    @State private var selectedSimulation: PublicIPMonitor.DebugSimulationScenario = .transportFailure

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Display", selection: preferenceBinding(\.menuBarDisplayStyle)) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text("The default is the compact color flag. Use Country code if emoji flags are not rendered reliably. A yellow dot and highlight appear for 10 minutes after the country changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Change attention") {
                Toggle("Highlight country changes", isOn: preferenceBinding(\.highlightCountryChanges))
                Text("A changed country is confirmed with a different documented API before any highlight appears. Turn this off to suppress all future yellow menu-bar, widget, Control Center, and dashboard country-change highlights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                LaunchAtLoginControl()
            }

            Section("Refresh") {
                Picker("Frequency", selection: preferenceBinding(\.refreshInterval)) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                Text(MonitoringRules.summary(interval: monitor.preferences.refreshInterval) + " A continuing event storm is limited after 30 seconds; follow-up checks wait for the burst budget while new network changes remain prompt. Timer and app/screen/session activation checks skip results under 2 minutes old. Each provider has a 5-second minimum interval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("IP location service") {
                Picker("Provider", selection: preferenceBinding(\.provider)) {
                    ForEach(ProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                // The active provider follows rotation, so offer the token whenever IPinfo Lite is enabled.
                if preferences.provider == .ipinfoLite || preferences.providerPool.contains(.ipinfoLite) {
                    SecureField("IPinfo Lite token", text: $ipinfoToken)
                    HStack {
                        Button("Save token") { saveToken() }
                        Button("Remove token", role: .destructive) { removeToken() }
                        if let tokenStatus {
                            Text(tokenStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("The token is stored in the macOS Keychain, not in the app-group defaults or widget data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if preferences.provider == .ipapiCo {
                    Text("ipapi.co requires no token for basic personal use; its full response can include city, region, timezone, ASN, and organization.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if preferences.provider == .ipapiIs {
                    Text("ipapi.is uses HTTPS without a token and returns country, city, state, and network details. Its anonymous service is limited to 100 requests per day.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("IPWHOIS.io provides HTTPS country, city, ASN, organization, and timezone data with a documented daily limit. When it is the primary provider, ipapi.co confirms any country change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Successful refreshes advance to the next enabled provider. Each provider is held to 80% of its documented free daily limit (reset at midnight UTC); exhausted providers are skipped. Rate-limit, quota, and authentication errors pause the affected provider and never trigger hidden failover.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Rotation order")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(preferences.providerPool.enumerated()), id: \.offset) { index, provider in
                    HStack {
                        Text("\(index + 1). \(provider.displayName)")
                        Spacer()
                        Button { moveProvider(provider, offset: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button { moveProvider(provider, offset: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == preferences.providerPool.count - 1)
                        Button(role: .destructive) { disableProvider(provider) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(ProviderID.allCases.filter { !preferences.providerPool.contains($0) }) { provider in
                    Button("Add \(provider.displayName)") { enableProvider(provider) }
                        .buttonStyle(.borderless)
                }
            }

            Section("Provider health") {
                ForEach(preferences.providerPool) { provider in
                    let record = monitor.providerHealth[provider] ?? ProviderHealthRecord()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Test") {
                                Task { await monitor.testProvider(provider) }
                            }
                            // Without a token IPinfo Lite can only fail; rotation skips it until one is saved.
                            .disabled(provider == .ipinfoLite && monitor.isIPinfoMissingToken)
                        }
                        Text(providerHealthSummary(provider, record: record))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Diagnostics") {
                Button("Clear indicators") { monitor.clearIndicators() }
                    .disabled(monitor.indicators.errorMessage == nil && monitor.snapshot?.countryChange == nil)
                Text("Clearing an error removes its message but keeps location hidden until the next successful lookup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Runtime JSON logs are saved in ~/Library/Application Support/ExitIPMonitor/Logs. Set EXIT_IP_LOG_DIRECTORY to choose another folder during development.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Include full IP addresses in logs", isOn: Binding(
                    get: { diagnostics.includeFullIPAddresses },
                    set: { value in
                        diagnostics.includeFullIPAddresses = value
                        monitor.applyDiagnosticPreferences(diagnostics)
                    }
                ))
                Picker("Log retention", selection: Binding(
                    get: { diagnostics.retentionDays },
                    set: { value in
                        diagnostics.retentionDays = value
                        monitor.applyDiagnosticPreferences(diagnostics)
                    }
                )) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                Text("IP addresses are redacted by default. Retention is applied when the app starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

#if DEBUG
            Section("Developer simulations") {
                Picker("Scenario", selection: $selectedSimulation) {
                    ForEach(PublicIPMonitor.DebugSimulationScenario.allCases) { scenario in
                        Text(scenario.displayName).tag(scenario)
                    }
                }
                HStack {
                    Button("Run simulation") { monitor.runDebugSimulation(selectedSimulation) }
                    Button("Clear simulation") { monitor.clearDebugSimulation() }
                }
                if let message = monitor.simulationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("Simulations change only in-memory UI state.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#endif
        }
        .formStyle(.grouped)
        .padding()
        // Fills the window SettingsWindowController sizes (560 × 700); a scrolling Form has no
        // useful size of its own.
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .task {
            ipinfoToken = (try? SecureTokenStore.read(account: SecureTokenStore.ipinfoLiteAccount)) ?? ""
            diagnostics = monitor.diagnosticPreferences
        }
    }

    /// Always the monitor's live preferences. Rotation changes the active provider after every lookup and
    /// the popover can turn highlights off, so a copy held by this retained window would go stale and
    /// write old values back (reverting rotation and spending a `provider_changed` lookup).
    private var preferences: MonitoringPreferences { monitor.preferences }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<MonitoringPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { monitor.preferences[keyPath: keyPath] },
            set: { value in
                var updated = monitor.preferences
                updated[keyPath: keyPath] = value
                monitor.apply(updated)
            }
        )
    }

    private func enableProvider(_ provider: ProviderID) {
        var updated = monitor.preferences
        guard !updated.providerPool.contains(provider) else { return }
        updated.providerPool.append(provider)
        monitor.apply(updated)
    }

    private func disableProvider(_ provider: ProviderID) {
        var updated = monitor.preferences
        guard updated.providerPool.count > 1 else { return }
        updated.providerPool.removeAll { $0 == provider }
        if updated.provider == provider {
            updated.provider = updated.providerPool[0]
        }
        monitor.apply(updated)
    }

    private func moveProvider(_ provider: ProviderID, offset: Int) {
        var updated = monitor.preferences
        guard let index = updated.providerPool.firstIndex(of: provider) else { return }
        let destination = index + offset
        guard updated.providerPool.indices.contains(destination) else { return }
        updated.providerPool.swapAt(index, destination)
        monitor.apply(updated)
    }

    private func saveToken() {
        do {
            try SecureTokenStore.save(ipinfoToken.trimmingCharacters(in: .whitespacesAndNewlines), account: SecureTokenStore.ipinfoLiteAccount)
            tokenStatus = "Saved in Keychain"
            monitor.ipinfoTokenSaved()
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    private func removeToken() {
        do {
            try SecureTokenStore.delete(account: SecureTokenStore.ipinfoLiteAccount)
            ipinfoToken = ""
            tokenStatus = "Removed from Keychain; IPinfo Lite is skipped until a token is saved"
            monitor.ipinfoTokenRemoved()
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    private func providerHealthSummary(_ provider: ProviderID, record: ProviderHealthRecord) -> String {
        let budget = LookupBudget.dailyBudget(for: provider).map { "\(monitor.lookupBudget.callsToday(for: provider))/\($0) daily calls" } ?? "No published daily cap"
        let attempt = record.lastAttempt?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        let success = record.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        let failure = record.lastError.map { "last error \($0)" } ?? "no recent error"
        if provider == .ipinfoLite, monitor.isIPinfoMissingToken {
            return "Skipped: no token saved · Last success: \(success)"
        }
        return "Last attempt: \(attempt) · Last success: \(success) · \(budget) · \(failure)"
    }
}
