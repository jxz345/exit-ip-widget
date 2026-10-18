import Foundation
import XCTest
@testable import ExitIPShared

final class DaemonInstallationTests: XCTestCase {
    func testZeroExitWithoutBothLoadedServicesIsNotSuccess() {
        for (monitor, responder) in [(false, false), (true, false), (false, true)] {
            XCTAssertEqual(DaemonInstallation.outcome(exitStatus: 0, output: "", monitorLoaded: monitor,
                                                    responderLoaded: responder), .failed)
        }
        XCTAssertEqual(DaemonInstallation.outcome(exitStatus: 0, output: "", monitorLoaded: true,
                                                responderLoaded: true), .succeeded)
        XCTAssertEqual(DaemonInstallation.outcome(exitStatus: 3, output: "Port in use", monitorLoaded: true,
                                                responderLoaded: false), .failed)
    }

    func testCancelledAuthenticationIsDistinctFromSetupFailure() {
        XCTAssertEqual(DaemonInstallation.outcome(exitStatus: 1, output: "User canceled. (-128)",
                                                monitorLoaded: false, responderLoaded: false), .cancelled)
        XCTAssertEqual(DaemonInstallation.outcome(exitStatus: 1, output: "Authorization denied. (-60005)",
                                                monitorLoaded: false, responderLoaded: false), .failed)
    }

    func testScriptPathAndUserNameCannotInjectShellCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("daemon ' $(touch INJECTED) \" \\ \n.sh")
        try Data("printf '%s\\n%s\\n' \"$SUDO_USER\" \"$1\"\n".utf8).write(to: script)
        let user = "jay'; touch INJECTED; #"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = directory
        process.arguments = ["-c", DaemonInstallation.shellCommand(scriptPath: script.path, userName: user)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\(user)\ninstall\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("INJECTED").path))
    }

    #if os(macOS)
    func testAdministratorScriptCompilesWithQuotedPathsWithoutRequestingAuthentication() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: file) }
        let script = DaemonInstallation.appleScript(scriptPath: "/Applications/Name ' \" \\ \n.app/daemon.sh",
                                                   userName: "name'with\\quotes")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", file.path, "-e", script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif
}
