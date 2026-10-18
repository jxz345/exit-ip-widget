import XCTest
@testable import ExitIPShared

/// The dashboard's reading of the Tailscale → Clash Verge daemon state must match what the
/// responder serves (Sources/ExitIPDaemon/tailscale-verge.sh, Tests/ExitIPDaemonTests/http_test.sh).
final class TailscaleVergeProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func state(_ state: String = "direct", interface: String = "utun7", reason: String = "verified",
                       checked: String = "1999999999") -> String {
        "state=\(state)\ninterface=\(interface)\nreason=\(reason)\nchecked=\(checked)\nuid=501\n"
    }

    private func evaluate(_ text: String?) -> TailscaleVergeStatus {
        TailscaleVergeStatus.evaluate(stateText: text, now: now)
    }

    func testFreshDirectStateIsServedAsDirectOnItsInterface() {
        let status = evaluate(state())
        XCTAssertEqual(status.served, .direct(interface: "utun7"))
        XCTAssertEqual(status.checkedAt, Date(timeIntervalSince1970: 1_999_999_999))
        XCTAssertEqual(status.summary, "Direct on utun7")
        XCTAssertTrue(status.isDirect)
    }

    func testRejectStateKeepsTheMonitorsReason() {
        let status = evaluate(state("reject", interface: "", reason: "no-tailscale-route"))
        XCTAssertEqual(status.served, .reject(reason: "no-tailscale-route"))
        XCTAssertEqual(status.summary, "Reject · Tailscale isn't connected")
        XCTAssertFalse(status.isDirect)
    }

    func testStateOlderThanTwelveSecondsIsStaleAndServedAsReject() {
        XCTAssertEqual(evaluate(state(checked: "1999999988")).served, .direct(interface: "utun7"))
        let stale = evaluate(state(checked: "1999999987"))
        XCTAssertEqual(stale.served, .reject(reason: "monitor-stale"))
        XCTAssertEqual(stale.summary, "Reject · The monitor stopped updating")
        XCTAssertEqual(stale.checkedAt, Date(timeIntervalSince1970: 1_999_999_987))
    }

    func testCheckedTimeSlightlyAheadIsClampedButFarAheadIsStale() {
        XCTAssertEqual(evaluate(state(checked: "2000000002")).served, .direct(interface: "utun7"))
        XCTAssertEqual(evaluate(state(checked: "2000000060")).served, .reject(reason: "monitor-stale"))
    }

    func testNonUtunInterfaceIsNeverDirect() {
        XCTAssertEqual(evaluate(state(interface: "en0")).served, .reject(reason: "invalid-interface"))
        XCTAssertEqual(evaluate(state(interface: "utun")).served, .reject(reason: "invalid-interface"))
        XCTAssertEqual(evaluate(state(interface: "utun7 x")).served, .reject(reason: "invalid-interface"))
    }

    func testMalformedOrMissingStateIsReject() {
        XCTAssertEqual(evaluate(nil).served, .reject(reason: "starting"))
        XCTAssertNil(evaluate(nil).checkedAt)
        XCTAssertEqual(evaluate(state(checked: "soon")).served, .reject(reason: "monitor-error"))
        XCTAssertEqual(evaluate(state(checked: "01999999999")).served, .reject(reason: "monitor-error"))
        XCTAssertEqual(evaluate(state("maybe")).served, .reject(reason: "monitor-error"))
        XCTAssertEqual(evaluate(state(reason: "Not Valid")).served, .reject(reason: "monitor-error"))
        XCTAssertEqual(evaluate("").served, .reject(reason: "monitor-error"))
    }

    func testInstalledMeansTheMonitorPlistExists() {
        XCTAssertTrue(TailscaleVergeProvider.isInstalled { $0 == TailscaleVergeProvider.monitorPlistPath })
        XCTAssertFalse(TailscaleVergeProvider.isInstalled { _ in false })
    }

    func testLocationsMatchTheDaemonScripts() {
        XCTAssertEqual(TailscaleVergeProvider.providerFileURL.path, "/Library/Application Support/ExitIPMonitor/TailscaleVerge/provider.yaml")
        XCTAssertEqual(TailscaleVergeProvider.stateFileURL.path, "/Library/Application Support/ExitIPMonitor/TailscaleVerge/state")
        XCTAssertEqual(TailscaleVergeProvider.monitorPlistPath, "/Library/LaunchDaemons/com.example.exitipmonitor.tailscale-verge.plist")
        XCTAssertEqual(TailscaleVergeProvider.providerURL.absoluteString, "http://127.0.0.1:18766/provider.yaml")
        XCTAssertEqual(TailscaleVergeProvider.statusURL.absoluteString, "http://127.0.0.1:18766/status.json")
    }

    func testEveryReasonHasPlainWords() {
        let expected = [
            "tailscale-not-installed": "Tailscale isn't installed",
            "tailscale-cli-unavailable": "Tailscale isn't running or is logged out",
            "tailscale-cli-timeout": "Tailscale didn't answer in time",
            "no-tailscale-route": "Tailscale isn't connected",
            "no-tailscale-ip": "Tailscale has no IPv4 address yet",
            "no-console-user": "Nobody is logged in",
            "interface-not-owned-by-tailscale": "That tunnel isn't Tailscale's",
            "route-changed-during-check": "The route changed during the check",
            "route-timeout": "A check timed out",
            "route-recheck-timeout": "A check timed out",
            "interface-timeout": "A check timed out",
            "route-unavailable": "A check failed",
            "route-recheck-unavailable": "A check failed",
            "interface-unavailable": "A check failed",
            "monitor-stale": "The monitor stopped updating",
            "monitor-error": "The monitor's state can't be read",
            "invalid-interface": "The reported tunnel is invalid",
            "starting": "Starting up",
            "verified": "Verified",
            "something-new": "Something new"
        ]
        for (reason, text) in expected {
            XCTAssertEqual(TailscaleVergeStatus.reasonText(reason), text, reason)
        }
        // Every reason the monitor script can write has its own words (no generic fallback).
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ExitIPDaemon/tailscale-verge.sh")
        let text = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
        let pattern = try! NSRegularExpression(pattern: #"REASON=([a-z][a-z-]+)"#)
        let written = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
        XCTAssertTrue(written.isSuperset(of: ["tailscale-not-installed", "no-tailscale-route", "no-console-user", "verified"]))
        for reason in written.subtracting(["verified"]) {
            XCTAssertNotEqual(TailscaleVergeStatus.reasonText(reason).lowercased(), reason.replacingOccurrences(of: "-", with: " "),
                              "\(reason) falls back to its code")
        }
        let missing = TailscaleVergeStatus.evaluate(
            stateText: "state=reject\ninterface=\nreason=tailscale-not-installed\nchecked=2000000000\n",
            now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(missing.summary, "Reject · Tailscale isn't installed")
    }
}
