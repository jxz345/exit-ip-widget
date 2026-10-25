import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarCountryLabel: View {
    let snapshot: ExitIPSnapshot?
    let displayStyle: MenuBarDisplayStyle
    let refreshInterval: RefreshInterval
    let indicators: MonitorIndicatorState
    /// The verified exit IP is outside the allowlist (warn-only).
    let outsideAllowlist: Bool
    let date: Date

    /// A red stop sign beside the location. After a failed lookup the error stop sign replaces the
    /// flag instead, so this one is not added.
    var showsAllowlistStop: Bool { outsideAllowlist && !indicators.suppressLocation }

    /// The red stop sign shown while the exit IP is outside the allowlist; the Dock icon shows it alone.
    static var allowlistStop: some View {
        Image(systemName: ExitIPIndicatorSymbol.outsideAllowlist)
            .foregroundStyle(.red)
            .accessibilityLabel("Not on the allowlist")
    }

    var body: some View {
        let isChanged = !indicators.suppressLocation && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        HStack(spacing: 3) {
            if indicators.suppressLocation {
                // A stop sign in place of the flag; text styles also say so in words.
                Image(systemName: ExitIPIndicatorSymbol.lookupError)
                    .foregroundStyle(.red)
                if displayStyle != .flag {
                    Text("Exit IP error")
                        .lineLimit(1)
                }
            } else {
                Text(statusLabel(at: date))
                    .lineLimit(1)
                    .fontWeight(isChanged ? .bold : .regular)
            }
            if showsAllowlistStop {
                Self.allowlistStop
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

    /// Everything that changes what this label draws, so the Dock copy re-renders only when the
    /// menu bar's appearance of it changes.
    var visualKey: String {
        let isChanged = !indicators.suppressLocation && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        return [displayStyle.rawValue, indicators.suppressLocation ? "error" : statusLabel(at: date),
                isChanged ? "changed" : "-", showsAllowlistStop ? "outside" : "-"].joined(separator: "|")
    }

    func accessibilityText(at date: Date) -> String {
        if indicators.suppressLocation { return "Exit IP error" }
        let allowlist = showsAllowlistStop ? ", not on the allowlist" : ""
        guard let snapshot else { return "Exit IP location unavailable" + allowlist }
        let stale = snapshot.isStale(at: date, threshold: Double(refreshInterval.rawValue * 2))
        if snapshot.isCountryChangeHighlighted(at: date) {
            return "Exit IP country changed from \(snapshot.countryChange?.previousName ?? "previous location") to \(snapshot.countryName)" + allowlist + (stale ? ", data is stale" : "")
        }
        return "Exit IP country: \(snapshot.countryName)" + allowlist + (stale ? ", data is stale" : "")
    }

    private func statusLabel(at date: Date) -> String {
        guard !indicators.suppressLocation else { return "Exit IP error" }
        guard let snapshot else { return "Locating" }
        let label = snapshot.menuBarLabel(style: displayStyle)
        return snapshot.isStale(at: date, threshold: Double(refreshInterval.rawValue * 2)) ? "Stale · \(label)" : label
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @StateObject private var daemon = DaemonInstallationModel()
    @State private var allowedIPInput = ""
    @State private var allowedIPStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    content(twoColumns: geometry.size.width >= 960)
                        .padding(20)
                }
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .controlSize(.regular)
        .buttonStyle(DashboardButtonStyle())
    }

    private func content(twoColumns: Bool) -> some View {
        // AnyLayout preserves the form's identity and unsaved edits when the window is resized.
        let columns = twoColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return VStack(alignment: .leading, spacing: 16) {
            notices
            header
            columns {
                leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: 8) {
                Label("Country changed from \(change.previousName) to \(snapshot.countryName)", systemImage: "mappin.and.ellipse")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Dismiss") { monitor.dismissCountryChangeHighlight() }
                    Button("Turn Off Highlights") { monitor.setCountryChangeHighlightsEnabled(false) }
                }
                .buttonStyle(DashboardButtonStyle(minimumWidth: 140))
            }
            .padding(10)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                headerSummary
                Spacer(minLength: 16)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 12) {
                headerSummary
                refreshButton
            }
        }
    }

    private var headerSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            SnapshotHeader(snapshot: monitor.snapshot, indicators: monitor.indicators)
            StaleDataNotice(
                snapshot: monitor.indicators.suppressLocation ? nil : monitor.snapshot,
                refreshInterval: monitor.preferences.refreshInterval,
                date: monitor.displayDate
            )
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await monitor.refresh(force: true) }
        } label: {
            Label("Refresh now", systemImage: "arrow.clockwise")
        }
        .disabled(monitor.status == .refreshing)
    }

    /// The exit IP, allowlist, and saved profile remain available during daemon setup.
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
                            Text("\(lastUpdatedText(snapshot.checkedAt)) · \(snapshot.checkedAt, style: .relative) ago")
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
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
                        Text(address).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) { monitor.removeAllowedIP(address) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .help("Remove allowed IP")
                        .accessibilityLabel("Remove allowed IP \(address)")
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

            ClashVergeProfileSection(providerInstalled: daemon.isInstalled)
        }
    }

    /// How the app is running: refresh setup, provider rotation, and the optional Tailscale daemon.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            DashboardGroup("Monitoring") {
                MonitoringSummary(monitor: monitor)
            }
            TailscaleVergeProviderSection(installer: daemon)
            ClashVergeApplySteps(providerInstalled: daemon.isInstalled)
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
        case .waitingForIPinfoToken: "Load or save your IPinfo token in Settings. The last verified result stays shown."
        case .failed(let message): message
        }
    }
}

/// Shown in the dashboard while the verified exit IP is outside the allowlist. Warn-only.
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Clear error", action: clear)
        }
        .font(.footnote)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// Native macOS controls with one size and minimum label width across the dashboard.
private struct DashboardButtonStyle: PrimitiveButtonStyle {
    var minimumWidth: CGFloat = 120
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.body)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minimumWidth, minHeight: 18)
        }
        Group {
            if prominent { button.buttonStyle(.borderedProminent) }
            else { button.buttonStyle(.bordered) }
        }
        .controlSize(.regular)
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
        GridRow(alignment: .top) {
            DetailLabel(text: label)
            VStack(alignment: .leading, spacing: 8) {
                Text(value)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) { actions }
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
        // Remembered, so the next launch restores a registration macOS dropped.
        LoginItemSync.store(enabled)
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
        .buttonStyle(DashboardButtonStyle(minimumWidth: 120))
    }

    private func providerState(_ provider: ProviderID) -> String {
        var notes: [String] = []
        if provider == monitor.preferences.provider { notes.append("next") }
        if provider == .ipinfoLite, monitor.isIPinfoTokenUnavailable {
            notes.append("skipped: \(monitor.ipinfoCredentialStatus.lowercased())")
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

/// Always visible: offers installation when missing and repair after incomplete setup.
/// Reads the provider state every two seconds; the app never sends proxy data to the daemon.
private struct TailscaleVergeProviderSection: View {
    @ObservedObject var installer: DaemonInstallationModel

    var body: some View {
        DashboardGroup("Tailscale → Clash Verge provider") {
            if installer.isInstalled, let status = installer.status {
                DetailGrid {
                    GridRow {
                        DetailLabel(text: "Status")
                        VStack(alignment: .leading, spacing: 4) {
                            Label(status.summary, systemImage: status.isDirect ? "checkmark.circle" : "xmark.octagon")
                                .foregroundStyle(status.isDirect ? Color.primary : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let checkedAt = status.checkedAt {
                                Text("Checked \(checkedAt.formatted(.relative(presentation: .named)))")
                                    .font(.footnote)
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
                        // Status only; Apply in Clash Verge has the one Open Clash Verge button.
                        if ClashVergeApp.url != nil {
                            Text("Installed")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(ClashVergeApp.missingNote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                GroupCaption("The provider file is never imported: your profile's tailscale-live provider fetches it every 3 seconds.")
            } else {
                if installer.monitorInstalled || installer.responderInstalled {
                    Label("Background provider setup is incomplete", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Optional background provider is not installed", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                GroupCaption("Exit IP monitoring works without this provider. Install it only to enable Tailscale routing in Clash Verge. Installation requires administrator authentication; your proxy info stays available.")
            }

            if installer.isInstalling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Installing provider…")
                }
            } else if !installer.isInstalled || installer.hasError {
                Button(installer.hasError ? "Retry Installation" : "Install Provider") {
                    installer.install()
                }
                .buttonStyle(DashboardButtonStyle(prominent: true))
                .help("macOS will ask for administrator authentication to install the background services.")
            }
            if let message = installer.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(installer.hasError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                installer.reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// The full Clash Verge profile the app maintains: the proxy is entered here and kept in the Keychain,
/// and the app writes ~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml (0600) for
/// you to import into Clash Verge as its one Local profile. Nothing here writes into Clash Verge.
struct ClashVergeProfileSection: View {
    let providerInstalled: Bool
    let credentials: CredentialSession
    @State private var name = ""
    @State private var type: ClashProxySettings.ProxyType = .socks5
    @State private var server = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var fileExists = false
    @State private var restoredSession = false

    init(providerInstalled: Bool, credentials: CredentialSession = AppCredentials.proxy) {
        self.providerInstalled = providerInstalled
        self.credentials = credentials
    }

    var body: some View {
        DashboardGroup("Clash Verge profile") {
            if !providerInstalled {
                GroupCaption("You can save your proxy info now. Install the background provider before using Tailscale routing.")
            }
            GroupCaption("Proxy info · stored in your Keychain")
            DetailGrid {
                GridRow {
                    DetailLabel(text: "Name")
                    TextField("e.g. MP-SG", text: $name).accessibilityLabel("Proxy name")
                }
                GridRow {
                    DetailLabel(text: "Type")
                    Picker("Proxy type", selection: $type) {
                        ForEach(ClashProxySettings.ProxyType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    DetailLabel(text: "Server")
                    TextField("IP address or host name", text: $server).accessibilityLabel("Proxy server")
                }
                GridRow {
                    DetailLabel(text: "Port")
                    TextField("1080", text: $port).accessibilityLabel("Proxy port")
                }
                GridRow {
                    DetailLabel(text: "Username")
                    TextField("optional", text: $username).accessibilityLabel("Proxy username")
                }
                GridRow {
                    DetailLabel(text: "Password")
                    SecureField("optional", text: $password).accessibilityLabel("Proxy password")
                }
                GridRow {
                    DetailLabel(text: "")
                    VStack(alignment: .leading, spacing: 4) {
                        ProxyInfoActionRow(load: { Task { await loadSavedProfile() } },
                                           save: { Task { await save() } },
                                           remove: { Task { await remove() } })
                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(messageIsError ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if fileExists {
                    PathRow(label: "Clash Verge profile file", value: (ClashVergeProfile.fileURL.path as NSString).abbreviatingWithTildeInPath) {
                        Button("Open") { openInTextEdit(ClashVergeProfile.fileURL) }
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([ClashVergeProfile.fileURL]) }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(credentials.isBusy)
            if credentials.isBusy {
                GroupCaption("Waiting for Keychain… Complete any macOS access prompt. Monitoring continues.")
            }
            GroupCaption("Save stores the proxy info in your Keychain and writes the Clash Verge profile file. Remove deletes the proxy info from your Keychain and the profile file generated from it; Clash Verge keeps the copy it imported.")
            GroupCaption("The dashboard reads the proxy info from your Keychain when it opens. The profile file is readable only by you.")
        }
        .task {
            // Restoring this session's memory and inspecting file metadata do not read Keychain.
            if !restoredSession, let text = credentials.value, let settings = ClashVergeProfile.decode(text) {
                apply(settings)
            }
            restoredSession = true
            refreshFileState()
            // One automatic Keychain read per app session, off the main thread (CredentialSession).
            if credentials.state == .notLoaded { await loadSavedProfile(automatic: true) }
        }
    }

    private func apply(_ settings: ClashProxySettings) {
        name = settings.name
        type = settings.type
        server = settings.server
        port = String(settings.port)
        username = settings.username
        password = settings.password
    }

    /// `automatic` is the dashboard's first read; it never repeats or retries within a session.
    private func loadSavedProfile(automatic: Bool = false) async {
        let loaded = automatic ? await credentials.loadIfNotLoaded() : await credentials.load()
        guard loaded else {
            if let error = credentials.errorMessage { show(error, error: true) }
            return
        }
        guard let text = credentials.value else {
            show("No proxy info in your Keychain yet: enter your proxy, then Save.", error: false)
            return
        }
        guard let settings = ClashVergeProfile.decode(text) else {
            show("The proxy info in your Keychain couldn't be read; the profile file is unchanged.", error: true)
            return
        }
        do {
            let settings = try settings.validated()
            try maintainClashVergeProfile(settings)
            apply(settings)
            show("Proxy info loaded · profile file up to date", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
        refreshFileState()
    }

    private func refreshFileState() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: ClashVergeProfile.fileURL.path)
        fileExists = attributes != nil
        if message == nil, let modified = attributes?[.modificationDate] as? Date {
            show("Profile file written \(modified.formatted(date: .abbreviated, time: .shortened)) · import it in Clash Verge", error: false)
        }
    }

    private func save() async {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            show(ClashProxySettings.ValidationError.invalidPort.localizedDescription, error: true)
            return
        }
        let entered = ClashProxySettings(name: name, type: type, server: server, port: portNumber,
                                         username: username, password: password)
        do {
            let settings = try entered.validated()
            let encoded = try ClashVergeProfile.encode(settings)
            guard await credentials.save(encoded) else {
                if let error = credentials.errorMessage { show(error, error: true) }
                return
            }
            let outcome = try maintainClashVergeProfile(settings)
            name = settings.name
            server = settings.server
            show(outcome == .written
                 ? "Proxy info saved · profile file written \(Date().formatted(date: .omitted, time: .shortened)); import it in Clash Verge"
                 : "Proxy info saved · profile file already up to date", error: false)
        } catch {
            RuntimeLog.shared.error("clash_profile_write_failed", fields: ["error": error.localizedDescription])
            show(error.localizedDescription, error: true)
        }
        refreshFileState()
    }

    /// Deletes the saved proxy and the generated file (the profile Clash Verge imported is its own copy).
    private func remove() async {
        guard await credentials.remove() else {
            if let error = credentials.errorMessage { show(error, error: true) }
            return
        }
        do {
            if FileManager.default.fileExists(atPath: ClashVergeProfile.fileURL.path) {
                try FileManager.default.removeItem(at: ClashVergeProfile.fileURL)
            }
            name = ""
            server = ""
            port = ""
            username = ""
            password = ""
            type = .socks5
            show("Proxy info removed · profile file deleted; Clash Verge keeps its imported copy", error: false)
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

/// Load proxy info, Save and Remove, always in one row (measured by the app test). The profile form's
/// value column is at least ~326 pt, both in the default two-column window and at the 520 pt minimum.
struct ProxyInfoActionRow: View {
    let load: () -> Void
    let save: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Load proxy info", action: load)
            Button("Save", action: save)
            Button("Remove", role: .destructive, action: remove)
        }
        // A 56 pt label minimum keeps Save and Remove alike (~80 pt buttons) and the row ≤ 320 pt.
        .buttonStyle(DashboardButtonStyle(minimumWidth: 56))
        .fixedSize()
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
    let providerInstalled: Bool
    var body: some View {
        DashboardGroup("Apply in Clash Verge") {
            if !providerInstalled {
                Label("Install the background provider before applying the profile.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
                step(1, "Save writes the profile file.")
                step(2, "Clash Verge → Profiles → New. In Create Profile, set Type to Local, Choose File → clash-verge-profile.yaml, then Save.")
                step(3, "Right-click the new profile → Select. Clash Verge reloads once.")
                step(4, "Proxies → Proxy Provider → tailscale-live lists TS-NATIVE, and Status above reads Direct.")
            }
            if let vergeURL = ClashVergeApp.url {
                Button("Open Clash Verge") { ClashVergeApp.open(vergeURL) }
                GroupCaption("Import again after changing the proxy. Tailscale reconnects need nothing.")
            } else {
                GroupCaption("Install Clash Verge Rev first, then follow steps 2–4. Import again after changing the proxy.")
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
                        .disabled(monitor.ipinfoCredentials.isBusy)
                    HStack {
                        Button("Load saved token") { Task { await loadToken() } }
                        Button("Save token") { Task { await saveToken() } }
                            .disabled(ipinfoToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove token", role: .destructive) { Task { await removeToken() } }
                    }
                    .disabled(monitor.ipinfoCredentials.isBusy)
                    Text(monitor.ipinfoCredentials.isBusy ? "Waiting for Keychain… Complete any macOS access prompt." : (tokenStatus ?? monitor.ipinfoCredentialStatus))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Load once per app session to enable automatic IPinfo monitoring. Keychain is accessed only when you load, save, or remove; the token is never stored in widget data.")
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
                            .disabled(provider == .ipinfoLite && monitor.isIPinfoTokenUnavailable)
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
            if ipinfoToken.isEmpty { ipinfoToken = monitor.ipinfoToken ?? "" }
            diagnostics = monitor.diagnosticPreferences
        }
    }

    /// Always the monitor's live preferences. Rotation changes the active provider after every lookup and
    /// the dashboard can turn highlights off, so a copy held by this retained window would go stale and
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

    private func loadToken() async {
        if await monitor.loadIPinfoToken() {
            ipinfoToken = monitor.ipinfoToken ?? ""
            tokenStatus = monitor.ipinfoCredentialStatus
        } else if let error = monitor.ipinfoCredentials.errorMessage { tokenStatus = error }
    }

    private func saveToken() async {
        if await monitor.saveIPinfoToken(ipinfoToken) {
            tokenStatus = "Saved in Keychain · available for this session"
        } else if let error = monitor.ipinfoCredentials.errorMessage { tokenStatus = error }
    }

    private func removeToken() async {
        if await monitor.removeIPinfoToken() {
            ipinfoToken = ""
            tokenStatus = "Removed from Keychain; IPinfo Lite is skipped until a token is loaded or saved"
        } else if let error = monitor.ipinfoCredentials.errorMessage { tokenStatus = error }
    }

    private func providerHealthSummary(_ provider: ProviderID, record: ProviderHealthRecord) -> String {
        let budget = LookupBudget.dailyBudget(for: provider).map { "\(monitor.lookupBudget.callsToday(for: provider))/\($0) daily calls" } ?? "No published daily cap"
        let attempt = record.lastAttempt?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        let success = record.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        let failure = record.lastError.map { "last error \($0)" } ?? "no recent error"
        if provider == .ipinfoLite, monitor.isIPinfoTokenUnavailable {
            return "Skipped: \(monitor.ipinfoCredentialStatus) · Last success: \(success)"
        }
        return "Last attempt: \(attempt) · Last success: \(success) · \(budget) · \(failure)"
    }
}
