import Darwin
import Foundation

/// Watches the kernel routing socket for route, gateway, address, and interface changes.
/// `NetworkConfigurationObserver` only sees what is published to SystemConfiguration; a TUN tool
/// that installs its routes directly (e.g. split `0/1` + `128/1` default routes) is visible only here.
/// `RouteChangeFilter` drops kernel noise so ordinary traffic never triggers a lookup.
final class RouteChangeObserver {
    private let queue = DispatchQueue(label: "com.example.exitipmonitor.route-socket")
    private var source: DispatchSourceRead?
    private let onRouteChange: () -> Void

    init(onRouteChange: @escaping () -> Void) {
        self.onRouteChange = onRouteChange
    }

    func start() {
        guard source == nil else { return }
        let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard descriptor >= 0 else {
            RuntimeLog.shared.error("route_monitor_unavailable", fields: ["errno": String(errno)])
            return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(descriptor)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Reads every pending message (one per `read`) and reports at most once per wakeup;
    /// `PublicIPMonitor` debounces further and the persisted 5-second gate still applies.
    private func drain(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var relevant = false
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            if !relevant {
                relevant = buffer.withUnsafeBytes { Self.isRelevant(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
        }
        if relevant {
            onRouteChange()
        }
    }

    private static func isRelevant(_ message: UnsafeRawBufferPointer) -> Bool {
        // Every routing message starts with msglen (u_short), version (u_char), type (u_char).
        guard message.count >= 4 else { return false }
        let type = Int32(message[3])
        switch type {
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            guard message.count >= MemoryLayout<rt_msghdr>.size else { return false }
            let header = message.loadUnaligned(as: rt_msghdr.self)
            return RouteChangeFilter.isRelevant(
                messageType: type,
                routeFlags: header.rtm_flags,
                interfaceName: interfaceName(for: header.rtm_index)
            )
        case RTM_NEWADDR, RTM_DELADDR:
            guard message.count >= MemoryLayout<ifa_msghdr>.size else { return false }
            let header = message.loadUnaligned(as: ifa_msghdr.self)
            return RouteChangeFilter.isRelevant(messageType: type, interfaceName: interfaceName(for: header.ifam_index))
        case RTM_IFINFO:
            guard message.count >= MemoryLayout<if_msghdr>.size else { return false }
            let header = message.loadUnaligned(as: if_msghdr.self)
            return RouteChangeFilter.isRelevant(messageType: type, interfaceName: interfaceName(for: header.ifm_index))
        default:
            return false
        }
    }

    private static func interfaceName(for index: UInt16) -> String? {
        guard index > 0 else { return nil }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        let bytes = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
