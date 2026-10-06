import Foundation

/// Removes IP addresses from runtime-log field values. Regexes only find candidates; a match is replaced
/// only when it parses as a real address, so clock times (`12:53:52` in an ISO timestamp, `13:53`) stay
/// readable for log verification.
public enum LogRedactor {
    public static let placeholder = "<redacted-ip>"

    private static let candidates: [NSRegularExpression] = [
        #"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"#,
        #"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redactIPAddresses(in value: String) -> String {
        candidates.reduce(value) { result, expression in
            let text = result as NSString
            let matches = expression.matches(in: result, range: NSRange(location: 0, length: text.length))
            var redacted = result
            for match in matches.reversed() {
                guard IPAddressValidator.normalize(text.substring(with: match.range)) != nil,
                      let range = Range(match.range, in: redacted) else { continue }
                redacted.replaceSubrange(range, with: placeholder)
            }
            return redacted
        }
    }
}
