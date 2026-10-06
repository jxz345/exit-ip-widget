import Darwin

/// Decides which kernel routing-socket (`PF_ROUTE`) messages describe a change in how traffic
/// leaves the Mac. TUN tools often install split default routes (`0/1`, `128/1`, …) directly in
/// the kernel without updating SystemConfiguration, so these messages are the only signal for
/// them. Everything else on the socket—ARP/ND cache entries, per-connection cloned routes,
/// lookup misses, and Apple-internal peer-to-peer interfaces—is noise that must not cost a lookup.
public enum RouteChangeFilter {
    /// Loopback, tunnelling shims, and Apple's AWDL/low-latency/internal interfaces never carry the
    /// public exit path, and AWDL in particular toggles whenever AirDrop or Continuity is active.
    public static let ignoredInterfacePrefixes = ["lo", "gif", "stf", "awdl", "llw", "anpi"]

    /// Flags marking kernel-generated routes: clones of a network route for one destination,
    /// link-layer (ARP/ND) entries, and ICMP-redirect results.
    static let ignoredRouteFlags = RTF_WASCLONED | RTF_LLINFO | RTF_DYNAMIC

    public static func isRelevant(messageType: Int32, routeFlags: Int32 = 0, interfaceName: String?) -> Bool {
        if let interfaceName, ignoredInterfacePrefixes.contains(where: { interfaceName.hasPrefix($0) }) {
            return false
        }
        switch messageType {
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            return routeFlags & ignoredRouteFlags == 0
        case RTM_NEWADDR, RTM_DELADDR, RTM_IFINFO:
            return true
        default:
            return false
        }
    }
}
