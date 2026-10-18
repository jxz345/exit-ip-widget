#if os(macOS)
import Foundation
import XCTest
@testable import ExitIPShared

final class SingleInstanceLockTests: XCTestCase {
    func testSecondOwnerIsRejectedAndExitReleasesLockWithoutDeletingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var owner = try SingleInstanceLock(url: url)
        XCTAssertNotNil(owner)
        XCTAssertNil(try SingleInstanceLock(url: url))
        withExtendedLifetime(owner) {}
        owner = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try SingleInstanceLock(url: url), "A leftover file must not prevent a restart")
    }

    func testSymlinkIsRejectedInsteadOfLockingAnotherFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("other-file")
        try Data("unchanged".utf8).write(to: target)
        let link = directory.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SingleInstanceLock(url: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }
}
#endif
