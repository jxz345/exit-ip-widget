import Foundation

/// The same native administrator authentication used by Sleepless. Arguments are quoted for
/// both the shell and AppleScript; no password is accepted or stored by the app.
public enum DaemonInstallation {
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case cancelled
        case failed
    }

    public static func shellCommand(scriptPath: String, userName: String) -> String {
        "/usr/bin/env SUDO_USER=\(shellQuote(userName)) /bin/bash \(shellQuote(scriptPath)) install"
    }

    public static func appleScript(scriptPath: String, userName: String) -> String {
        let command = shellCommand(scriptPath: scriptPath, userName: userName)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(command)\" with administrator privileges"
    }

    public static func outcome(exitStatus: Int32, output: String, monitorLoaded: Bool,
                               responderLoaded: Bool) -> Outcome {
        if exitStatus == 0 {
            return monitorLoaded && responderLoaded ? .succeeded : .failed
        }
        // osascript normally exits 1 and prints the Apple event cancellation code (-128).
        if output.contains("(-128)") { return .cancelled }
        return .failed
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
