import AppKit
import Darwin
import SwiftUI

/// One model per dashboard, shared by both responsive layouts. Authentication and launchctl
/// run off the main thread so the dashboard and launch heartbeat remain responsive.
@MainActor
final class DaemonInstallationModel: ObservableObject {
    @Published private(set) var monitorInstalled = false
    @Published private(set) var responderInstalled = false
    @Published private(set) var status: TailscaleVergeStatus?
    @Published private(set) var isInstalling = false
    @Published private(set) var message: String?
    @Published private(set) var hasError = false

    var isInstalled: Bool { monitorInstalled && responderInstalled }

    init() { reload() }

    func reload() {
        monitorInstalled = TailscaleVergeProvider.isInstalled()
        responderInstalled = FileManager.default.fileExists(atPath: TailscaleVergeProvider.responderPlistPath)
        let text = try? String(contentsOf: TailscaleVergeProvider.stateFileURL, encoding: .utf8)
        status = monitorInstalled ? TailscaleVergeStatus.evaluate(stateText: text, now: Date()) : nil
    }

    func install() {
        guard !isInstalling else { return }
        guard let script = Bundle.main.url(forResource: "daemon", withExtension: "sh") else {
            hasError = true
            message = "The installer is missing from this app. Reinstall the current release."
            RuntimeLog.shared.error("daemon_install_failed", fields: ["reason": "missing_bundled_script"])
            return
        }
        isInstalling = true
        hasError = false
        message = "Complete macOS administrator authentication to install the background provider."
        // The setup output is saved here: the outcome check reads it, and the runtime log points to it.
        let logURL = RuntimeLog.shared.directory.appendingPathComponent("daemon-setup-\(UUID().uuidString).log")
        let appleScript = DaemonInstallation.appleScript(scriptPath: script.path, userName: NSUserName())
        RuntimeLog.shared.info("daemon_install_started", fields: ["log": logURL.path])
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runInstaller(appleScript: appleScript, logURL: logURL)
            }.value
            reload()
            isInstalling = false
            switch result.outcome {
            case .succeeded:
                message = "Background provider installed and both services loaded."
                RuntimeLog.shared.info("daemon_install_succeeded", fields: ["log": logURL.path])
            case .cancelled:
                message = "Installation cancelled. Click Install Provider to try again."
                RuntimeLog.shared.info("daemon_install_cancelled", fields: ["log": logURL.path])
            case .failed:
                hasError = true
                message = "Provider installation did not complete. Click Retry Installation to try again."
                RuntimeLog.shared.error("daemon_install_failed", fields: ["log": logURL.path])
            }
        }
    }

    private struct Result: Sendable {
        let outcome: DaemonInstallation.Outcome
        let output: String
    }

    nonisolated private static func runInstaller(appleScript: String, logURL: URL) -> Result {
        do {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            // A file avoids pipe-buffer deadlocks, even with verbose daemon diagnostics.
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            let monitorLoaded = process.terminationStatus == 0 && jobLoaded(TailscaleVergeProvider.monitorLabel)
            let responderLoaded = process.terminationStatus == 0 && jobLoaded(TailscaleVergeProvider.responderLabel)
            if process.terminationStatus == 0 && (!monitorLoaded || !responderLoaded) {
                try log.write(contentsOf: Data("\nVerification failed: both background services must be loaded.\n".utf8))
            }
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No installer output was available."
            return Result(outcome: DaemonInstallation.outcome(exitStatus: process.terminationStatus,
                          output: output, monitorLoaded: monitorLoaded, responderLoaded: responderLoaded),
                          output: String(output.suffix(16_000)))
        } catch {
            return Result(outcome: .failed, output: error.localizedDescription)
        }
    }

    nonisolated private static func jobLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Do not leave post-install verification waiting indefinitely on launchd.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !process.isRunning else {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
