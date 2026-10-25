import XCTest
@testable import ExitIPShared

/// Names for the profile copies dragged into Clash Verge Rev, checked against the names in its
/// `profiles.yaml`. Dummy names only.
final class ClashVergeProfileNamingTests: XCTestCase {
    /// The shape Clash Verge Rev 2.5.8 writes (serde_yaml), with every quoting style a name can take.
    private let profilesIndex = """
    # Profiles Config for Clash Verge

    current: LxAoLWs6xoOQ
    items:
    - uid: Merge
      type: merge
      name: null
      file: Merge.yaml
      updated: 1790265651
    - uid: LPtB4ijfHGLt
      type: local
      name: clash-verge 5.yaml
      file: LPtB4ijfHGLt.yaml
      updated: 1792255891
      option:
        merge: m9RyfTrTQfqV
        name: nested-not-a-profile
    - uid: R1
      type: remote
      name: 'Exit IP Monitor 2026-10-25 (1)'
      file: R1.yaml
      desc: ''
    - uid: L2
      type: local
      name: "Exit IP Monitor 2026-10-25 (3).yaml"
      latency_test_urls:
      - name: list-entry
    - name: It''s "quoted" \\u00e9
      uid: R3
    - uid: R4
      name: 'It''s single'
    """

    private func date() throws -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        // 2026-10-24 20:00 UTC is already the 25th in Singapore.
        return (try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T20:00:00Z")), calendar)
    }

    func testNamesAreTheItemsOwnNamesUnquoted() {
        XCTAssertEqual(ClashVergeProfileNaming.names(inProfilesIndex: profilesIndex), [
            "clash-verge 5.yaml", "Exit IP Monitor 2026-10-25 (1)", "Exit IP Monitor 2026-10-25 (3).yaml",
            "It''s \"quoted\" \\u00e9", "It's single"
        ])
        XCTAssertEqual(ClashVergeProfileNaming.scalar("\"a \\\"b\\\" \\\\ \\u00e9\""), "a \"b\" \\ é")
        XCTAssertEqual(ClashVergeProfileNaming.scalar(" plain #comment"), "plain")
        XCTAssertNil(ClashVergeProfileNaming.scalar(" ~"))
        XCTAssertEqual(ClashVergeProfileNaming.names(inProfilesIndex: "current: null\nitems: []\n"), [])
        XCTAssertEqual(ClashVergeProfileNaming.names(inProfilesIndex: "items:\r\n- uid: L1\r\n  name: crlf\r\n"), ["crlf"])
        XCTAssertEqual(ClashVergeProfileNaming.names(inProfilesIndex: "other:\n  name: not-an-item\n"), [])
    }

    func testTheNextNameUsesTheLocalDateAndTheLowestFreeCopy() throws {
        let (date, calendar) = try date()
        func next(_ existing: [String]) -> String {
            ClashVergeProfileNaming.nextProfileName(existing: existing, date: date, calendar: calendar)
        }
        XCTAssertEqual(next([]), "Exit IP Monitor 2026-10-25 (1)")
        XCTAssertEqual(next(["Exit IP Monitor 2026-10-25 (1)"]), "Exit IP Monitor 2026-10-25 (2)")
        XCTAssertEqual(next(ClashVergeProfileNaming.names(inProfilesIndex: profilesIndex)), "Exit IP Monitor 2026-10-25 (2)",
                       "The lowest free number fills a gap")
        XCTAssertEqual(next(["Exit IP Monitor 2026-10-24 (1)", "Exit IP Monitor 2026-10-25"]), "Exit IP Monitor 2026-10-25 (1)",
                       "Other dates and other names don't count")
    }

    func testADroppedFileNameTakesItsNameWithOrWithoutTheExtension() throws {
        let (date, calendar) = try date()
        func next(_ existing: [String]) -> String {
            ClashVergeProfileNaming.nextProfileName(existing: existing, date: date, calendar: calendar)
        }
        XCTAssertEqual(next(["Exit IP Monitor 2026-10-25 (1).yaml"]), "Exit IP Monitor 2026-10-25 (2)",
                       "Clash Verge names a dropped file's profile with its .yaml ending")
        XCTAssertEqual(next(["Exit IP Monitor 2026-10-25 (1).yml", "Exit IP Monitor 2026-10-25 (2)"]), "Exit IP Monitor 2026-10-25 (3)")
        XCTAssertEqual(next(["Exit IP Monitor 2026-10-25 (1).yaml.bak"]), "Exit IP Monitor 2026-10-25 (1)")
    }
}
