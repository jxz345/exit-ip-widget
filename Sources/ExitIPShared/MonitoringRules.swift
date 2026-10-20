import Foundation

/// The one description of when the app checks the exit IP. The dashboard, Settings, and the menu-bar
/// popover all show this text, so they always agree with `PublicIPMonitor`'s triggers.
public enum MonitoringRules {
    public static func summary(interval: RefreshInterval) -> String {
        "Checks \(interval.cadence), and right after a network, route, proxy, DNS, VPN/TUN, wake, or app-activation change."
    }
}

extension RefreshInterval {
    /// The interval as it reads inside a sentence ("every 15 minutes"), without "(recommended)".
    public var cadence: String {
        switch self {
        case .fiveMinutes: "every 5 minutes"
        case .fifteenMinutes: "every 15 minutes"
        case .thirtyMinutes: "every 30 minutes"
        case .sixtyMinutes: "every hour"
        }
    }
}

/// SF Symbols shared by the app, the widget, and the Control Center control.
public enum ExitIPIndicatorSymbol {
    /// A failed exit-IP lookup (the location is hidden): a stop sign in place of the country flag.
    public static let lookupError = "xmark.octagon.fill"
    /// A verified exit IP outside the allowlist (app only): the same stop sign in red, beside the flag
    /// in the menu bar and alone in the Dock icon. The location stays visible.
    public static let outsideAllowlist = "xmark.octagon.fill"
    /// A confirmed country change (Control Center only; elsewhere the yellow highlight shows it).
    public static let countryChanged = "exclamationmark.triangle.fill"
}
