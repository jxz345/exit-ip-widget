import SwiftUI
import WidgetKit

struct ExitIPWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: ExitIPSnapshot?
    let indicators: MonitorIndicatorState
    var refreshInterval: RefreshInterval = .fifteenMinutes
}

struct ExitIPWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExitIPWidgetEntry {
        ExitIPWidgetEntry(
            date: .now,
            snapshot: ExitIPSnapshot(
                ipAddress: "203.0.113.8",
                countryCode: "US",
                countryName: "United States",
                city: "Seattle",
                region: "Washington",
                autonomousSystem: "AS64500",
                organization: "Example Network",
                provider: .ipapiCo
            ),
            indicators: MonitorIndicatorState()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ExitIPWidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let reply = WidgetReply(completion)
        Task { reply.finish(await WidgetServiceState.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExitIPWidgetEntry>) -> Void) {
        let reply = WidgetReply(completion)
        Task {
            let entry = await WidgetServiceState.entry()
            let refreshAt = entry.date.addingTimeInterval(RefreshPolicy.widgetTimelineRefresh)
            reply.finish(Timeline(entries: [entry], policy: .after(refreshAt)))
        }
    }
}

struct ExitIPStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ExitIPSurfaceID.widget, provider: ExitIPWidgetTimelineProvider()) { entry in
            ExitIPWidgetView(entry: entry)
        }
        .configurationDisplayName("Exit IP")
        .description("Shows the public exit IP and its current country.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ExitIPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExitIPWidgetEntry

    var body: some View {
        Group {
            if entry.indicators.suppressLocation {
                ContentUnavailableView(
                    "Exit IP unavailable",
                    systemImage: ExitIPIndicatorSymbol.lookupError,
                    description: Text(entry.indicators.errorMessage ?? "A successful lookup is required to show location.")
                )
            } else if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium:
                    medium(snapshot)
                default:
                    small(snapshot)
                }
            } else {
                ContentUnavailableView("No exit IP", systemImage: "network", description: Text("Open Exit IP to set up the background service."))
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func small(_ snapshot: ExitIPSnapshot) -> some View {
        let staleThreshold = Double(entry.refreshInterval.rawValue * 2)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.countryFlag)
                    .font(.title)
                Spacer()
                if snapshot.isCountryChangeHighlighted() {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            Text(snapshot.countryCode)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(snapshot.countryName)
                .font(.caption)
                .lineLimit(1)
            if snapshot.isStale(at: entry.date, threshold: staleThreshold) {
                Label("Stale", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(snapshot.checkedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func medium(_ snapshot: ExitIPSnapshot) -> some View {
        let staleThreshold = Double(entry.refreshInterval.rawValue * 2)
        return HStack(alignment: .top, spacing: 14) {
            Text(snapshot.countryFlag)
                .font(.system(size: 42))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(snapshot.countryName)
                        .font(.headline)
                    if snapshot.isCountryChangeHighlighted(), let change = snapshot.countryChange {
                        Text("Changed from \(change.previousCode)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.yellow.opacity(0.28), in: Capsule())
                    }
                    if snapshot.isStale(at: entry.date, threshold: staleThreshold) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                Text(snapshot.ipAddress)
                    .font(.system(.subheadline, design: .monospaced))
                if !snapshot.locationSummary.isEmpty {
                    Text(snapshot.locationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let organization = snapshot.organization {
                    Text(organization)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Updated \(snapshot.checkedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

/// Each extension fetches the machine state in its own user context. Its cache is only for outages.
enum WidgetServiceState {
    static func entry() async -> ExitIPWidgetEntry {
        do {
            guard let state = try await DaemonRPC.call(DaemonRequest(.state), timeout: 2).state else { throw DaemonFailure.unavailable }
            if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "daemon.widget-cache") }
            return ExitIPWidgetEntry(date: .now, snapshot: state.presentedSnapshot,
                                     indicators: state.initialized ? state.presentedIndicators : .init(errorMessage: "Set up shared monitoring in Exit IP", suppressLocation: true),
                                     refreshInterval: state.settings.refreshInterval)
        } catch {
            let cached = UserDefaults.standard.data(forKey: "daemon.widget-cache").flatMap { try? JSONDecoder().decode(DaemonState.self, from: $0) }
            return ExitIPWidgetEntry(date: .now, snapshot: cached?.presentedSnapshot,
                                     indicators: .init(errorMessage: "Background service unavailable; cached data is stale", suppressLocation: true),
                                     refreshInterval: cached?.settings.refreshInterval ?? .fifteenMinutes)
        }
    }
}

/// WidgetKit's legacy callbacks aren't annotated Sendable. Each immutable callback is transferred
/// once to the fetch task and invoked exactly once, never read concurrently by another task.
private struct WidgetReply<Value>: @unchecked Sendable {
    let finish: (Value) -> Void
    init(_ finish: @escaping (Value) -> Void) { self.finish = finish }
}
