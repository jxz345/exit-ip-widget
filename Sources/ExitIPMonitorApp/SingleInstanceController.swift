import AppKit

@MainActor
enum SingleInstanceController {
    private static var instanceLock: SingleInstanceLock?
    private static var observer: NSObjectProtocol?
    private static var ready = false
    private static var reopenPending = false
    private static let reopenNotification = Notification.Name("com.example.exitipmonitor.reopenExisting")

    static func acquire() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.exitipmonitor"
        // A diagnostic log override must never create a separate instance lock.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ExitIPMonitor", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else {
                reopenExisting(bundleID: bundleID)
                return false
            }
            // Older releases do not own the lock. Respect an already-running legacy copy too.
            if let existing = existingApplication(bundleID: bundleID) {
                reopenExisting(bundleID: bundleID, application: existing)
                withExtendedLifetime(lock) {}
                return false
            }
            instanceLock = lock
            observer = DistributedNotificationCenter.default().addObserver(
                forName: reopenNotification, object: bundleID, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    RuntimeLog.shared.info("duplicate_launch_reopened")
                    if ready { ExitIPAppDelegate.showDashboard() } else { reopenPending = true }
                }
            }
            return true
        } catch {
            RuntimeLog.shared.error("single_instance_lock_failed", fields: ["error": error.localizedDescription])
            let alert = NSAlert()
            alert.messageText = "Exit IP Monitor couldn't start safely"
            alert.informativeText = "The app couldn't check whether another copy is running. \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
    }

    static func didFinishLaunching() {
        ready = true
        if reopenPending {
            reopenPending = false
            ExitIPAppDelegate.showDashboard()
        }
    }

    private static func existingApplication(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.isFinishedLaunching && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
            .first
    }

    private static func reopenExisting(bundleID: String, application: NSRunningApplication? = nil) {
        RuntimeLog.shared.info("duplicate_instance_blocked", fields: ["pid": String(ProcessInfo.processInfo.processIdentifier)])
        DistributedNotificationCenter.default().postNotificationName(
            reopenNotification, object: bundleID, userInfo: nil, deliverImmediately: true
        )
        if let existing = application ?? existingApplication(bundleID: bundleID) {
            if let url = existing.bundleURL { NSWorkspace.shared.open(url) }
            existing.activate(options: [.activateAllWindows])
        }
    }
}
