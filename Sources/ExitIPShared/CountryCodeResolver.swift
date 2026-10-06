import Foundation

/// Maps an English country name to its ISO 3166-1 alpha-2 code for providers that return only a name
/// (for example the anonymous ipapi.is tier). An unknown name returns `nil` so the lookup can fail
/// instead of storing a placeholder code that cannot be compared or confirmed.
public enum CountryCodeResolver {
    public static func isValidCode(_ code: String) -> Bool {
        code.count == 2 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    public static func code(forCountryName name: String) -> String? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        if let alias = aliases[key] {
            return alias
        }
        return codesByName[key]
    }

    public static func resolvedCode(code providedCode: String, countryName: String) -> String? {
        let normalizedCode = providedCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if isValidCode(normalizedCode) {
            return normalizedCode
        }
        return code(forCountryName: countryName)
    }

    private static let codesByName: [String: String] = {
        let english = Locale(identifier: "en_US")
        var result: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard isValidCode(code), let name = english.localizedString(forRegionCode: code) else { continue }
            result[normalized(name)] = code
        }
        return result
    }()

    /// Common provider spellings that differ from Foundation's English region names.
    private static let aliases: [String: String] = [
        "united states of america": "US",
        "usa": "US",
        "uk": "GB",
        "great britain": "GB",
        "netherlands": "NL",
        "russian federation": "RU",
        "korea": "KR",
        "republic of korea": "KR",
        "korea, republic of": "KR",
        "korea, democratic people's republic of": "KP",
        "turkey": "TR",
        "czech republic": "CZ",
        "macau": "MO",
        "hong kong sar": "HK",
        "hong kong sar china": "HK",
        "taiwan, province of china": "TW",
        "viet nam": "VN",
        "iran, islamic republic of": "IR",
        "syrian arab republic": "SY",
        "lao people's democratic republic": "LA",
        "bolivia, plurinational state of": "BO",
        "venezuela, bolivarian republic of": "VE",
        "tanzania, united republic of": "TZ",
        "moldova, republic of": "MD",
        "palestine": "PS",
        "palestine, state of": "PS",
        "myanmar": "MM",
        "ivory coast": "CI",
        "democratic republic of the congo": "CD",
        "congo, democratic republic of the": "CD",
        "republic of the congo": "CG",
        "congo": "CG",
        "macedonia": "MK",
        "swaziland": "SZ",
        "cabo verde": "CV",
        "east timor": "TL",
        "holy see": "VA",
        "brunei darussalam": "BN"
    ]

    private static func normalized(_ name: String) -> String {
        var value = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("the ") {
            value.removeFirst(4)
        }
        return value
    }
}
