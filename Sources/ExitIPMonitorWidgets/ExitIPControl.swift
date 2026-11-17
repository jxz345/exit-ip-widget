import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct ExitIPControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ExitIPSurfaceID.control, provider: ExitIPControlValueProvider()) { entry in
            let symbol = entry.indicators.suppressLocation
                ? ExitIPIndicatorSymbol.lookupError
                : (entry.snapshot?.isCountryChangeHighlighted() == true ? ExitIPIndicatorSymbol.countryChanged : "network")
            ControlWidgetButton(action: OpenExitIPDashboardIntent(target: .dashboard)) {
                Label(compactSummary(entry.snapshot, indicators: entry.indicators, interval: entry.refreshInterval), systemImage: symbol)
            }
        }
        .displayName("Exit IP")
        .description("Shows country code, public exit IP, and last update time in a resized Control Center tile.")
    }

    private func compactSummary(_ snapshot: ExitIPSnapshot?, indicators: MonitorIndicatorState, interval: RefreshInterval) -> String {
        guard !indicators.suppressLocation, let snapshot else { return "Exit IP unavailable" }
        let time = snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
        let stale = snapshot.isStale(at: .now, threshold: Double(interval.rawValue * 2))
        return "\(snapshot.countryCode) · \(snapshot.ipAddress) · \(time)\(stale ? " · stale" : "")"
    }
}

@available(macOS 26.0, *)
private struct ExitIPControlValueProvider: ControlValueProvider {
    var previewValue: ExitIPWidgetEntry { ExitIPWidgetEntry(date: .now, snapshot: nil, indicators: .init()) }
    func currentValue() async throws -> ExitIPWidgetEntry { await WidgetServiceState.entry() }
}

@main
struct ExitIPMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExitIPStatusWidget()
        if #available(macOS 26.0, *) {
            ExitIPControl()
        }
    }
}
