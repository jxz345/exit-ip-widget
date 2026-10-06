import Foundation
@testable import ExitIPShared

/// A virtual-clock model of `PublicIPMonitor`'s refresh plumbing. It drives the real shared policy
/// (`EventRefreshWindow`, `RefreshGate`, `LookupBudget`, `PendingRefresh`) the same way the app does:
/// event triggers go through the window, every request goes through the gate, requests that arrive during
/// a lookup become one recheck, and a started lookup supersedes a pending queued one. Lookups always
/// succeed after `lookupDuration` and advance the provider rotation.
struct RefreshScenario {
    enum Input {
        /// A network/route/proxy/VPN/wake signal (enters the event window with `.networkChange`).
        case network
        /// App/screen/session activation (enters the event window with `.routine`).
        case routineEvent
        /// Periodic timer (calls refresh directly with `.routine`).
        case periodic
        /// Refresh now (calls refresh directly with `.manual`).
        case manual
    }

    struct Lookup: Equatable {
        var at: Date
        var provider: ProviderID
        var trigger: String
        var urgency: RefreshUrgency
    }

    struct Queued: Equatable {
        var at: Date
        var trigger: String
        var urgency: RefreshUrgency
        var reason: String
        var notBefore: Date
    }

    static let lookupDuration: TimeInterval = 1

    var pool: [ProviderID]
    var preferred: ProviderID
    var budget: LookupBudget
    var lastAttempts: [ProviderID: Date] = [:]
    var lastSuccess: Date?
    /// Refusal cooldown deadlines (a provider answered `429` or a quota error).
    var cooldowns: [ProviderID: Date] = [:]

    private(set) var lookups: [Lookup] = []
    private(set) var queued: [Queued] = []
    private(set) var skipped: [(at: Date, trigger: String, reason: String)] = []
    private(set) var merged: [Date] = []
    private(set) var superseded: [(at: Date, notBefore: Date)] = []
    private(set) var dailyBudgetPauses: [(at: Date, resetAt: Date)] = []
    private(set) var allPausedUntil: [(at: Date, until: Date)] = []
    /// Set when internal timers kept firing at the same instant (a re-queue loop); the run stops.
    private(set) var stalled = false

    private var now: Date
    private var window = EventRefreshWindow()
    private var pending = PendingRefresh()
    private var windowTimer: Date?
    private var queueTimer: Date?
    private var inFlightUntil: Date?
    private var recheckUrgency: RefreshUrgency?

    init(
        start: Date,
        pool: [ProviderID] = [.ipapiCo, .ipWhois, .ipapiIs],
        budget: LookupBudget? = nil
    ) {
        self.now = start
        self.pool = pool
        self.preferred = pool[0]
        self.budget = budget ?? LookupBudget(now: start)
    }

    /// A budget whose burst tokens are used up at `date`, as after a busy period.
    static func drainedBudget(at date: Date) -> LookupBudget {
        var budget = LookupBudget(now: date)
        for _ in 0..<Int(LookupBudget.burstCapacity) {
            _ = budget.admit(.manual, lastSuccess: nil, now: date)
        }
        return budget
    }

    /// Feeds timestamped inputs, then lets every timer, queued lookup, and recheck run to completion.
    mutating func run(_ inputs: [(Date, Input)]) {
        for (date, input) in inputs.sorted(by: { $0.0 < $1.0 }) {
            advance(to: date)
            now = date
            handle(input)
        }
        advance(to: .distantFuture)
    }

    // MARK: Engine (mirrors PublicIPMonitor)

    private mutating func handle(_ input: Input) {
        switch input {
        case .network:
            handleEvent(.networkChange, trigger: "network")
        case .routineEvent:
            handleEvent(.routine, trigger: "routine_event")
        case .periodic:
            request(.routine, trigger: "periodic")
        case .manual:
            request(.manual, trigger: "manual")
        }
    }

    private mutating func handleEvent(_ urgency: RefreshUrgency, trigger: String) {
        switch window.register(urgency, now: now) {
        case .runNow(let windowEndsAt):
            windowTimer = windowEndsAt
            request(urgency, trigger: trigger)
        case .mergedIntoTrailing:
            merged.append(now)
        case .absorbed:
            skipped.append((now, trigger, "event_window"))
        }
    }

    private mutating func request(_ urgency: RefreshUrgency, trigger: String) {
        if inFlightUntil != nil {
            if urgency >= .followUp {
                recheckUrgency = max(recheckUrgency ?? urgency, urgency)
            }
            return
        }
        let decision = RefreshGate.decide(
            urgency: urgency,
            pool: pool,
            preferred: preferred,
            lastAttempts: lastAttempts,
            cooldowns: cooldowns,
            budget: &budget,
            lastSuccess: lastSuccess,
            now: now
        )
        switch decision {
        case .run(let provider, _):
            if let notBefore = pending.supersede() {
                queueTimer = nil
                superseded.append((now, notBefore))
            }
            lastAttempts[provider] = now
            lookups.append(Lookup(at: now, provider: provider, trigger: trigger, urgency: urgency))
            inFlightUntil = now.addingTimeInterval(Self.lookupDuration)
            if let index = pool.firstIndex(of: provider) {
                preferred = pool[(index + 1) % pool.count]
            }
        case .queue(let date, let reason):
            if pending.enqueue(at: date, urgency: urgency) || queueTimer == nil {
                queueTimer = pending.notBefore
            }
            queued.append(Queued(at: now, trigger: trigger, urgency: urgency, reason: reason, notBefore: pending.notBefore ?? date))
        case .skip(let reason):
            skipped.append((now, trigger, reason))
        case .dailyBudgetExhausted(let resetAt):
            dailyBudgetPauses.append((now, resetAt))
        case .allProvidersPaused(let until):
            allPausedUntil.append((now, until))
        }
    }

    /// Fires internal timers (lookup completion, window end, queued boundary) up to `limit`, in time order.
    private mutating func advance(to limit: Date) {
        var firedAtSameInstant = 0
        while !stalled {
            let candidates = [inFlightUntil, windowTimer, queueTimer].compactMap { $0 }.filter { $0 <= limit }
            guard let next = candidates.min() else { return }
            firedAtSameInstant = next == now ? firedAtSameInstant + 1 : 0
            if firedAtSameInstant > 10 {
                stalled = true
                return
            }
            now = next
            if inFlightUntil == next {
                inFlightUntil = nil
                lastSuccess = next
                if let urgency = recheckUrgency {
                    recheckUrgency = nil
                    request(urgency, trigger: "recheck")
                }
            } else if windowTimer == next {
                windowTimer = nil
                if let trailing = window.takeTrailing(now: now) {
                    windowTimer = trailing.windowEndsAt
                    request(trailing.urgency, trigger: "trailing")
                }
            } else {
                queueTimer = nil
                let urgency = pending.take() ?? .networkChange
                request(urgency, trigger: "queued")
            }
        }
    }

    // MARK: Assertions helpers

    /// Seconds from `date` until the next lookup starts (`nil` if none does).
    func latencyOfFirstLookup(atOrAfter date: Date) -> TimeInterval? {
        lookups.first { $0.at >= date }.map { $0.at.timeIntervalSince(date) }
    }

    /// Lookups to the same provider closer together than the per-provider gap.
    func gapViolations() -> [Lookup] {
        var last: [ProviderID: Date] = [:]
        var violations: [Lookup] = []
        for lookup in lookups {
            if let previous = last[lookup.provider],
               lookup.at.timeIntervalSince(previous) < RefreshPolicy.minimumRefreshSpacing {
                violations.append(lookup)
            }
            last[lookup.provider] = lookup.at
        }
        return violations
    }
}
