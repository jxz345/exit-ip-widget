import Foundation
@preconcurrency import SystemConfiguration

/// Observes macOS SystemConfiguration changes that do not necessarily alter an
/// `NWPath`, including proxy settings, default route/DNS changes, service state,
/// and tunnel-interface changes.
final class NetworkConfigurationObserver {
    private var store: SCDynamicStore?
    private let onConfigurationChange: () -> Void

    init(onConfigurationChange: @escaping () -> Void) {
        self.onConfigurationChange = onConfigurationChange
    }

    func start() {
        guard store == nil else { return }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let dynamicStore = SCDynamicStoreCreate(
            nil,
            "com.example.exitipmonitor.network-configuration" as CFString,
            networkConfigurationDidChange,
            &context
        ) else {
            Self.logUnavailable(step: "create")
            return
        }

        // Every key must be unique: SystemConfiguration rejects the whole registration
        // ("Key already defined") if one repeats, which would silently disable this observer.
        let keys = Self.notificationKeys()
        let patterns = Self.notificationKeyPatterns()
        guard SCDynamicStoreSetNotificationKeys(
            dynamicStore,
            keys as CFArray,
            patterns as CFArray
        ) else {
            Self.logUnavailable(step: "set_notification_keys")
            return
        }

        // SystemConfiguration delivers the callback on the main queue, where
        // PublicIPMonitor coalesces it with NWPath and lifecycle notifications.
        guard SCDynamicStoreSetDispatchQueue(dynamicStore, DispatchQueue.main) else {
            Self.logUnavailable(step: "set_dispatch_queue")
            return
        }
        store = dynamicStore
    }

    private static func logUnavailable(step: String) {
        RuntimeLog.shared.error("network_configuration_monitor_unavailable", fields: [
            "step": step,
            "error": String(cString: SCErrorString(SCError()))
        ])
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    fileprivate func notifyConfigurationChange(changedKeys: [String]) {
        RuntimeLog.shared.info("network_configuration_changed", fields: ["keys": changedKeys.joined(separator: ",")])
        onConfigurationChange()
    }

    private static func notificationKeys() -> [CFString] {
        [
            // State:/Network/Global/Proxies (the same key as the kSCEntNetProxies global entity, so
            // that entity must not be listed again).
            SCDynamicStoreKeyCreateProxies(nil),
            SCDynamicStoreKeyCreateLocation(nil),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetDNS),
            // Service order (which service owns the default route) and the interface list, so a
            // utun/VPN interface appearing or disappearing is noticed even before it has addresses.
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainSetup, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkInterface(nil, kSCDynamicStoreDomainState)
        ]
    }

    private static func notificationKeyPatterns() -> [CFString] {
        let strings: [String] = [
            "^State:/Network/Service/[^/]+/IPv4$",
            "^State:/Network/Service/[^/]+/IPv6$",
            "^State:/Network/Service/[^/]+/DNS$",
            "^State:/Network/Service/[^/]+/Proxies$",
            "^State:/Network/Service/[^/]+/PPP$",
            "^State:/Network/Service/[^/]+/IPSec$",
            "^State:/Network/Service/[^/]+/VPN$",
            "^Setup:/Network/Service/[^/]+/IPv4$",
            "^Setup:/Network/Service/[^/]+/IPv6$",
            "^Setup:/Network/Service/[^/]+/DNS$",
            "^Setup:/Network/Service/[^/]+/Proxies$",
            "^State:/Network/Interface/[^/]+/Link$",
            "^State:/Network/Interface/[^/]+/IPv4$",
            "^State:/Network/Interface/[^/]+/IPv6$"
        ]
        return strings.map { ($0 as NSString) as CFString }
    }
}

private func networkConfigurationDidChange(
    _: SCDynamicStore,
    changedKeys: CFArray,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let observer = Unmanaged<NetworkConfigurationObserver>
        .fromOpaque(info)
        .takeUnretainedValue()
    observer.notifyConfigurationChange(changedKeys: (changedKeys as? [String]) ?? [])
}
