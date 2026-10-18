import Foundation

/// Fixed locations of the optional Tailscale → Clash Verge provider (`Sources/ExitIPDaemon`). Its root
/// monitor writes `provider.yaml` (the exact bytes Clash/Mihomo receives) and `state`; a launchd-held
/// socket serves them on `127.0.0.1:18766`. The app only reads these files; it never queries the daemon.
public enum TailscaleVergeProvider {
    public static let monitorLabel = "com.example.exitipmonitor.tailscale-verge"
    public static let responderLabel = monitorLabel + "-http"
    public static let monitorPlistPath = "/Library/LaunchDaemons/\(monitorLabel).plist"
    public static let responderPlistPath = "/Library/LaunchDaemons/\(responderLabel).plist"
    public static let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/ExitIPMonitor/TailscaleVerge", isDirectory: true)
    public static let providerFileURL = stateDirectory.appendingPathComponent("provider.yaml")
    public static let stateFileURL = stateDirectory.appendingPathComponent("state")
    public static let host = "127.0.0.1"
    public static let port = 18766
    public static let endpoint = "\(host):\(port)"
    public static let providerURL = URL(string: "http://\(endpoint)/provider.yaml")!
    public static let statusURL = URL(string: "http://\(endpoint)/status.json")!
    /// The responder serves Reject once the last check is older than this (the monitor checks every 2 s).
    public static let staleAfterSeconds = 12
    /// A `checked` time up to this far ahead of the clock counts as now; further ahead counts as stale.
    public static let futureToleranceSeconds = 2

    /// Installed means the monitor's LaunchDaemon plist exists.
    public static func isInstalled(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        fileExists(monitorPlistPath)
    }
}

/// Decides when a change in what Clash is served is worth a log record. The daemon rewrites its state
/// every 2 seconds and Clash fetches every 3, so only a different served value counts: Direct↔Reject,
/// another utun, or another reason. The age and check time never do.
public enum TailscaleVergeChange {
    /// `current` when it differs from the last recorded value (the first reading always counts), else nil.
    public static func next(previous: TailscaleVergeStatus.Served?, current: TailscaleVergeStatus.Served) -> TailscaleVergeStatus.Served? {
        previous == current ? nil : current
    }

    /// The runtime-log fields of a `tailscale_provider_changed` record.
    public static func logFields(_ served: TailscaleVergeStatus.Served) -> [String: String] {
        switch served {
        case .direct(let interface): ["served": "direct", "interface": interface, "reason": "verified"]
        case .reject(let reason): ["served": "reject", "interface": "", "reason": reason]
        }
    }
}

/// What the responder serves right now, derived from the monitor's `state` file with the responder's
/// rules (tailscale-verge.sh `load_state`): any missing, malformed, or stale state means Reject.
public struct TailscaleVergeStatus: Equatable, Sendable {
    public enum Served: Equatable, Sendable {
        case direct(interface: String)
        case reject(reason: String)
    }

    public let served: Served
    /// When the monitor last finished a check, if the state file says so.
    public let checkedAt: Date?

    public init(served: Served, checkedAt: Date?) {
        self.served = served
        self.checkedAt = checkedAt
    }

    /// `stateText` is the content of the `state` file, or nil when it is missing or unreadable.
    public static func evaluate(stateText: String?, now: Date) -> TailscaleVergeStatus {
        guard let stateText else { return TailscaleVergeStatus(served: .reject(reason: "starting"), checkedAt: nil) }
        var fields: [String: String] = [:]
        for line in stateText.prefix(512).split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let checkedText = fields["checked"], (1...12).contains(checkedText.count), checkedText.first != "0",
              checkedText.allSatisfy(\.isASCIIDigit), let checked = Int(checkedText),
              let reason = fields["reason"], isValidReason(reason),
              let state = fields["state"], state == "direct" || state == "reject" else {
            return TailscaleVergeStatus(served: .reject(reason: "monitor-error"), checkedAt: nil)
        }
        let checkedAt = Date(timeIntervalSince1970: TimeInterval(checked))
        let nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        if checked > nowSeconds + TailscaleVergeProvider.futureToleranceSeconds {
            return TailscaleVergeStatus(served: .reject(reason: "monitor-stale"), checkedAt: checkedAt)
        }
        let age = max(0, nowSeconds - checked)
        if age > TailscaleVergeProvider.staleAfterSeconds {
            return TailscaleVergeStatus(served: .reject(reason: "monitor-stale"), checkedAt: checkedAt)
        }
        guard state == "direct" else { return TailscaleVergeStatus(served: .reject(reason: reason), checkedAt: checkedAt) }
        guard let interface = fields["interface"], isUtun(interface) else {
            return TailscaleVergeStatus(served: .reject(reason: "invalid-interface"), checkedAt: checkedAt)
        }
        return TailscaleVergeStatus(served: .direct(interface: interface), checkedAt: checkedAt)
    }

    /// "Direct on utun7", or "Reject · Tailscale isn't installed".
    public var summary: String {
        switch served {
        case .direct(let interface): "Direct on \(interface)"
        case .reject(let reason): "Reject · \(Self.reasonText(reason))"
        }
    }

    /// Plain words for a reason the monitor or responder reports (`status.json` keeps the code). A
    /// missing Tailscale is a reason like any other, never a failure.
    public static func reasonText(_ reason: String) -> String {
        switch reason {
        case "verified": return "Verified"
        case "tailscale-not-installed": return "Tailscale isn't installed"
        case "tailscale-cli-unavailable": return "Tailscale isn't running or is logged out"
        case "tailscale-cli-timeout": return "Tailscale didn't answer in time"
        case "no-tailscale-route": return "Tailscale isn't connected"
        case "no-tailscale-ip": return "Tailscale has no IPv4 address yet"
        case "no-console-user": return "Nobody is logged in"
        case "interface-not-owned-by-tailscale": return "That tunnel isn't Tailscale's"
        case "route-changed-during-check": return "The route changed during the check"
        case "monitor-stale": return "The monitor stopped updating"
        case "monitor-error": return "The monitor's state can't be read"
        case "invalid-interface": return "The reported tunnel is invalid"
        case "starting": return "Starting up"
        default:
            if reason.hasSuffix("-timeout") { return "A check timed out" }
            if reason.hasSuffix("-unavailable") { return "A check failed" }
            let words = reason.replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    public var isDirect: Bool {
        if case .direct = served { true } else { false }
    }

    static func isUtun(_ value: String) -> Bool {
        value.hasPrefix("utun") && value.count > 4 && value.dropFirst(4).allSatisfy(\.isASCIIDigit)
    }

    static func isValidReason(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0 == "-" || $0.isASCIIDigit || ("a"..."z").contains($0) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
