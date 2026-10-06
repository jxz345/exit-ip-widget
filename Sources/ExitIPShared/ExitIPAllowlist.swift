import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Normalizes and stores the exact public addresses that are safe for this Mac.
public enum IPAddressValidator {
    public static func normalize(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains("/"), !candidate.contains(where: { $0.isWhitespace }) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let family: Int32 = candidate.contains(":") ? AF_INET6 : AF_INET
        let result = candidate.withCString { pointer in
            bytes.withUnsafeMutableBytes { buffer in
                inet_pton(family, pointer, buffer.baseAddress)
            }
        }
        guard result == 1 else { return nil }

        return candidate.lowercased()
    }

    public static func canonicalKey(_ value: String) -> String? {
        guard let normalized = normalize(value) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        let family: Int32 = normalized.contains(":") ? AF_INET6 : AF_INET
        let result = normalized.withCString { pointer in
            bytes.withUnsafeMutableBytes { buffer in
                inet_pton(family, pointer, buffer.baseAddress)
            }
        }
        guard result == 1 else { return nil }
        let length = family == AF_INET ? 4 : 16
        return bytes.prefix(length).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AllowedIPList: Codable, Equatable, Sendable {
    public private(set) var addresses: [String]

    public init(addresses: [String] = []) {
        var unique: [String] = []
        var keys = Set<String>()
        for value in addresses {
            guard let normalized = IPAddressValidator.normalize(value),
                  let key = IPAddressValidator.canonicalKey(normalized),
                  !keys.contains(key) else { continue }
            unique.append(normalized)
            keys.insert(key)
        }
        self.addresses = unique
    }

    public var isEmpty: Bool { addresses.isEmpty }

    public func contains(_ address: String) -> Bool {
        guard let key = IPAddressValidator.canonicalKey(address) else { return false }
        return addresses.contains { IPAddressValidator.canonicalKey($0) == key }
    }

    @discardableResult
    public mutating func insert(_ address: String) -> Bool {
        guard let normalized = IPAddressValidator.normalize(address), !contains(normalized) else { return false }
        addresses.append(normalized)
        return true
    }

    @discardableResult
    public mutating func remove(_ address: String) -> Bool {
        guard let key = IPAddressValidator.canonicalKey(address),
              let index = addresses.firstIndex(where: { IPAddressValidator.canonicalKey($0) == key }) else {
            return false
        }
        addresses.remove(at: index)
        return true
    }
}

public final class AllowedIPStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = ExitIPAppGroup.defaults, key: String = ExitIPPreferenceKey.allowedIPs) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AllowedIPList {
        guard let data = defaults.data(forKey: key), let list = try? decoder.decode(AllowedIPList.self, from: data) else {
            return AllowedIPList()
        }
        return AllowedIPList(addresses: list.addresses)
    }

    public func save(_ list: AllowedIPList) {
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}
