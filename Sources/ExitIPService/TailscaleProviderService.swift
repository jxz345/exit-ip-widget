import Darwin
import Foundation
@preconcurrency import Network
import SystemConfiguration

/// Runs fixed, read-only system commands off the actor. No shell or client-supplied executable.
enum BoundedProcess {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) -> (text: String, status: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return ("", -1) }
        defer { close(descriptors[0]) }
        let null = open("/dev/null", O_RDWR)
        guard null >= 0 else { close(descriptors[1]); return ("", -1) }
        defer { close(null) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(descriptors[1]); return ("", -1) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { close(descriptors[1]); return ("", -1) }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addclose(&actions, null)
        // Each probe has its own group so timeout also terminates sudo and its child CLI.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawn = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        close(descriptors[1])
        guard spawn == 0 else { return ("", -1) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var output = Data(), bytes = [UInt8](repeating: 0, count: 4096), status: Int32 = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            var count = read(descriptors[0], &bytes, bytes.count)
            while count > 0 {
                output.append(contentsOf: bytes.prefix(count))
                if output.count > 65536 { break }
                count = read(descriptors[0], &bytes, bytes.count)
            }
            if output.count > 65536 || ContinuousClock.now >= deadline {
                kill(-pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.1)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                return ("", output.count > 65536 ? 125 : 124)
            }
            if waitpid(pid, &status, WNOHANG) == pid {
                // Drain bytes written just before the child exited.
                count = read(descriptors[0], &bytes, bytes.count)
                while count > 0 && output.count <= 65536 {
                    output.append(contentsOf: bytes.prefix(count))
                    count = read(descriptors[0], &bytes, bytes.count)
                }
                guard output.count <= 65536 else { return ("", 125) }
                return (String(data: output, encoding: .utf8) ?? "", status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

struct TailscaleProbe {
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    struct Result: Sendable { var status: TailscaleVergeStatus; var user: uid_t? }

    static func check(previousUser: uid_t?) -> Result {
        func reject(_ reason: String) -> Result { Result(status: .init(served: .reject(reason: reason), checkedAt: .now), user: previousUser) }
        guard FileManager.default.isExecutableFile(atPath: cli) else { return reject("tailscale-not-installed") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        func run(_ executable: String, _ arguments: [String]) -> (text: String, status: Int32) {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard seconds > 0 else { return ("", 124) }
            return BoundedProcess.run(executable, arguments, timeout: min(2, seconds))
        }
        let route = run("/sbin/route", ["-n", "get", "100.100.100.100"])
        guard route.status == 0 else { return reject(route.status == 124 ? "route-timeout" : "route-unavailable") }
        guard let interface = NativeProviderProtocol.routeInterface(route.text) else { return reject("no-tailscale-route") }
        let users = candidateUsers(previousUser: previousUser)
        guard !users.isEmpty else { return reject("no-console-user") }
        // Keep each full pass within the freshness window, even with many sessions or stalled CLIs.
        var reason = "tailscale-cli-unavailable"
        for uid in users {
            guard ContinuousClock.now < deadline, let entry = getpwuid(uid) else { continue }
            let name = String(cString: entry.pointee.pw_name), home = String(cString: entry.pointee.pw_dir)
            let result = run("/usr/bin/sudo", ["-n", "-u", "#\(uid)", "--", "/usr/bin/env", "-i",
                "HOME=\(home)", "USER=\(name)", "LOGNAME=\(name)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C",
                "TAILSCALE_BE_CLI=1", cli, "ip", "-4"])
            guard result.status == 0 else { reason = result.status == 124 ? "tailscale-cli-timeout" : "tailscale-cli-unavailable"; continue }
            guard let address = NativeProviderProtocol.tailscaleAddress(result.text) else { reason = "no-tailscale-ip"; continue }
            let config = run("/sbin/ifconfig", [interface])
            guard config.status == 0, NativeProviderProtocol.ownsAddress(config.text, interface: interface, address: address) else {
                reason = "interface-not-owned-by-tailscale"; continue
            }
            let recheck = run("/sbin/route", ["-n", "get", "100.100.100.100"])
            guard recheck.status == 0, NativeProviderProtocol.routeInterface(recheck.text) == interface else { return reject("route-changed-during-check") }
            return Result(status: .init(served: .direct(interface: interface), checkedAt: .now), user: uid)
        }
        return reject(reason)
    }

    private static func candidateUsers(previousUser: uid_t?) -> [uid_t] {
        var result: [uid_t] = []
        func append(_ uid: uid_t) {
            if uid != 0, getpwuid(uid) != nil, !result.contains(uid) { result.append(uid) }
        }
        if let previousUser { append(previousUser) }
        var uid: uid_t = 0, gid: gid_t = 0
        if SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil { append(uid) }
        let bytes = proc_listallpids(nil, 0) * Int32(MemoryLayout<pid_t>.size) * 2
        guard bytes > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        for pid in pids.prefix(max(0, Int(count))) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == cli else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size { append(info.pbi_uid) }
        }
        return result
    }
}

@MainActor
final class TailscaleProviderService {
    private(set) var status: TailscaleVergeStatus?
    private(set) var error: String?
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var listenerRetry: Task<Void, Never>?
    private var enabled = false
    private var generation = 0

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        task?.cancel(); task = nil
        listenerRetry?.cancel(); listenerRetry = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        status = nil; error = nil
        guard enabled else { changed?(); return }
        startListener()
        let generation = generation
        task = Task { [weak self] in
            var previousUser: uid_t?
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { [previousUser] in TailscaleProbe.check(previousUser: previousUser) }.value
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                previousUser = result.user
                let changed = self.status?.served != result.status.served
                self.status = result.status
                self.writeProviderFiles(result)
                if changed { RuntimeLog.shared.info("tailscale_provider_changed", fields: TailscaleVergeChange.logFields(result.status.served)) }
                self.changed?()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func writeProviderFiles(_ result: TailscaleProbe.Result) {
        do {
            let directory = TailscaleVergeProvider.stateDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try Data(NativeProviderProtocol.yaml(result.status.served).utf8).write(to: TailscaleVergeProvider.providerFileURL, options: .atomic)
            let state: String, interface: String, reason: String
            switch result.status.served {
            case .direct(let value): state = "direct"; interface = value; reason = "verified"
            case .reject(let value): state = "reject"; interface = ""; reason = value
            }
            let text = "state=\(state)\ninterface=\(interface)\nreason=\(reason)\nchecked=\(Int(Date().timeIntervalSince1970))\nuid=\(result.user.map(String.init) ?? "")\n"
            try Data(text.utf8).write(to: TailscaleVergeProvider.stateFileURL, options: .atomic)
            for url in [TailscaleVergeProvider.stateFileURL, TailscaleVergeProvider.providerFileURL] {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
        } catch { self.error = "Could not write provider files: \(error.localizedDescription)" }
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18766)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.enabled, self.listener === listener else { return }
                    if case .ready = state { self.error = nil; self.changed?() }
                    if case .failed(let error) = state {
                        listener.cancel()
                        self.listener = nil
                        self.retryListener()
                        self.error = "Provider listener unavailable: \(error.localizedDescription)"
                        RuntimeLog.shared.error("provider_listener_failed", fields: ["error": error.localizedDescription])
                        self.changed?()
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription; retryListener() }
    }

    private func retryListener() {
        guard enabled, listenerRetry == nil else { return }
        listenerRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.enabled else { return }
            self.listenerRetry = nil
            self.startListener()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, data: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.close(id) }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193 - data.count) { [weak self] chunk, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil else { return }
                var next = data; if let chunk { next.append(chunk) }
                guard error == nil, next.count <= 8192 else { self.close(id); return }
                if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let response = NativeProviderProtocol.response(to: next, status: self.status) else { self.close(id); return }
                    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated { self?.close(id) }
                    })
                } else if complete { self.close(id) }
                else { self.receive(connection, id: id, data: next) }
            }
        }
    }
}
