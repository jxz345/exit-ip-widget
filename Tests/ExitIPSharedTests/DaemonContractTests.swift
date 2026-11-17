import Foundation
import XCTest
@testable import ExitIPShared

final class DaemonContractTests: XCTestCase {
    func testAtomicStoragePersistsBudgetAndCooldownAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.plist")
        let store = try FilePreferenceStorage(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        budget.recordCall(to: .ipWhois)
        LookupBudgetStore(defaults: store).save(budget)
        ProviderCooldownStore(defaults: store).save(retryNotBefore: now.addingTimeInterval(300), for: .ipWhois)
        let restored = try FilePreferenceStorage(url: url)
        XCTAssertEqual(LookupBudgetStore(defaults: restored).load(now: now).callsToday(for: .ipWhois), 1)
        XCTAssertEqual(ProviderCooldownStore(defaults: restored).retryNotBefore(for: .ipWhois), now.addingTimeInterval(300))
        XCTAssertNil(restored.lastError)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testCorruptMachineStateDoesNotResetBudgetsSilently() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a property list".utf8).write(to: url)
        XCTAssertThrowsError(try FilePreferenceStorage(url: url))
    }

    func testFailedTransactionDoesNotPublishPartialSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.plist")
        let store = try FilePreferenceStorage(url: url)
        try store.update(["revision": 1, "provider": "old"])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.update(["revision": 2, "provider": "new"]))
        XCTAssertEqual(store.integer(forKey: "revision"), 1)
        XCTAssertEqual(store.string(forKey: "provider"), "old")
        XCTAssertNotNil(store.lastError)
    }

    func testSettingsRejectEmptyDuplicateAndInconsistentProviderPools() throws {
        var settings = MachineSettings()
        settings.providerPool = []
        XCTAssertThrowsError(try settings.validated())
        settings.providerPool = [.ipapiCo, .ipapiCo]
        XCTAssertThrowsError(try settings.validated())
        settings.providerPool = [.ipWhois]
        XCTAssertThrowsError(try settings.validated())
        settings.provider = .ipWhois
        XCTAssertNoThrow(try settings.validated())
    }

    func testRequestRoundTripDoesNotProvideCallerIdentity() throws {
        var request = DaemonRequest(.configure)
        request.expectedRevision = 5
        request.settings = MachineSettings()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: data)
        XCTAssertEqual(decoded.expectedRevision, 5)
        XCTAssertEqual(decoded.settings, request.settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["uid"])
        XCTAssertNil(object["user"])
    }

    func testNativeRouteRequiresSpecificSingleUtun() {
        XCTAssertEqual(NativeProviderProtocol.routeInterface("destination: 100.100.100.100\ninterface: utun7"), "utun7")
        for text in ["destination: default\ninterface: utun7", "destination: 100.100.100.100\ninterface: en0",
                     "destination: 100.100.100.100\ninterface: utun7\ninterface: utun8"] {
            XCTAssertNil(NativeProviderProtocol.routeInterface(text))
        }
    }

    func testNativeAddressMustBeOneCanonicalCGNATAddress() {
        XCTAssertEqual(NativeProviderProtocol.tailscaleAddress("100.64.0.1\n"), "100.64.0.1")
        for text in ["100.63.0.1", "100.128.0.1", "100.064.0.1", "100.64.0.256", "100.64.0.1\n100.64.0.2", "::1"] {
            XCTAssertNil(NativeProviderProtocol.tailscaleAddress(text))
        }
    }

    func testNativeInterfaceMustBeUpAndOwnAddress() {
        XCTAssertTrue(NativeProviderProtocol.ownsAddress("utun7: flags=1<UP,POINTOPOINT>\n inet 100.64.0.1", interface: "utun7", address: "100.64.0.1"))
        XCTAssertFalse(NativeProviderProtocol.ownsAddress("utun7: flags=1<POINTOPOINT>\n inet 100.64.0.1", interface: "utun7", address: "100.64.0.1"))
        XCTAssertFalse(NativeProviderProtocol.ownsAddress("utun8: flags=1<UP>\n inet 100.64.0.1", interface: "utun7", address: "100.64.0.1"))
    }

    func testHTTPPreservesProviderBytesAndRejectsStaleState() throws {
        let now = Date()
        let status = TailscaleVergeStatus(served: .direct(interface: "utun7"), checkedAt: now)
        let request = Data("GET /provider.yaml HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let response = try XCTUnwrap(NativeProviderProtocol.response(to: request, status: status, now: now))
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix("proxies:\n  - name: TS-NATIVE\n    type: direct\n    interface-name: utun7\n    udp: true\n"))
        let stale = try XCTUnwrap(NativeProviderProtocol.response(to: request, status: status, now: now.addingTimeInterval(13)))
        XCTAssertTrue(String(decoding: stale, as: UTF8.self).hasSuffix("proxies:\n  - name: TS-NATIVE\n    type: reject\n"))
    }

    func testHTTPHeadUnknownRoutesUnsupportedMethodsAndIncompleteRequests() throws {
        for (method, path, status) in [("HEAD", "/provider.yaml", "200"), ("GET", "/unknown", "404"), ("POST", "/provider.yaml", "501")] {
            let request = Data("\(method) \(path) HTTP/1.1\r\n\r\n".utf8)
            let response = String(decoding: try XCTUnwrap(NativeProviderProtocol.response(to: request, status: nil)), as: UTF8.self)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 \(status)"))
            if method == "HEAD" { XCTAssertTrue(response.hasSuffix("\r\n\r\n")) }
        }
        XCTAssertNil(NativeProviderProtocol.response(to: Data("GET /provider.yaml HTTP/1.1\r\n".utf8), status: nil))
        XCTAssertNil(NativeProviderProtocol.response(to: Data(repeating: 65, count: 8193), status: nil))
    }
}
