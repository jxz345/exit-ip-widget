import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import ExitIPShared

/// The Event Log window's lines: one concise UTC line per important event, nothing for routine records.
final class EventLogLineTests: XCTestCase {
    private let at = "2026-10-18T13:28:56Z"

    private func line(_ event: String, _ fields: [String: String] = [:]) -> String? {
        EventLogLine.format(timestamp: at, event: event, fields: fields)
    }

    func testLinesStartWithAUTCStamp() {
        XCTAssertEqual(line("monitor_started"), "2026-10-18 13:28:56Z  App started")
        XCTAssertEqual(EventLogLine.format(timestamp: "2026-10-18T13:28:56.123Z", event: "monitor_stopped", fields: [:]),
                       "2026-10-18 13:28:56Z  App quit")
    }

    func testChecksNameTheirTriggerAndProvider() {
        XCTAssertEqual(line("refresh_requested", ["trigger": "route_change", "provider": "ipWhois", "urgency": "network_change"]),
                       "2026-10-18 13:28:56Z  Check · route changed · IPWHOIS.io")
        XCTAssertEqual(EventLogLine.message(event: "refresh_requested", fields: ["trigger": "manual", "provider": "ipapiCo"]),
                       "Check · Refresh now · ipapi.co")
        XCTAssertEqual(EventLogLine.message(event: "refresh_requested", fields: ["trigger": "periodic", "provider": "ipapiIs"]),
                       "Check · timer · ipapi.is")
        for (raw, phrase) in [("startup", "app start"), ("network_path", "network path changed"),
                              ("network_configuration", "network settings changed"), ("system_wake", "Mac woke"),
                              ("screens_wake", "screen woke"), ("session_active", "session active"),
                              ("app_active", "app activated"), ("trailing", "follow-up after events"),
                              ("queued", "queued check"), ("retry", "retry"), ("recheck", "recheck"),
                              ("provider_changed", "provider changed"), ("settings_changed", "settings changed")] {
            XCTAssertEqual(EventLogLine.trigger(raw), phrase)
        }
    }

    func testResultsAndPolicyEvents() {
        func message(_ event: String, _ fields: [String: String]) -> String? { EventLogLine.message(event: event, fields: fields) }
        XCTAssertEqual(message("lookup_succeeded", ["provider": "ipWhois", "country": "SG"]), "Lookup OK · IPWHOIS.io · SG")
        XCTAssertEqual(message("lookup_failed", ["provider": "ipapiCo", "message": "timed out"]), "Lookup failed · ipapi.co · timed out")
        // The dashboard no longer shows installation details, so the line doesn't point there.
        XCTAssertEqual(message("daemon_install_failed", ["log": "/tmp/daemon-setup.log"]), "Provider installation failed")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "app_active", "reason": "fresh"]),
                       "Skipped · app activated · result under 2 min old")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "screens_wake", "reason": "event_window"]),
                       "Skipped · screen woke · absorbed by the check just run")
        XCTAssertEqual(message("refresh_event_merged", ["trigger": "route_change", "trailingAt": "2026-10-18T13:29:01Z"]),
                       "Merged · route changed → follow-up at 13:29:01Z")
        XCTAssertEqual(message("refresh_queued", ["reason": "provider_gap", "notBefore": "2026-10-18T13:29:01Z"]),
                       "Queued · provider gap · at 13:29:01Z")
        XCTAssertEqual(message("lookup_rate_limited", ["provider": "ipapiIs", "retryNotBefore": "2026-10-19T00:00:00Z"]),
                       "Provider paused · ipapi.is until 00:00:00Z")
        XCTAssertEqual(message("lookup_all_providers_paused", ["resumeAt": "2026-10-19T08:00:00Z"]),
                       "All providers paused until 08:00:00Z")
        XCTAssertEqual(message("lookup_daily_budget_exhausted", ["provider": "ipapiIs", "resetAt": "2026-10-19T00:00:00Z"]),
                       "Daily budget used · ipapi.is · resets 00:00:00Z")
        XCTAssertEqual(message("confirmation_result", ["provider": "ipapiCo", "country": "SG", "agrees": "true"]),
                       "Country confirmed · ipapi.co · SG")
        XCTAssertEqual(message("confirmation_result", ["provider": "ipapiCo", "country": "JP", "agrees": "false"]),
                       "Country not confirmed · ipapi.co · JP")
        XCTAssertEqual(message("allowlist_warning_presented", ["ip": "<redacted-ip>"]), "Exit IP not on allowlist · <redacted-ip>")
        XCTAssertEqual(message("clash_profile_written", ["path": "/x"]), "Clash Verge profile written")
        XCTAssertEqual(message("clash_profile_copy_written", ["name": "Exit IP Monitor 2026-10-25 (3).yaml"]),
                       "Clash Verge profile copy · Exit IP Monitor 2026-10-25 (3).yaml")
        XCTAssertEqual(message("keychain_operation", ["operation": "load", "outcome": "started", "duration_ms": "0"]),
                       "Keychain load · started")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "startup", "reason": "token_unavailable"]),
                       "Skipped · app start · load or save the IPinfo token in Settings")
    }

    func testTailscaleProviderLines() {
        XCTAssertEqual(EventLogLine.message(event: "tailscale_provider_changed",
                                            fields: TailscaleVergeChange.logFields(.direct(interface: "utun7"))),
                       "Tailscale provider · Direct utun7")
        XCTAssertEqual(EventLogLine.message(event: "tailscale_provider_changed",
                                            fields: TailscaleVergeChange.logFields(.reject(reason: "no-tailscale-route"))),
                       "Tailscale provider · Reject (Tailscale isn't connected)")
        XCTAssertEqual(EventLogLine.message(event: "tailscale_provider_changed",
                                            fields: TailscaleVergeChange.logFields(.reject(reason: "tailscale-not-installed"))),
                       "Tailscale provider · Reject (Tailscale isn't installed)")
    }

    func testRoutineRecordsAreNotShown() {
        for event in ["provider_health_changed", "network_path_unchanged", "lookup_started", "widget_reload_requested",
                      "refresh_coalesced_in_flight", "network_configuration_changed", "diagnostic_preferences_changed",
                      "debug_simulation_started", "something_new"] {
            XCTAssertNil(line(event, ["provider": "ipapiCo"]), event)
        }
    }

    func testLongMessagesAreCutToOneLine() throws {
        let text = try XCTUnwrap(EventLogLine.message(event: "lookup_failed",
                                                     fields: ["provider": "ipapiCo", "message": String(repeating: "x", count: 300) + "\nmore"]))
        let cut = EventLogLine.truncated(text)
        XCTAssertEqual(cut.count, EventLogLine.maximumMessageLength)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.contains("\n"))
    }

    func testTailscaleChangeIgnoresRepeatsAndCountsRealChanges() {
        let direct7 = TailscaleVergeStatus.Served.direct(interface: "utun7")
        XCTAssertEqual(TailscaleVergeChange.next(previous: nil, current: direct7), direct7, "the first reading is recorded")
        XCTAssertNil(TailscaleVergeChange.next(previous: direct7, current: direct7), "routine rewrites are not recorded")
        // Same served value from two state files with different ages: still nothing to record.
        let a = TailscaleVergeStatus.evaluate(stateText: "state=direct\ninterface=utun7\nreason=verified\nchecked=1999999990\n",
                                              now: Date(timeIntervalSince1970: 2_000_000_000))
        let b = TailscaleVergeStatus.evaluate(stateText: "state=direct\ninterface=utun7\nreason=verified\nchecked=1999999998\n",
                                              now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(TailscaleVergeChange.next(previous: a.served, current: b.served))
        XCTAssertEqual(TailscaleVergeChange.next(previous: direct7, current: .reject(reason: "no-tailscale-route")),
                       .reject(reason: "no-tailscale-route"))
        XCTAssertEqual(TailscaleVergeChange.next(previous: direct7, current: .direct(interface: "utun8")), .direct(interface: "utun8"))
        XCTAssertEqual(TailscaleVergeChange.next(previous: .reject(reason: "no-tailscale-route"), current: .reject(reason: "monitor-stale")),
                       .reject(reason: "monitor-stale"))
    }

    func testMonitoringSummaryDescribesTimerAndEvents() {
        XCTAssertEqual(MonitoringRules.summary(interval: .fifteenMinutes),
                       "Checks every 15 minutes, and right after a network, route, proxy, DNS, VPN/TUN, wake, or app-activation change.")
        XCTAssertTrue(MonitoringRules.summary(interval: .sixtyMinutes).hasPrefix("Checks every hour, and right after"))
        for interval in RefreshInterval.allCases {
            XCTAssertFalse(MonitoringRules.summary(interval: interval).contains("recommended"))
        }
    }

    func testStopSymbolIsAValidSFSymbol() {
        XCTAssertEqual(ExitIPIndicatorSymbol.lookupError, "xmark.octagon.fill")
        XCTAssertNotEqual(ExitIPIndicatorSymbol.lookupError, ExitIPIndicatorSymbol.countryChanged)
        // The allowlist mismatch uses the same stop sign, drawn red.
        XCTAssertEqual(ExitIPIndicatorSymbol.outsideAllowlist, ExitIPIndicatorSymbol.lookupError)
        #if canImport(AppKit)
        XCTAssertNotNil(NSImage(systemSymbolName: ExitIPIndicatorSymbol.lookupError, accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: ExitIPIndicatorSymbol.countryChanged, accessibilityDescription: nil))
        #endif
    }
}

final class EventLogBufferTests: XCTestCase {
    func testRepeatedTailscaleLinesAreDroppedButOtherEventsAreKept() {
        var buffer = EventLogBuffer()
        let direct = TailscaleVergeChange.logFields(.direct(interface: "utun7"))
        XCTAssertTrue(buffer.append(timestamp: "2026-10-18T13:00:00Z", event: "tailscale_provider_changed", fields: direct))
        XCTAssertFalse(buffer.append(timestamp: "2026-10-18T13:05:00Z", event: "tailscale_provider_changed", fields: direct),
                       "a later launch recording the same starting value adds no line")
        XCTAssertTrue(buffer.append(timestamp: "2026-10-18T13:06:00Z", event: "monitor_started", fields: [:]))
        XCTAssertTrue(buffer.append(timestamp: "2026-10-18T13:07:00Z", event: "tailscale_provider_changed",
                                    fields: TailscaleVergeChange.logFields(.reject(reason: "no-tailscale-route"))))
        XCTAssertTrue(buffer.append(timestamp: "2026-10-18T13:07:04Z", event: "tailscale_provider_changed", fields: direct))
        XCTAssertFalse(buffer.append(timestamp: "2026-10-18T13:07:05Z", event: "widget_reload_requested", fields: [:]))
        XCTAssertEqual(buffer.lines, [
            "2026-10-18 13:00:00Z  Tailscale provider · Direct utun7",
            "2026-10-18 13:06:00Z  App started",
            "2026-10-18 13:07:00Z  Tailscale provider · Reject (Tailscale isn't connected)",
            "2026-10-18 13:07:04Z  Tailscale provider · Direct utun7"
        ])
    }

    func testKeepsOnlyTheNewestLines() {
        var buffer = EventLogBuffer(limit: 3)
        for second in 0..<5 {
            buffer.append(timestamp: "2026-10-18T13:00:0\(second)Z", event: "error_cleared", fields: [:])
        }
        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertTrue(buffer.lines[0].hasPrefix("2026-10-18 13:00:02Z"))
    }

    func testReadsRuntimeLogJSONLines() {
        var buffer = EventLogBuffer()
        buffer.append(jsonLines: """
        {"timestamp":"2026-10-18T13:28:56Z","level":"info","event":"lookup_succeeded","fields":{"provider":"ipWhois","country":"SG"}}
        not json
        {"timestamp":"2026-10-18T13:28:57Z","level":"info","event":"provider_health_changed","fields":{}}
        {"timestamp":"2026-10-18T13:28:58Z","level":"info","event":"refresh_requested","fields":{"trigger":"system_wake","provider":"ipapiCo"}}
        """)
        XCTAssertEqual(buffer.lines, [
            "2026-10-18 13:28:56Z  Lookup OK · IPWHOIS.io · SG",
            "2026-10-18 13:28:58Z  Check · Mac woke · ipapi.co"
        ])
    }
}
