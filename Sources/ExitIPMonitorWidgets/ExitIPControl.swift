import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct ExitIPControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        let snapshot = SnapshotStore().load()
        let indicators = IndicatorStore().load()
        let controlTitle = compactSummary(snapshot, indicators: indicators)
        let symbol = indicators.suppressLocation || snapshot?.isCountryChangeHighlighted() == true
            ? "exclamationmark.triangle.fill"
            : "network"

        return StaticControlConfiguration(kind: ExitIPSurfaceID.control) {
            ControlWidgetButton(action: OpenExitIPDashboardIntent(target: .dashboard)) {
                Label(controlTitle, systemImage: symbol)
            }
        }
        .displayName("Exit IP")
        .description("Shows country code, public exit IP, and last update time in a resized Control Center tile.")
    }

    private func compactSummary(_ snapshot: ExitIPSnapshot?, indicators: MonitorIndicatorState) -> String {
        guard !indicators.suppressLocation, let snapshot else { return "Exit IP unavailable" }
        let time = snapshot.checkedAt.formatted(date: .omitted, time: .shortened)
        let interval = MonitoringPreferences.load().refreshInterval
        let stale = snapshot.isStale(at: .now, threshold: Double(interval.rawValue * 2))
        return "\(snapshot.countryCode) · \(snapshot.ipAddress) · \(time)\(stale ? " · stale" : "")"
    }
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
