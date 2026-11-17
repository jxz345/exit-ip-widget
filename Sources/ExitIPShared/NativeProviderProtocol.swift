import Foundation

public enum NativeProviderProtocol {
    public static func routeInterface(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let destinations = lines.filter { $0.first == "destination:" }
        let interfaces = lines.filter { $0.first == "interface:" }
        guard destinations.count == 1, destinations[0].count == 2, interfaces.count == 1, interfaces[0].count == 2,
              !["default", "0", "0.0.0.0", "0.0.0.0/0", "::", "::/0"].contains(destinations[0][1].lowercased()),
              TailscaleVergeStatus.isUtun(interfaces[0][1]) else { return nil }
        return interfaces[0][1]
    }

    public static func tailscaleAddress(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 1 else { return nil }
        let address = String(words[0])
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]),
              octets.allSatisfy({ (0...255).contains($0) }),
              octets.map(String.init).joined(separator: ".") == address else { return nil }
        return address
    }

    public static func ownsAddress(_ text: String, interface: String, address: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard let header = lines.first, header.hasPrefix(interface + ":"),
              let start = header.firstIndex(of: "<"), let end = header[start...].firstIndex(of: ">"),
              header[header.index(after: start)..<end].split(separator: ",").contains("UP") else { return false }
        return lines.dropFirst().contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "inet" && words[1] == address
        }
    }

    public static func yaml(_ served: TailscaleVergeStatus.Served) -> String {
        switch served {
        case .direct(let interface):
            "proxies:\n  - name: TS-NATIVE\n    type: direct\n    interface-name: \(interface)\n    udp: true\n"
        case .reject:
            "proxies:\n  - name: TS-NATIVE\n    type: reject\n"
        }
    }

    public static func freshStatus(_ status: TailscaleVergeStatus?, now: Date = .now) -> TailscaleVergeStatus {
        guard let status, let checked = status.checkedAt else { return .init(served: .reject(reason: "starting"), checkedAt: nil) }
        guard now.timeIntervalSince(checked) <= 12, checked.timeIntervalSince(now) <= 2 else {
            return .init(served: .reject(reason: "monitor-stale"), checkedAt: checked)
        }
        return status
    }

    /// A complete, bounded HTTP header is required; this endpoint has no mutations or file paths.
    public static func response(to data: Data, status: TailscaleVergeStatus?, now: Date = .now) -> Data? {
        guard data.count <= 8192, let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else { return nil }
        let lines = request.components(separatedBy: "\r\n")
        guard lines.count <= 104 else { return nil }
        let words = (lines.first ?? "").split(separator: " ")
        guard words.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(words[2])) else { return nil }
        let method = words[0], path = words[1]
        let current = freshStatus(status, now: now)
        var code = "200 OK", contentType = "text/plain; charset=utf-8", body: String
        if method != "GET" && method != "HEAD" {
            code = "501 Not Implemented"; body = "Unsupported method\n"
        } else if path == "/provider.yaml" { body = yaml(current.served) }
        else if path == "/status.json" {
            let direct: Bool, reason: String, interface: String?
            switch current.served {
            case .direct(let value): direct = true; reason = "verified"; interface = value
            case .reject(let value): direct = false; reason = value; interface = nil
            }
            let object: [String: Any] = ["identity": "tailscale-verge-live-v1", "state": direct ? "direct" : "reject",
                                        "reason": reason, "interface": interface as Any? ?? NSNull(),
                                        "checked_age_seconds": current.checkedAt.map { max(0, Int(now.timeIntervalSince($0))) } as Any? ?? NSNull()]
            body = String(data: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(), encoding: .utf8)! + "\n"
            contentType = "application/json"
        } else { code = "404 Not Found"; body = "Not found\n" }
        let header = "HTTP/1.1 \(code)\r\nServer: tailscale-verge-live-v1\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        return Data((header + (method == "HEAD" ? "" : body)).utf8)
    }
}
