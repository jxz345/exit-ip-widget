import XCTest
@testable import ExitIPShared

/// The full Clash Verge profile the app maintains. Only RFC 5737 addresses and dummy credentials appear
/// here; real proxy details live in the Keychain and the generated 0600 file, never in the repository.
final class ClashVergeProfileTests: XCTestCase {
    private let sample = ClashProxySettings(name: "MP-SG", type: .socks5, server: "192.0.2.10", port: 1080,
                                            username: "user", password: "pa\"ss\\#: x")

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    func testRenderHasEverySectionInProfileOrder() throws {
        let text = try ClashVergeProfile.render(sample)
        let topLevel = lines(text).filter { $0.first.map { $0.isLetter } ?? false }.map { String($0.prefix { $0 != ":" }) }
        XCTAssertEqual(topLevel, ["mode", "find-process-mode", "mixed-port", "allow-lan", "log-level", "ipv6",
                                  "external-controller", "unified-delay", "external-controller-unix", "profile", "tun",
                                  "external-controller-cors", "dns", "proxies", "proxy-providers", "proxy-groups", "rules"])
        XCTAssertFalse(text.contains("\nsecret:"), "Clash Verge supplies its own controller secret")
        XCTAssertTrue(text.contains("\n---\nmode: rule\n"))
    }

    func testRenderWritesTheProxyQuotedAndEscaped() throws {
        let text = try ClashVergeProfile.render(sample)
        XCTAssertTrue(text.contains("""
        proxies:
        - name: "MP-SG"
          type: socks5
          server: "192.0.2.10"
          port: 1080
          username: "user"
          password: "pa\\"ss\\\\#: x"
        proxy-providers:
        """))
        XCTAssertTrue(text.contains("""
        proxy-groups:
        - name: Proxy
          type: select
          proxies:
          - "MP-SG"
        - name: TS-DIRECT
          type: select
          use:
          - tailscale-live
          empty-fallback: REJECT
        """))
    }

    func testRenderKeepsTheProviderSectionDNSPolicyAndRules() throws {
        let text = try ClashVergeProfile.render(sample)
        XCTAssertTrue(text.contains("""
        proxy-providers:
          tailscale-live:
            type: http
            url: "\(TailscaleVergeProvider.providerURL.absoluteString)"
            path: ./proxy_providers/tailscale-live.yaml
            interval: 3
            proxy: DIRECT
            health-check:
              enable: false
            payload:
              - name: TS-NATIVE
                type: reject
        """))
        XCTAssertTrue(text.contains("""
          nameserver-policy:
            "+.ts.net":
              - "tcp://100.100.100.100:53#TS-DIRECT"
        """))
        let rules = lines(text).filter { $0.hasPrefix("  - ") && ($0.contains(",DIRECT") || $0.contains(",TS-DIRECT") || $0.contains("MATCH")) }
        XCTAssertEqual(rules.count, 38)
        XCTAssertEqual(rules.last, "  - MATCH,Proxy")
        XCTAssertTrue(text.contains("  route-exclude-address:\n  - 100.64.0.0/10\n  - fd7a:115c:a1e0::/48\n"))
    }

    func testHTTPProxyWithoutAuthOmitsCredentials() throws {
        let settings = ClashProxySettings(name: "Office", type: .http, server: "proxy.example.com", port: 8080)
        let text = try ClashVergeProfile.render(settings)
        XCTAssertTrue(text.contains("- name: \"Office\"\n  type: http\n  server: \"proxy.example.com\"\n  port: 8080\nproxy-providers:"))
        XCTAssertFalse(text.contains("username:"))
        XCTAssertFalse(text.contains("password:"))
    }

    func testValidationRejectsBadInput() {
        func error(_ change: (inout ClashProxySettings) -> Void) -> ClashProxySettings.ValidationError? {
            var settings = sample
            change(&settings)
            do { _ = try settings.validated(); return nil } catch { return error as? ClashProxySettings.ValidationError }
        }
        XCTAssertNil(error { _ in })
        XCTAssertEqual(error { $0.server = "" }, .invalidServer)
        XCTAssertEqual(error { $0.server = "bad host" }, .invalidServer)
        XCTAssertEqual(error { $0.server = "-bad.example.com" }, .invalidServer)
        XCTAssertNil(error { $0.server = "2001:db8::1" })
        XCTAssertNil(error { $0.server = "proxy.example.com" })
        XCTAssertEqual(error { $0.port = 0 }, .invalidPort)
        XCTAssertEqual(error { $0.port = 70000 }, .invalidPort)
        XCTAssertEqual(error { $0.name = "" }, .invalidName)
        XCTAssertEqual(error { $0.name = "a\nb" }, .invalidName)
        XCTAssertEqual(error { $0.name = "Proxy" }, .reservedName("Proxy"))
        XCTAssertEqual(error { $0.name = "TS-DIRECT" }, .reservedName("TS-DIRECT"))
        XCTAssertEqual(error { $0.password = "a\nb" }, .invalidCharacters(field: "Password"))
        XCTAssertEqual(error { $0.username = "a\tb" }, .invalidCharacters(field: "Username"))
        XCTAssertEqual(error { $0.username = "" }, .passwordWithoutUsername)
        XCTAssertThrowsError(try ClashVergeProfile.render(ClashProxySettings(name: "X", type: .socks5, server: "", port: 1)))
    }

    func testValidationTrimsNameAndServer() throws {
        var settings = sample
        settings.name = "  MP-SG "
        settings.server = " 192.0.2.10 "
        XCTAssertEqual(try settings.validated().server, "192.0.2.10")
        XCTAssertTrue(try ClashVergeProfile.render(settings).contains("- name: \"MP-SG\"\n"))
    }

    func testSettingsRoundTripThroughTheKeychainEncoding() throws {
        XCTAssertEqual(ClashVergeProfile.decode(try ClashVergeProfile.encode(sample)), sample)
        XCTAssertNil(ClashVergeProfile.decode("not json"))
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clash-profile-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("nested/clash-verge-profile.yaml")
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testWriteCreatesAPrivateFileAndRewritesOnlyOnChange() throws {
        let url = temporaryFile()
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .written)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a: 1\n")
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .unchanged)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode)
        XCTAssertEqual(try ClashVergeProfile.write("a: 2\n", to: url), .written)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a: 2\n")
        XCTAssertEqual(try mode(url), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["clash-verge-profile.yaml"])
    }

    func testWriteTightensALooseFileThatAlreadyMatches() throws {
        let url = temporaryFile()
        try ClashVergeProfile.write("a: 1\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .unchanged)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testFileLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClashVergeProfile.fileURL.path, home + "/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml")
        XCTAssertEqual(ClashVergeProfile.legacyPartialFileURL.path, home + "/Library/Application Support/ExitIPMonitor/verge-profile.yaml")
    }
}
