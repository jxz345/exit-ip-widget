#if !EXIT_IP_SERVICE_TEST
import Darwin
import Foundation
import Security

@main
enum DaemonMain {
    @MainActor
    static func main() {
        guard geteuid() == 0 else { fputs("Run the installed service through launchd.\n", stderr); exit(1) }
        umask(0o077)
        SecKeychainSetUserInteractionAllowed(false)
        do {
            if CommandLine.arguments.dropFirst() == ["--install-right"] {
                try ServiceAuthorization.installRight()
                return
            }
            if CommandLine.arguments.dropFirst() == ["--check-service"] {
                Task { @MainActor in
                    for _ in 0..<5 {
                        if let response = try? await DaemonRPC.call(DaemonRequest(.state), timeout: 2),
                           response.state?.build == "3.0" {
                            print("Background service 3.0 responds to XPC.")
                            exit(0)
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    exit(1)
                }
                RunLoop.main.run()
                return
            }
            guard CommandLine.arguments.count == 1 else { exit(2) }
            let directory = ExitIPService.storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else { exit(0) }
            let storage = try FilePreferenceStorage(url: ExitIPService.storageURL)
            let service = try DaemonService(storage: storage)
            let listener = NSXPCListener(machServiceName: ExitIPService.label)
            listener.delegate = service
            listener.resume()
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { service.stop(); listener.invalidate(); exit(0) }
            termination.resume()
            Task { await service.start() }
            RuntimeLog.shared.info("daemon_started", fields: ["pid": String(getpid())])
            withExtendedLifetime((lock, service, listener, termination)) { RunLoop.main.run() }
        } catch {
            RuntimeLog.shared.error("daemon_start_failed", fields: ["error": error.localizedDescription])
            exit(1)
        }
    }
}
#endif
