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
            Text(statusLabel(at: date))
                .lineLimit(1)
                .fontWeight(isChanged ? .bold : .regular)
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
        guard !indicators.suppressLocation, let snapshot else { return "Exit IP location unavailable" }
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
        VStack(alignment: .leading, spacing: 12) {
            // Scrolls so the footer (Settings, status) stays visible however much content is shown.
            ScrollView {
                content
                    .padding(24)
            }
            Divider()
            footer
                .padding([.horizontal, .bottom], 24)
                .padding(.top, 4)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if case .notAllowed(let address) = monitor.authorizationState {
                AllowlistNotice(address: address)
            }
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

            GroupBox("Allowed exit IPs") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You'll be warned when a verified exit IP is not in this list. Leave the list empty to turn warnings off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                }
                .padding(.top, 4)
            }

            if let errorMessage = monitor.indicators.errorMessage {
                IndicatorErrorView(message: errorMessage, clear: monitor.clearError)
            }

            if let snapshot = monitor.snapshot {
                if !monitor.indicators.suppressLocation,
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

                GroupBox("Current exit IP") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        DetailRow(label: "Public exit IP", value: snapshot.ipAddress)
                        if !monitor.indicators.suppressLocation {
                            DetailRow(label: "Country", value: "\(snapshot.countryFlag) \(snapshot.countryName) (\(snapshot.countryCode))")
                        }
                        if !monitor.indicators.suppressLocation {
                            DetailRow(label: "Location", value: snapshot.locationSummary.isEmpty ? "Not supplied by \(snapshot.provider.displayName)" : snapshot.locationSummary)
                        }
                        DetailRow(label: "Network", value: [snapshot.autonomousSystem, snapshot.organization].compactMap { $0 }.joined(separator: " · "))
                        DetailRow(label: "Timezone", value: snapshot.timezone ?? "Not supplied")
                        DetailRow(label: "Last updated", value: snapshot.checkedAt.formatted(date: .abbreviated, time: .standard))
                        GridRow {
                            Text("Age")
                                .foregroundStyle(.secondary)
                            Text(snapshot.checkedAt, style: .relative)
                        }
                        DetailRow(label: "Source", value: snapshot.provider.displayName)
                    }
                    .padding(.top, 4)
                }
            } else {
                ContentUnavailableView(
                    "No public IP result yet",
                    systemImage: "network",
                    description: Text("The app will check when it can reach the selected service.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }

            GroupBox("Monitoring") {
                MonitoringSummary(monitor: monitor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .ready: "Updates run on the selected schedule and after network, proxy, VPN, wake, and app-activation events."
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
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

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "Not supplied" : value)
                .textSelection(.enabled)
        }
    }
}

/// Launch-at-login toggle shared by the dashboard and Settings. State is always read back from
/// `SMAppService`, so both windows (and changes made in System Settings) stay in agreement.
private struct LaunchAtLoginControl: View {
    @State private var serviceStatus = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { serviceStatus == .enabled },
                set: { setEnabled($0) }
            ))
            Text("When enabled, the menu-bar app starts at user login and checks immediately. Later event and manual checks use the 5-second minimum interval.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Open Login Items Settings") {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        .onAppear { serviceStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            serviceStatus = SMAppService.mainApp.status
        }
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
        VStack(alignment: .leading, spacing: 12) {
            LaunchAtLoginControl()
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                DetailRow(label: "Refresh frequency", value: monitor.preferences.refreshInterval.displayName)
                DetailRow(label: "Change highlights", value: monitor.preferences.highlightCountryChanges ? "On" : "Off")
                GridRow(alignment: .top) {
                    Text("Provider rotation")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(monitor.preferences.providerPool.enumerated()), id: \.offset) { index, provider in
                            Text("\(index + 1). \(provider.displayName)\(providerState(provider))")
                                .fontWeight(provider == monitor.preferences.provider ? .semibold : .regular)
                        }
                    }
                }
            }
            Button("Edit in Settings…") { ExitIPAppDelegate.showSettings() }
        }
        .padding(.top, 4)
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
        return notes.isEmpty ? "" : " — " + notes.joined(separator: " · ")
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
                Text("Network, route, proxy, VPN/TUN changes and wake are checked promptly. A continuing event storm is limited after 30 seconds; follow-up checks wait for the burst budget while new network changes remain prompt. Timer and app/screen/session activation checks skip results under 2 minutes old. Each provider has a 5-second minimum interval.")
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
        .frame(width: 520)
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
