import AppKit
import Darwin

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
            // Older releases do not own the lock. Respect a legacy copy belonging to this user too.
            if let existing = existingApplication(bundleID: bundleID) {
                reopenExisting(bundleID: bundleID, application: existing)
                withExtendedLifetime(lock) {}
                return false
            }
            instanceLock = lock
            observer = DistributedNotificationCenter.default().addObserver(
                forName: reopenNotification, object: reopenObject(bundleID: bundleID), queue: .main
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
            .filter { isCurrentUserProcess($0.processIdentifier) }
            .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
            .first
    }

    static func isCurrentUserProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == getuid()
    }

    static func reopenObject(bundleID: String, userID: uid_t = getuid()) -> String {
        "\(bundleID).\(userID)"
    }

    private static func reopenExisting(bundleID: String, application: NSRunningApplication? = nil) {
        RuntimeLog.shared.info("duplicate_instance_blocked", fields: ["pid": String(ProcessInfo.processInfo.processIdentifier)])
        DistributedNotificationCenter.default().postNotificationName(
            reopenNotification, object: reopenObject(bundleID: bundleID), userInfo: nil, deliverImmediately: true
        )
        if let existing = application ?? existingApplication(bundleID: bundleID) {
            if let url = existing.bundleURL { NSWorkspace.shared.open(url) }
            existing.activate(options: [.activateAllWindows])
        }
    }
}
