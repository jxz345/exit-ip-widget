import Foundation

/// The one proxy the generated Clash Verge profile routes `MATCH,Proxy` traffic through. Entered in the
/// dashboard and stored only in the Keychain (`ClashVergeProfile.keychainAccount`) and in the generated
/// 0600 profile file. Never log it, and never commit real values: tests use RFC 5737 addresses.
public struct ClashProxySettings: Codable, Equatable, Sendable {
    public enum ProxyType: String, Codable, CaseIterable, Sendable, Identifiable {
        case socks5
        case http

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .socks5: "SOCKS5"
            case .http: "HTTP"
            }
        }
    }

    public enum ValidationError: LocalizedError, Equatable {
        case invalidName
        case reservedName(String)
        case invalidServer
        case invalidPort
        case invalidCharacters(field: String)
        case passwordWithoutUsername

        public var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a proxy name of up to 64 letters, digits, spaces, dots, dashes, or underscores."
            case .reservedName(let name): "\(name) is already used by the profile; choose another proxy name."
            case .invalidServer: "Enter the proxy server as an IP address or host name."
            case .invalidPort: "Enter a port from 1 to 65535."
            case .invalidCharacters(let field): "\(field) can't contain line breaks or control characters (256 characters at most)."
            case .passwordWithoutUsername: "Enter the username that goes with the password."
            }
        }
    }

    public var name: String
    public var type: ProxyType
    public var server: String
    public var port: Int
    public var username: String
    public var password: String

    public init(name: String, type: ProxyType, server: String, port: Int, username: String = "", password: String = "") {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.username = username
        self.password = password
    }

    /// Names the profile already uses for its built-in outbounds, groups, and provider member.
    static let reservedNames: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "Proxy", "TS-DIRECT", "TS-NATIVE"]

    /// The settings with surrounding whitespace removed from name and server, after validation.
    public func validated() throws -> ClashProxySettings {
        var settings = self
        settings.name = name.trimmingCharacters(in: .whitespaces)
        settings.server = server.trimmingCharacters(in: .whitespaces)
        let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        guard (1...64).contains(settings.name.count),
              settings.name.unicodeScalars.allSatisfy({ $0.isASCII && nameCharacters.contains($0) }) else {
            throw ValidationError.invalidName
        }
        guard !Self.reservedNames.contains(settings.name) else { throw ValidationError.reservedName(settings.name) }
        guard IPAddressValidator.normalize(settings.server) != nil || Self.isHostName(settings.server) else {
            throw ValidationError.invalidServer
        }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort }
        for (field, value) in [("Username", username), ("Password", password)] {
            guard value.count <= 256, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError.invalidCharacters(field: field)
            }
        }
        if username.isEmpty, !password.isEmpty { throw ValidationError.passwordWithoutUsername }
        return settings
    }

    static func isHostName(_ value: String) -> Bool {
        guard (1...253).contains(value.count) else { return false }
        let labelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { labelCharacters.contains($0) }
        }
    }
}

/// The complete Clash Verge profile the app maintains for design A: one Local profile in Clash Verge with
/// the proxy entered in the dashboard, the `tailscale-live` provider (refreshed every 3 seconds, no
/// reloads), the `Proxy` and `TS-DIRECT` groups, the `+.ts.net` DNS policy, and the routing rules.
/// The settings, DNS, TUN, and rules reproduce the profile verified on 2026-10-18; only the controller
/// `secret:` is left out, because Clash Verge supplies its own.
public enum ClashVergeProfile {
    public static let keychainAccount = "clash-verge-proxy"

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml")
    }

    /// The provider-only part an earlier build kept here; the app removes it.
    public static var legacyPartialFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ExitIPMonitor/verge-profile.yaml")
    }

    public enum WriteOutcome: Equatable, Sendable {
        case unchanged
        case written
    }

    // MARK: Keychain

    public static func encode(_ settings: ClashProxySettings) throws -> String {
        let data = try JSONEncoder().encode(settings)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> ClashProxySettings? {
        try? JSONDecoder().decode(ClashProxySettings.self, from: Data(text.utf8))
    }

    // MARK: Rendering

    /// The full profile. Throws when the settings don't validate.
    public static func render(_ settings: ClashProxySettings) throws -> String {
        let proxy = try settings.validated()
        var proxyLines = [
            "- name: \(quoted(proxy.name))",
            "  type: \(proxy.type.rawValue)",
            "  server: \(quoted(proxy.server))",
            "  port: \(proxy.port)"
        ]
        if !proxy.username.isEmpty {
            proxyLines.append("  username: \(quoted(proxy.username))")
            proxyLines.append("  password: \(quoted(proxy.password))")
        }
        return #"""
        # Clash Verge profile generated by Exit IP Monitor from the proxy entered in its dashboard.
        # Import it in Clash Verge once (Profiles → New → Local); Clash Verge copies it, so import it
        # again after changing the proxy in the dashboard. Tailscale changes need nothing: the
        # tailscale-live provider below is refreshed every 3 seconds. This file holds your proxy
        # credentials: keep it private (mode 0600) and never commit it.
        ---
        mode: rule
        find-process-mode: always
        mixed-port: 7890
        allow-lan: false
        log-level: info
        ipv6: true
        external-controller: ''
        unified-delay: true
        external-controller-unix: "/tmp/verge/verge-mihomo.sock"
        profile:
          store-selected: true
        tun:
          enable: true
          stack: gvisor
          auto-route: true
          strict-route: false
          auto-detect-interface: true
          dns-hijack:
          - any:53
          route-exclude-address:
          - 100.64.0.0/10
          - fd7a:115c:a1e0::/48
        external-controller-cors:
          allow-private-network: true
          allow-origins:
          - tauri://localhost
          - http://tauri.localhost
          - https://yacd.metacubex.one
          - https://metacubex.github.io
          - https://board.zash.run.place
        dns:
          enable: true
          ipv6: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          fake-ip-filter-mode: blacklist
          fake-ip-filter:
          - "*.lan"
          - "+.local"
          - "+.ts.net"
          - "+.tailscale.com"
          nameserver-policy:
            "+.ts.net":
              - "tcp://100.100.100.100:53#TS-DIRECT"
          nameserver:
          - 119.29.29.29
          - 180.76.76.76
          - https://120.53.53.53/dns-query
          - https://223.5.5.5/dns-query
          proxy-server-nameserver:
          - https://120.53.53.53/dns-query
          - https://223.6.6.6/dns-query
        proxies:
        \#(proxyLines.joined(separator: "\n"))
        proxy-providers:
          tailscale-live:
            type: http
            url: "\#(TailscaleVergeProvider.providerURL.absoluteString)"
            path: ./proxy_providers/tailscale-live.yaml
            interval: 3
            proxy: DIRECT
            health-check:
              enable: false
            payload:
              - name: TS-NATIVE
                type: reject
        proxy-groups:
        - name: Proxy
          type: select
          proxies:
          - \#(quoted(proxy.name))
        - name: TS-DIRECT
          type: select
          use:
          - tailscale-live
          empty-fallback: REJECT

        rules:
          - IP-CIDR,100.100.100.100/32,TS-DIRECT,no-resolve
          - IP-CIDR,100.64.0.0/10,TS-DIRECT,no-resolve
          - IP-CIDR6,fd7a:115c:a1e0::/48,TS-DIRECT,no-resolve
          - DOMAIN-SUFFIX,ts.net,TS-DIRECT
          - PROCESS-NAME,Tailscale,DIRECT
          - PROCESS-NAME,tailscaled,DIRECT
          - PROCESS-NAME,io.tailscale.ipn.macsys.network-extension,DIRECT
          - DOMAIN-SUFFIX,tailscale.com,DIRECT
          - DOMAIN-SUFFIX,tailscale.io,DIRECT

          # YouTube + CDN
          - DOMAIN-SUFFIX,youtube.com,DIRECT
          - DOMAIN-SUFFIX,youtu.be,DIRECT
          - DOMAIN-SUFFIX,youtube-nocookie.com,DIRECT
          - DOMAIN-SUFFIX,googlevideo.com,DIRECT
          - DOMAIN-SUFFIX,ytimg.com,DIRECT
          - DOMAIN-SUFFIX,ggpht.com,DIRECT
          - DOMAIN,youtubei.googleapis.com,DIRECT
          # Homebrew (brew install pulls bottles from GitHub's registry)
          - DOMAIN-SUFFIX,brew.sh,DIRECT
          - DOMAIN,ghcr.io,DIRECT
          - DOMAIN-SUFFIX,githubusercontent.com,DIRECT
          - DOMAIN-SUFFIX,github.com,DIRECT
          # Microsoft CDN
          - DOMAIN-SUFFIX,microsoft.com,DIRECT
          - DOMAIN-SUFFIX,msecnd.net,DIRECT
          - DOMAIN-SUFFIX,azureedge.net,DIRECT
          - DOMAIN-SUFFIX,azurefd.net,DIRECT
          - DOMAIN-SUFFIX,msedge.net,DIRECT
          - DOMAIN-SUFFIX,windowsupdate.com,DIRECT
          - DOMAIN-SUFFIX,aka.ms,DIRECT
          # Zoom
          - DOMAIN-SUFFIX,zoom.us,DIRECT
          - DOMAIN-SUFFIX,zoom.com,DIRECT
          - DOMAIN-SUFFIX,zoomgov.com,DIRECT

          - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
          - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
          - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
          - IP-CIDR6,fc00::/7,DIRECT,no-resolve
          - IP-CIDR6,fe80::/10,DIRECT,no-resolve
          - MATCH,Proxy

        """#
    }

    /// A double-quoted YAML scalar; validation already excluded control characters.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: File

    /// Writes `text` to `url` with mode 0600 (it holds credentials), atomically through a temporary file
    /// in the same folder, unless the file already holds exactly that text.
    @discardableResult
    public static func write(_ text: String, to url: URL, fileManager: FileManager = .default) throws -> WriteOutcome {
        if let current = try? String(contentsOf: url, encoding: .utf8), current == text {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .unchanged
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return .written
    }
}
