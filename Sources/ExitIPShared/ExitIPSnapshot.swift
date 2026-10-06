import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case ipinfoLite
    case ipapiCo
    case ipWhois
    case ipapiIs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ipinfoLite: "IPinfo Lite"
        case .ipapiCo: "ipapi.co"
        case .ipWhois: "IPWHOIS.io"
        case .ipapiIs: "ipapi.is"
        }
    }
}

public enum MenuBarDisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case name
    case flag
    case flagAndName
    case code

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: "Country name"
        case .flag: "Color flag"
        case .flagAndName: "Flag and country name"
        case .code: "Country code"
        }
    }
}

public struct CountryChange: Codable, Equatable, Sendable {
    public let previousCode: String
    public let previousName: String
    public let changedAt: Date
    public let highlightUntil: Date

    public init(previousCode: String, previousName: String, changedAt: Date, highlightUntil: Date) {
        self.previousCode = previousCode
        self.previousName = previousName
        self.changedAt = changedAt
        self.highlightUntil = highlightUntil
    }

    public func isHighlighted(at date: Date = .now) -> Bool {
        date < highlightUntil
    }
}

public struct ExitIPSnapshot: Codable, Equatable, Sendable {
    public var ipAddress: String
    public var countryCode: String
    public var countryName: String
    public var city: String?
    public var region: String?
    public var timezone: String?
    public var autonomousSystem: String?
    public var organization: String?
    public var provider: ProviderID
    public var checkedAt: Date
    public var countryChange: CountryChange?

    public init(
        ipAddress: String,
        countryCode: String,
        countryName: String,
        city: String? = nil,
        region: String? = nil,
        timezone: String? = nil,
        autonomousSystem: String? = nil,
        organization: String? = nil,
        provider: ProviderID,
        checkedAt: Date = .now,
        countryChange: CountryChange? = nil
    ) {
        self.ipAddress = ipAddress
        self.countryCode = countryCode.uppercased()
        self.countryName = countryName
        self.city = city
        self.region = region
        self.timezone = timezone
        self.autonomousSystem = autonomousSystem
        self.organization = organization
        self.provider = provider
        self.checkedAt = checkedAt
        self.countryChange = countryChange
    }

    /// City, region, and country from a single provider response, without repeated place names.
    /// City-states are reported as e.g. city "Singapore", region "Central Singapore", country "Singapore",
    /// so the city is dropped when it matches the country and any later duplicate is skipped.
    public var locationSummary: String {
        func key(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        let countryKey = key(countryName)
        var seen: Set<String> = []
        var parts: [String] = []
        for (index, value) in [city, region, countryName].enumerated() {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueKey = key(trimmed)
            guard !valueKey.isEmpty else { continue }
            if index == 0, valueKey == countryKey { continue }
            guard seen.insert(valueKey).inserted else { continue }
            parts.append(trimmed)
        }
        return parts.joined(separator: ", ")
    }

    /// True only for a two-letter ISO 3166-1 alpha-2 code. Placeholders such as `--` are not comparable countries.
    public var hasValidCountryCode: Bool {
        CountryCodeResolver.isValidCode(countryCode)
    }

    public var countryFlag: String {
        guard hasValidCountryCode else { return "🌐" }

        let regionalIndicatorBase: UInt32 = 127_397
        let values = countryCode.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            UnicodeScalar(regionalIndicatorBase + scalar.value)
        }
        return values.count == 2 ? String(String.UnicodeScalarView(values)) : "🌐"
    }

    public func menuBarLabel(style: MenuBarDisplayStyle) -> String {
        switch style {
        case .name:
            countryName
        case .flag:
            countryFlag
        case .flagAndName:
            "\(countryFlag) \(countryName)"
        case .code:
            hasValidCountryCode ? countryCode : "--"
        }
    }

    public func isStale(at date: Date = .now, threshold: TimeInterval) -> Bool {
        date.timeIntervalSince(checkedAt) >= threshold
    }

    public func isCountryChangeHighlighted(at date: Date = .now) -> Bool {
        countryChange?.isHighlighted(at: date) ?? false
    }

    /// WidgetKit reloads only when its rendered content changes. The system can update relative-date text
    /// from the hourly timeline without spending an on-demand reload for every successful background check.
    public func hasWidgetContentChange(comparedTo previous: ExitIPSnapshot?) -> Bool {
        guard let previous else { return true }
        return ipAddress != previous.ipAddress ||
            countryCode != previous.countryCode ||
            countryName != previous.countryName ||
            city != previous.city ||
            region != previous.region ||
            timezone != previous.timezone ||
            autonomousSystem != previous.autonomousSystem ||
            organization != previous.organization ||
            countryChange != previous.countryChange
    }
}

public enum CountryChangeDetector {
    public static func applyingCountryChange(
        to current: ExitIPSnapshot,
        previous: ExitIPSnapshot?,
        at date: Date = .now,
        highlightDuration: TimeInterval = RefreshPolicy.defaultHighlightDuration
    ) -> ExitIPSnapshot {
        // A placeholder code on either side cannot be confirmed, so it never creates a highlight.
        guard let previous,
              previous.hasValidCountryCode,
              current.hasValidCountryCode,
              previous.countryCode != current.countryCode else {
            var unchanged = current
            if let activeChange = previous?.countryChange,
               activeChange.isHighlighted(at: date),
               activeChange.previousCode != current.countryCode,
               activeChange.previousName.caseInsensitiveCompare(current.countryName) != .orderedSame {
                unchanged.countryChange = activeChange
            } else {
                unchanged.countryChange = nil
            }
            return unchanged
        }

        var changed = current
        changed.countryChange = CountryChange(
            previousCode: previous.countryCode,
            previousName: previous.countryName,
            changedAt: date,
            highlightUntil: date.addingTimeInterval(highlightDuration)
        )
        return changed
    }
}

public enum RefreshPolicy {
    /// A visible 10-minute marker is long enough to be noticed, but does not leave a stale warning behind.
    public static let defaultHighlightDuration: TimeInterval = 10 * 60
    /// After an event-driven lookup starts immediately, further events in this window are merged into
    /// one trailing lookup at its end, so the settled network state is checked without a burst.
    public static let eventWindow: TimeInterval = 5
    /// Trailing lookups chained within this long after an event window's leading lookup still count as
    /// network changes (never burst-deferred); a storm that continues past it is throttled by the burst
    /// allowance.
    public static let eventStormGrace: TimeInterval = 30
    public static let maximumBackoff: TimeInterval = 15 * 60
    /// Normal WidgetKit timeline refreshes are capped at once per hour; material state changes still reload immediately.
    public static let widgetTimelineRefresh: TimeInterval = 60 * 60
    /// A conservative pause for a 429 response that omits the standard Retry-After header.
    public static let fallbackRateLimitCooldown: TimeInterval = 60 * 60
    /// A short minimum interval between lookup attempts to the *same* provider. A request inside it goes
    /// to the next provider in the pool instead. Provider cooldowns still apply independently.
    public static let minimumRefreshSpacing: TimeInterval = 5

    public static func retryDelay(forConsecutiveFailure count: Int) -> TimeInterval {
        let attempt = max(count - 1, 0)
        return min(60 * pow(2, Double(attempt)), maximumBackoff)
    }

    public enum ProviderSelection: Equatable, Sendable {
        case use(ProviderID)
        /// Every eligible provider was called within `minimumRefreshSpacing`; the earliest becomes free then.
        case waitUntil(Date)
        /// Nothing in the pool is eligible (all excluded).
        case unavailable
    }

    /// Picks the provider for the next lookup: `preferred` if it is free, otherwise the next pool entry
    /// (in rotation order) that is not excluded and was not called within `minimumRefreshSpacing`.
    public static func providerSelection(
        pool: [ProviderID],
        preferred: ProviderID,
        lastAttempts: [ProviderID: Date],
        excluded: Set<ProviderID> = [],
        at date: Date = .now
    ) -> ProviderSelection {
        let start = pool.firstIndex(of: preferred) ?? 0
        let ordered = pool.isEmpty ? [preferred] : (0..<pool.count).map { pool[(start + $0) % pool.count] }
        var earliest: Date?
        for candidate in ordered where !excluded.contains(candidate) {
            guard let last = lastAttempts[candidate] else { return .use(candidate) }
            let nextAllowed = last.addingTimeInterval(minimumRefreshSpacing)
            if nextAllowed <= date { return .use(candidate) }
            earliest = min(earliest ?? nextAllowed, nextAllowed)
        }
        return earliest.map { .waitUntil($0) } ?? .unavailable
    }
}
