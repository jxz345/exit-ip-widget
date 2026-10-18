import Foundation

/// A main-thread heartbeat lets an external installer distinguish a usable app from a process
/// suspended by macOS before main(), or an app blocked during startup. It contains no user data.
@MainActor
enum LaunchDiagnostics {
    private static let launchID = UUID().uuidString
    private static let started = Date()
    private static var ready = false
    private static var timer: Timer?
    private static var stage = "process_entered"
    private static let stateURL = RuntimeLog.shared.directory
        .appendingPathComponent("launch-\(ProcessInfo.processInfo.processIdentifier).json")

    static func record(_ event: String) {
        stage = event
        RuntimeLog.shared.info(event, fields: [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "launch_id": launchID,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        ])
        writeHeartbeat()
    }

    static func markReady() {
        guard !ready else { return }
        ready = true
        record("app_ready")
        let heartbeat = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in writeHeartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }

    static func stop() {
        ready = false
        timer?.invalidate()
        timer = nil
        record("app_terminating")
        try? FileManager.default.removeItem(at: stateURL)
    }

    private static func writeHeartbeat() {
        let record: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "launch_id": launchID,
            "started": Int(started.timeIntervalSince1970),
            "updated": Int(Date().timeIntervalSince1970),
            "ready": ready,
            "stage": stage,
            "bundle_path": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch {
            // Do not report success if the readiness file cannot be written; the external
            // checker will time out and collect this error from the runtime log.
            RuntimeLog.shared.error("launch_heartbeat_failed", fields: ["error": error.localizedDescription])
        }
    }
}

@main
enum ExitIPEntryPoint {
    @MainActor
    static func main() {
        guard SingleInstanceController.acquire() else { return }
        LaunchDiagnostics.record("process_entered")
        ExitIPMonitorApp.main()
    }
}
