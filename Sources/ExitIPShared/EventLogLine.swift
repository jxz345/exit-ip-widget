import Foundation

/// Turns runtime-log records into the Event Log window's lines: one concise line per important event,
/// in UTC ("2026-10-18 13:28:56Z  Lookup OK · IPWHOIS.io · SG"). Routine records (health bookkeeping,
/// unchanged network paths, widget reloads, ...) return nil and are not shown. A new trigger or event
/// that matters to people needs a case here.
public enum EventLogLine {
    public static let maximumMessageLength = 100

    public static func format(timestamp: String, event: String, fields: [String: String]) -> String? {
        guard let message = message(event: event, fields: fields) else { return nil }
        return "\(stamp(timestamp))  \(truncated(message))"
    }

    /// The text after the time stamp, or nil for routine records.
    public static func message(event: String, fields: [String: String]) -> String? {
        let provider = providerName(fields["provider"])
        switch event {
        case "monitor_started": return "App started"
        case "monitor_stopped": return "App quit"
        case "duplicate_launch_reopened": return "Existing app reopened · duplicate launch prevented"
        case "single_instance_lock_failed": return "App startup blocked · couldn't acquire the instance lock"
        case "refresh_requested":
            return "Check · \(trigger(fields["trigger"])) · \(provider)"
        case "refresh_skipped":
            return "Skipped · \(trigger(fields["trigger"])) · \(skipReason(fields["reason"]))"
        case "refresh_event_merged":
            return "Merged · \(trigger(fields["trigger"])) → follow-up at \(time(fields["trailingAt"]))"
        case "refresh_queued":
            return "Queued · \(queueReason(fields["reason"])) · at \(time(fields["notBefore"]))"
        case "refresh_queue_superseded":
            return "Queued check replaced · \(trigger(fields["trigger"]))"
        case "lookup_succeeded":
            return "Lookup OK · \(provider) · \(fields["country"] ?? "?")"
        case "lookup_failed":
            return "Lookup failed · \(provider)" + detail(fields["message"])
        case "lookup_cancelled":
            return "Lookup cancelled · \(provider)"
        case "lookup_rate_limited":
            return "Provider paused · \(provider) until \(time(fields["retryNotBefore"]))"
        case "lookup_all_providers_paused":
            return "All providers paused until \(time(fields["resumeAt"]))"
        case "lookup_daily_budget_exhausted":
            return "Daily budget used · \(provider) · resets \(time(fields["resetAt"]))"
        case "provider_rotated_after_failure":
            return "Next provider after failure · \(providerName(fields["from"])) → \(providerName(fields["to"]))"
        case "confirmation_deferred":
            return "Country change to confirm · \(fields["from"] ?? "?") → \(fields["to"] ?? "?") · asking \(provider)"
        case "confirmation_result":
            let agrees = fields["agrees"] == "true"
            return "\(agrees ? "Country confirmed" : "Country not confirmed") · \(provider) · \(fields["country"] ?? "?")"
        case "confirmation_failed":
            return "Confirmation failed · \(provider)"
        case "country_change_dismissed": return "Country-change notice dismissed"
        case "allowlist_warning_presented":
            return "Exit IP not on allowlist" + detail(fields["ip"])
        case "allowlist_warning_cleared": return "Allowlist warning cleared"
        case "indicator_error_set":
            return "Error shown" + detail(fields["message"])
        case "error_cleared": return "Error cleared"
        case "clash_profile_written": return "Clash Verge profile written"
        case "daemon_install_started": return "Provider installation started · awaiting macOS authentication"
        case "daemon_install_succeeded": return "Provider installed · both background services loaded"
        case "daemon_install_cancelled": return "Provider installation cancelled"
        case "daemon_install_failed": return "Provider installation failed · see dashboard installation details"
        case "clash_profile_write_failed":
            return "Clash Verge profile not written" + detail(fields["error"])
        case "tailscale_provider_changed":
            if fields["served"] == "direct" {
                return "Tailscale provider · Direct \(fields["interface"] ?? "")".trimmingCharacters(in: .whitespaces)
            }
            return "Tailscale provider · Reject (\(TailscaleVergeStatus.reasonText(fields["reason"] ?? "unknown")))"
        case "route_monitor_unavailable", "network_configuration_monitor_unavailable":
            return "Network change monitor unavailable"
        case "ipinfo_token_removed": return "IPinfo token removed"
        default: return nil
        }
    }

    // MARK: Pieces

    static func messageForBuffer(event: String, fields: [String: String]) -> String? {
        message(event: event, fields: fields).map(truncated)
    }

    static func trigger(_ raw: String?) -> String {
        switch raw {
        case "startup": "app start"
        case "manual": "Refresh now"
        case "periodic": "timer"
        case "network_path": "network path changed"
        case "network_configuration": "network settings changed"
        case "route_change": "route changed"
        case "system_wake": "Mac woke"
        case "screens_wake": "screen woke"
        case "session_active": "session active"
        case "app_active": "app activated"
        case "queued": "queued check"
        case "trailing": "follow-up after events"
        case "retry": "retry"
        case "recheck": "recheck"
        case "provider_changed": "provider changed"
        case "settings_changed": "settings changed"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func skipReason(_ raw: String?) -> String {
        switch raw {
        case "fresh": "result under 2 min old"
        case "event_window": "absorbed by the check just run"
        case "burst_budget": "burst budget empty"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func queueReason(_ raw: String?) -> String {
        switch raw {
        case "provider_gap": "provider gap"
        case "burst_budget": "burst budget"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func providerName(_ raw: String?) -> String {
        guard let raw else { return "?" }
        return ProviderID(rawValue: raw)?.displayName ?? raw
    }

    static func detail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return " · " + value.replacingOccurrences(of: "\n", with: " ")
    }

    static func truncated(_ message: String) -> String {
        message.count <= maximumMessageLength ? message : String(message.prefix(maximumMessageLength - 1)) + "…"
    }

    // MARK: Time (always UTC)

    private static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }

    private static func utc(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter
    }

    /// "2026-10-18 13:28:56Z" for a record's timestamp.
    static func stamp(_ iso: String) -> String {
        guard let date = parse(iso) else { return iso }
        return utc("yyyy-MM-dd HH:mm:ss'Z'").string(from: date)
    }

    /// "13:28:56Z" for a time inside a message.
    static func time(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "?" }
        return utc("HH:mm:ss'Z'").string(from: date)
    }
}

/// The Event Log window's lines, oldest first, at most `limit`. A Tailscale provider line identical to
/// the previous Tailscale line is dropped, so repeated readings (also across launches) never repeat.
public struct EventLogBuffer: Sendable {
    public let limit: Int
    public private(set) var lines: [String] = []
    private var lastTailscaleMessage: String?

    public init(limit: Int = 500) {
        self.limit = limit
    }

    /// Adds a runtime-log record; returns whether it produced a line.
    @discardableResult
    public mutating func append(timestamp: String, event: String, fields: [String: String]) -> Bool {
        guard let message = EventLogLine.messageForBuffer(event: event, fields: fields) else { return false }
        if event == "tailscale_provider_changed" {
            guard message != lastTailscaleMessage else { return false }
            lastTailscaleMessage = message
        }
        lines.append("\(EventLogLine.stamp(timestamp))  \(message)")
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        return true
    }

    /// Adds every record of a runtime log file (JSON lines), skipping lines that don't parse.
    public mutating func append(jsonLines text: String) {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = record["timestamp"] as? String,
                  let event = record["event"] as? String else { continue }
            append(timestamp: timestamp, event: event, fields: record["fields"] as? [String: String] ?? [:])
        }
    }
}
