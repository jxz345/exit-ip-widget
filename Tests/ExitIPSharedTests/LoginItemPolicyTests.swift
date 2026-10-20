import XCTest
@testable import ExitIPShared

/// Launch at login is the remembered choice, re-applied at launch when macOS dropped the registration.
final class LoginItemPolicyTests: XCTestCase {
    func testAChosenLoginItemIsRestoredWhenTheRegistrationWasDropped() {
        XCTAssertEqual(LoginItemPolicy.action(stored: true, status: .notRegistered), .register)
        XCTAssertEqual(LoginItemPolicy.action(stored: true, status: .notFound), .register)
        XCTAssertEqual(LoginItemPolicy.action(stored: true, status: .enabled), .none)
    }

    func testPendingApprovalIsLeftToTheUserSoTheAppNeverLoops() {
        XCTAssertEqual(LoginItemPolicy.action(stored: true, status: .requiresApproval), .none)
    }

    func testTurningItOffRemovesALeftoverRegistration() {
        XCTAssertEqual(LoginItemPolicy.action(stored: false, status: .enabled), .unregister)
        XCTAssertEqual(LoginItemPolicy.action(stored: false, status: .requiresApproval), .unregister)
        XCTAssertEqual(LoginItemPolicy.action(stored: false, status: .notRegistered), .none)
        XCTAssertEqual(LoginItemPolicy.action(stored: false, status: .notFound), .none)
    }

    func testARegistrationFromBeforeTheChoiceWasRememberedIsAdopted() {
        XCTAssertEqual(LoginItemPolicy.action(stored: nil, status: .enabled), .adopt)
        XCTAssertEqual(LoginItemPolicy.action(stored: nil, status: .requiresApproval), .adopt)
        XCTAssertEqual(LoginItemPolicy.action(stored: nil, status: .notRegistered), .none)
        XCTAssertEqual(LoginItemPolicy.action(stored: nil, status: .notFound), .none)
    }

    func testTheEventLogShowsOnlyRestoredRemovedOrFailedSyncs() {
        XCTAssertEqual(EventLogLine.message(event: "login_item_synced", fields: ["action": "register", "result": "ok"]),
                       "Launch at login restored")
        XCTAssertEqual(EventLogLine.message(event: "login_item_synced", fields: ["action": "unregister", "result": "ok"]),
                       "Launch at login turned off, as chosen")
        XCTAssertEqual(EventLogLine.message(event: "login_item_synced",
                                            fields: ["action": "register", "result": "failed", "error": "Operation not permitted"]),
                       "Launch at login couldn't be restored · Operation not permitted")
        XCTAssertNil(EventLogLine.message(event: "login_item_synced", fields: ["action": "none", "result": "ok"]))
        XCTAssertNil(EventLogLine.message(event: "login_item_synced", fields: ["action": "adopt", "result": "ok"]))
        XCTAssertNil(EventLogLine.message(event: "dock_icon_updated", fields: [:]))
        XCTAssertNil(EventLogLine.message(event: "windows_closed_by_shortcut", fields: ["count": "1"]))
    }
}
