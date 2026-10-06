import Foundation

/// How much a refresh request is worth spending API quota on.
public enum RefreshUrgency: Int, Comparable, Sendable {
    /// Periodic timer and app/screen/session activation: a safety net, skipped when the result is fresh.
    case routine = 0
    /// Trailing lookups once a continuous event storm outlasts `RefreshPolicy.eventStormGrace`, and scheduled retries: worth checking, but
    /// only within the burst allowance—deferred (never dropped) when it is used up.
    case followUp = 1
    /// Startup, network/route/proxy/VPN changes, system wake, and trailing settle checks: the
    /// exit IP may really have changed, so the lookup runs at once and never waits for the burst allowance.
    case networkChange = 2
    /// The person pressed Refresh now or changed provider settings.
    case manual = 3

    public static func < (lhs: RefreshUrgency, rhs: RefreshUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Stable name for the runtime log.
    public var logName: String {
        switch self {
        case .routine: "routine"
        case .followUp: "follow_up"
        case .networkChange: "network_change"
        case .manual: "manual"
        }
    }
}

/// Leading-plus-trailing throttle for event-driven refreshes. The first event after a quiet period is
/// checked immediately and opens a `RefreshPolicy.eventWindow`. Network-urgency events inside the window
/// are merged into one trailing lookup at its end, so a change that is still settling (a VPN finishing
/// its routes, a proxy applied after the interface) is checked once more. Routine events inside the window
/// are absorbed: the leading lookup already answers them.
///
/// Trailing lookups within `RefreshPolicy.eventStormGrace` of the leading lookup carry `.networkChange`
/// urgency: they check a real change that is still settling, or further changes made a few seconds apart.
/// Only once a continuous storm outlasts that grace do chained trailing lookups become `.followUp`, so the
/// burst allowance bounds a flapping network.
public struct EventRefreshWindow: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case runNow(windowEndsAt: Date)
        case mergedIntoTrailing(windowEndsAt: Date)
        case absorbed
    }

    public struct Trailing: Equatable, Sendable {
        /// End of the window the trailing lookup opens.
        public var windowEndsAt: Date
        public var urgency: RefreshUrgency
    }

    public private(set) var windowEndsAt: Date?
    public private(set) var trailingPending = false
    /// When the current chain of windows started with a leading lookup; `nil` once the window closes.
    public private(set) var leadingAt: Date?

    public init() {}

    public mutating func register(_ urgency: RefreshUrgency, now: Date = .now) -> Decision {
        guard let windowEndsAt, now < windowEndsAt else {
            let end = now.addingTimeInterval(RefreshPolicy.eventWindow)
            self.windowEndsAt = end
            trailingPending = false
            leadingAt = now
            return .runNow(windowEndsAt: end)
        }
        guard urgency >= .networkChange else { return .absorbed }
        trailingPending = true
        return .mergedIntoTrailing(windowEndsAt: windowEndsAt)
    }

    /// Called at the window end. Returns the trailing lookup when one is owed (it opens its own window,
    /// so a continuing storm settles to one lookup per window), or `nil` when the window closes quietly.
    public mutating func takeTrailing(now: Date = .now) -> Trailing? {
        guard trailingPending else {
            windowEndsAt = nil
            leadingAt = nil
            return nil
        }
        trailingPending = false
        let end = now.addingTimeInterval(RefreshPolicy.eventWindow)
        windowEndsAt = end
        let stormAge = now.timeIntervalSince(leadingAt ?? now)
        let urgency: RefreshUrgency = stormAge <= RefreshPolicy.eventStormGrace ? .networkChange : .followUp
        return Trailing(windowEndsAt: end, urgency: urgency)
    }

    public mutating func reset() {
        windowEndsAt = nil
        trailingPending = false
        leadingAt = nil
    }
}

/// Balances prompt checks against provider quotas with two persisted layers that sit on top of the
/// hard per-provider 5-second minimum interval (`RefreshPolicy.minimumRefreshSpacing`), the event window
/// (`EventRefreshWindow`), and per-provider `429` cooldowns:
///
/// 1. A **global token bucket**: `burstCapacity` lookups can run back-to-back, refilling one token every
///    `tokenRefillInterval`. Every lookup spends a token, but only follow-ups (chained trailing lookups,
///    retries) wait for one and routine checks are dropped without one. A real network change or a manual
///    refresh is never delayed by the bucket.
/// 2. A **per-provider daily budget** at `dailyBudgetFraction` of each provider's documented free
///    limit, reset at UTC midnight. An exhausted provider is skipped by normal pool rotation (never as a
///    reaction to a `429`); when every enabled provider is exhausted, lookups pause until the reset.
public struct LookupBudget: Codable, Equatable, Sendable {
    public static let burstCapacity: Double = 6
    public static let tokenRefillInterval: TimeInterval = 120
    /// Routine triggers are skipped while the last successful result is younger than this.
    public static let routineFreshness: TimeInterval = 120
    public static let dailyBudgetFraction = 0.8
    static let tokenTolerance = 1e-6

    public struct DailyUsage: Codable, Equatable, Sendable {
        public var day: Date
        public var count: Int
    }

    public enum Admission: Equatable, Sendable {
        case proceed
        /// Not worth a lookup now (routine trigger with a fresh result, or no tokens left).
        case skip(reason: String)
        /// Over the burst allowance; run one lookup at this time instead.
        case deferUntil(Date)
    }

    public private(set) var tokens: Double
    public private(set) var updatedAt: Date
    public private(set) var usage: [String: DailyUsage]

    public init(now: Date = .now) {
        tokens = Self.burstCapacity
        updatedAt = now
        usage = [:]
    }

    // MARK: Global token bucket

    /// Decides whether a request of the given urgency may spend a lookup now, consuming a token if so.
    /// Manual and network-change requests are never refused or delayed here (the per-provider gap,
    /// cooldowns, and daily budgets still apply), but they do drain the bucket so they count against
    /// later follow-ups and routine checks.
    public mutating func admit(_ urgency: RefreshUrgency, lastSuccess: Date?, now: Date = .now) -> Admission {
        refill(at: now)
        if urgency == .routine, let lastSuccess, now.timeIntervalSince(lastSuccess) < Self.routineFreshness {
            return .skip(reason: "fresh")
        }
        // Tolerate floating-point refill error: a deferral computed as `(1 - tokens) * interval` must
        // find a whole token when it fires, or it would re-queue for the same instant.
        if tokens >= 1 - Self.tokenTolerance || urgency >= .networkChange {
            tokens = max(0, tokens - 1)
            return .proceed
        }
        if urgency == .routine {
            return .skip(reason: "burst_budget")
        }
        return .deferUntil(now.addingTimeInterval((1 - tokens) * Self.tokenRefillInterval))
    }

    private mutating func refill(at now: Date) {
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        tokens = min(Self.burstCapacity, tokens + elapsed / Self.tokenRefillInterval)
        updatedAt = now
    }

    // MARK: Per-provider daily budget

    /// Documented free-tier daily request limits; `nil` means no published cap.
    public static func documentedDailyLimit(for provider: ProviderID) -> Int? {
        switch provider {
        case .ipinfoLite: nil
        case .ipapiCo: 1_000
        case .ipWhois: 1_000
        case .ipapiIs: 100
        }
    }

    public static func dailyBudget(for provider: ProviderID) -> Int? {
        documentedDailyLimit(for: provider).map { Int(Double($0) * dailyBudgetFraction) }
    }

    public func callsToday(for provider: ProviderID, now: Date = .now) -> Int {
        guard let entry = usage[provider.rawValue], entry.day == Self.dayStart(for: now) else { return 0 }
        return entry.count
    }

    public func isExhausted(_ provider: ProviderID, now: Date = .now) -> Bool {
        guard let budget = Self.dailyBudget(for: provider) else { return false }
        return callsToday(for: provider, now: now) >= budget
    }

    /// Records one request (primary or confirmation) against the provider's daily budget.
    public mutating func recordCall(to provider: ProviderID, now: Date = .now) {
        let day = Self.dayStart(for: now)
        usage[provider.rawValue] = DailyUsage(day: day, count: callsToday(for: provider, now: now) + 1)
    }

    /// When an exhausted daily budget becomes available again (next UTC midnight).
    public static func budgetResetDate(after now: Date = .now) -> Date {
        utcCalendar.date(byAdding: .day, value: 1, to: dayStart(for: now)) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    static func dayStart(for date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// The single admission decision for a lookup request, shared by the app and the tests. It layers the
/// self-imposed limits in order: per-provider daily budget and the per-provider 5-second gap (one rotation
/// decision), then the burst allowance. A provider that refused requests (a cooldown in `cooldowns`) is
/// skipped by rotation exactly like an exhausted one; lookups pause only when no enabled provider is usable.
public enum RefreshGate {
    public enum Decision: Equatable, Sendable {
        /// Run now on `provider`; `rotatedFrom` is set when the preferred provider was skipped. A burst
        /// token was spent and the call recorded against the provider's daily budget.
        case run(provider: ProviderID, rotatedFrom: ProviderID?)
        /// Run one lookup at `until`. `reason` is `provider_gap` or `burst_budget`.
        case queue(until: Date, reason: String)
        /// Not worth a lookup (`fresh` or `burst_budget`; routine triggers only).
        case skip(reason: String)
        /// Every eligible provider used its daily budget; lookups pause until the UTC reset.
        case dailyBudgetExhausted(resetAt: Date)
        /// Every eligible provider is paused by a refusal cooldown (or exhausted); lookups resume at
        /// `until`, the earliest moment any of them becomes usable again.
        case allProvidersPaused(until: Date)
    }

    /// - Parameter bypassLimits: startup's one-time exception to the gap and the burst allowance.
    public static func decide(
        urgency: RefreshUrgency,
        pool: [ProviderID],
        preferred: ProviderID,
        lastAttempts: [ProviderID: Date],
        excluded: Set<ProviderID> = [],
        cooldowns: [ProviderID: Date] = [:],
        budget: inout LookupBudget,
        lastSuccess: Date?,
        bypassLimits: Bool = false,
        now: Date = .now
    ) -> Decision {
        let candidates = pool.isEmpty ? [preferred] : pool
        let exhausted = Set(candidates.filter { budget.isExhausted($0, now: now) })
        let paused = cooldowns.filter { candidates.contains($0.key) && $0.value > now }
        let selection = RefreshPolicy.providerSelection(
            pool: pool,
            preferred: preferred,
            lastAttempts: bypassLimits ? [:] : lastAttempts,
            excluded: excluded.union(exhausted).union(paused.keys),
            at: now
        )
        let provider: ProviderID
        switch selection {
        case .use(let selected):
            provider = selected
        case .waitUntil(let nextAllowed):
            if urgency == .routine, let lastSuccess,
               now.timeIntervalSince(lastSuccess) < LookupBudget.routineFreshness {
                return .skip(reason: "fresh")
            }
            return .queue(until: nextAllowed, reason: "provider_gap")
        case .unavailable:
            let resetAt = LookupBudget.budgetResetDate(after: now)
            guard let earliestResume = paused.values.min() else {
                return .dailyBudgetExhausted(resetAt: resetAt)
            }
            // An exhausted provider becomes usable at the UTC reset, a paused one at its deadline.
            return .allProvidersPaused(until: exhausted.isEmpty ? earliestResume : min(earliestResume, resetAt))
        }

        if !bypassLimits {
            switch budget.admit(urgency, lastSuccess: lastSuccess, now: now) {
            case .proceed:
                break
            case .skip(let reason):
                return .skip(reason: reason)
            case .deferUntil(let date):
                return .queue(until: date, reason: "burst_budget")
            }
        }
        budget.recordCall(to: provider, now: now)
        return .run(provider: provider, rotatedFrom: provider == preferred ? nil : preferred)
    }
}

/// The single pending queued lookup. Requests that cannot run yet fold into it: it keeps the earliest
/// boundary (a later request never postpones an earlier one) and the highest urgency. Any lookup that
/// starts answers every earlier request, so it supersedes the pending one.
public struct PendingRefresh: Equatable, Sendable {
    public private(set) var notBefore: Date?
    public private(set) var urgency: RefreshUrgency?

    public init() {}

    public var isPending: Bool { notBefore != nil }

    /// Folds a request in. Returns `true` when the boundary changed and the timer must be rescheduled.
    public mutating func enqueue(at date: Date, urgency: RefreshUrgency) -> Bool {
        self.urgency = max(self.urgency ?? urgency, urgency)
        if let notBefore, notBefore <= date { return false }
        notBefore = date
        return true
    }

    /// Called when the queued lookup fires; returns the urgency it stands in for.
    public mutating func take() -> RefreshUrgency? {
        defer { self = PendingRefresh() }
        return urgency
    }

    /// Called when another lookup starts; returns the boundary that no longer needs to run.
    public mutating func supersede() -> Date? {
        defer { self = PendingRefresh() }
        return notBefore
    }
}

/// Persists `LookupBudget` in the App Group so relaunches cannot reset the burst allowance or daily counts.
public final class LookupBudgetStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = ExitIPAppGroup.defaults) {
        self.defaults = defaults
    }

    public func load(now: Date = .now) -> LookupBudget {
        guard let data = defaults.data(forKey: ExitIPPreferenceKey.lookupBudget),
              let budget = try? JSONDecoder().decode(LookupBudget.self, from: data) else {
            return LookupBudget(now: now)
        }
        return budget
    }

    public func save(_ budget: LookupBudget) {
        guard let data = try? JSONEncoder().encode(budget) else { return }
        defaults.set(data, forKey: ExitIPPreferenceKey.lookupBudget)
    }
}
