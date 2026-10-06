import XCTest
@testable import ExitIPShared

/// End-to-end refresh-policy scenarios on a virtual clock (see `RefreshScenario`). The central promise:
/// a real network change starts a lookup at once, however many lookups ran before it.
final class RefreshScenarioTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute, second: second))!
    }

    // MARK: Regression: the 2026-10-03 runtime log

    /// The triggers from the runtime log where `route_change` at 10:22:39 and 10:33:20 were queued with
    /// `reason=burst_budget` (the latter ran ~90 s late). Starting from an empty burst bucket, every network
    /// event must now start a lookup immediately, or within its event window when merged.
    func testLoggedNetworkChangesRunImmediatelyEvenWithAnEmptyBurstBucket() {
        let start = date(10, 21, 40)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        let network: [Date] = [
            date(10, 21, 49), date(10, 21, 50), date(10, 21, 55), date(10, 22, 1), date(10, 22, 11),
            date(10, 22, 21), date(10, 22, 39), date(10, 22, 54), date(10, 22, 59), date(10, 23, 21),
            date(10, 28, 46), date(10, 28, 51), date(10, 31, 5), date(10, 33, 5), date(10, 33, 20),
            date(10, 33, 31), date(10, 33, 37)
        ]
        var inputs = network.map { ($0, RefreshScenario.Input.network) }
        inputs.append((date(10, 22, 23), .routineEvent))
        inputs.append((date(10, 22, 44), .manual))
        inputs.append((date(10, 25, 28), .periodic))
        scenario.run(inputs)
        XCTAssertFalse(scenario.stalled)

        for event in network {
            let latency = scenario.latencyOfFirstLookup(atOrAfter: event)
            XCTAssertNotNil(latency, "No lookup after network event at \(event)")
            XCTAssertLessThanOrEqual(
                latency ?? .infinity,
                RefreshPolicy.eventWindow + RefreshScenario.lookupDuration,
                "Network event at \(event) waited too long"
            )
        }
        // The two events that were burst-deferred in the log now start a lookup at their own timestamp.
        XCTAssertEqual(scenario.latencyOfFirstLookup(atOrAfter: date(10, 22, 39)), 0)
        XCTAssertEqual(scenario.latencyOfFirstLookup(atOrAfter: date(10, 33, 20)), 0)
        XCTAssertTrue(
            scenario.queued.filter { $0.urgency >= .networkChange && $0.reason == "burst_budget" }.isEmpty,
            "A network change must never wait for the burst allowance: \(scenario.queued)"
        )
        XCTAssertEqual(scenario.gapViolations(), [])
    }

    // MARK: Empty bucket

    func testEmptyBucketStillRunsNetworkAndManualWhileRoutineSpendsNothing() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        scenario.lastSuccess = start.addingTimeInterval(-600)
        scenario.run([
            (start, .network),
            (start.addingTimeInterval(20), .manual),
            (start.addingTimeInterval(40), .periodic)
        ])
        XCTAssertFalse(scenario.stalled)
        XCTAssertEqual(scenario.lookups.map(\.trigger), ["network", "manual"])
        XCTAssertEqual(scenario.lookups.map { $0.at.timeIntervalSince(start) }, [0, 20])
        // The periodic tick 19 s after the manual result is answered by it (routine `burst_budget`
        // skips are covered by `testRefreshGate...` in ExitIPSharedTests).
        XCTAssertEqual(scenario.skipped.map(\.reason), ["fresh"])
        XCTAssertTrue(scenario.queued.isEmpty)
    }

    // MARK: VPN connect

    /// A VPN emits a network-path change and then installs routes over the next seconds. The immediate
    /// lookup may still see the old exit, so the one trailing settle check must also run on time, on a
    /// different provider, even with no burst tokens left.
    func testVPNConnectGetsImmediateLookupAndOnTimeSettleCheckWithEmptyBucket() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        scenario.run([
            (start, .network),
            (start.addingTimeInterval(1), .network),
            (start.addingTimeInterval(2), .network),
            (start.addingTimeInterval(3), .network)
        ])
        XCTAssertFalse(scenario.stalled)
        XCTAssertEqual(scenario.lookups.count, 2)
        XCTAssertEqual(scenario.lookups.map(\.trigger), ["network", "trailing"])
        XCTAssertEqual(scenario.lookups.map { $0.at.timeIntervalSince(start) }, [0, RefreshPolicy.eventWindow])
        guard scenario.lookups.count == 2 else { return XCTFail("Expected two lookups: \(scenario.lookups)") }
        XCTAssertNotEqual(scenario.lookups[0].provider, scenario.lookups[1].provider)
        XCTAssertEqual(scenario.merged.count, 3)
        XCTAssertTrue(scenario.queued.isEmpty)
    }

    /// Someone changes several settings a few seconds apart (proxy, then DNS, then VPN). The windows chain,
    /// but every change is checked within one event window, even with an empty bucket.
    func testSequentialSettingChangesSecondsApartAreEachCheckedPromptly() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        let changes = [0, 4, 8, 12, 17, 21].map { start.addingTimeInterval(TimeInterval($0)) }
        scenario.run(changes.map { ($0, .network) })
        XCTAssertFalse(scenario.stalled)
        for change in changes {
            XCTAssertLessThanOrEqual(scenario.latencyOfFirstLookup(atOrAfter: change) ?? .infinity, RefreshPolicy.eventWindow, "\(change)")
        }
        XCTAssertTrue(scenario.queued.isEmpty, "\(scenario.queued)")
        XCTAssertEqual(scenario.gapViolations(), [])
    }

    func testEventDuringInFlightLookupGetsOneRecheckRightAfterIt() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        // A manual lookup is in flight when a network change opens a new event window.
        scenario.run([
            (start, .manual),
            (start.addingTimeInterval(0.5), .network)
        ])
        XCTAssertFalse(scenario.stalled)
        XCTAssertEqual(scenario.lookups.map(\.trigger), ["manual", "recheck"])
        guard scenario.lookups.count == 2 else { return XCTFail("Expected two lookups: \(scenario.lookups)") }
        XCTAssertEqual(scenario.lookups[1].at.timeIntervalSince(start), RefreshScenario.lookupDuration)
        XCTAssertEqual(scenario.lookups[1].urgency, .networkChange)
        XCTAssertNotEqual(scenario.lookups[0].provider, scenario.lookups[1].provider)
    }

    // MARK: Quota protection

    /// A flapping tunnel firing every second for an hour: the leading lookup and the trailing lookups within
    /// the storm grace run at once, then chained trailing lookups settle to the burst refill rate. The final
    /// state is still checked.
    func testContinuousStormIsBoundedByBurstAllowanceAndFinalStateIsChecked() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start)
        let duration = 3_600
        let inputs = (0..<duration).map { (start.addingTimeInterval(TimeInterval($0)), RefreshScenario.Input.network) }
        scenario.run(inputs)
        XCTAssertFalse(scenario.stalled)

        let refills = Int(TimeInterval(duration) / LookupBudget.tokenRefillInterval)
        let graceLookups = 1 + Int(RefreshPolicy.eventStormGrace / RefreshPolicy.eventWindow)
        XCTAssertLessThanOrEqual(scenario.lookups.count, Int(LookupBudget.burstCapacity) + graceLookups + refills + 1)
        XCTAssertGreaterThanOrEqual(scenario.lookups.count, refills)
        XCTAssertEqual(scenario.lookups.first?.at, start)
        XCTAssertEqual(scenario.gapViolations(), [])
        // Only chained follow-ups wait for the bucket.
        XCTAssertFalse(scenario.queued.isEmpty)
        XCTAssertTrue(scenario.queued.allSatisfy { $0.urgency == .followUp && $0.reason == "burst_budget" })
        // The last event is checked once a token arrives (deferred, never dropped).
        let lastEvent = start.addingTimeInterval(TimeInterval(duration - 1))
        let latency = scenario.latencyOfFirstLookup(atOrAfter: lastEvent)
        XCTAssertNotNil(latency)
        XCTAssertLessThanOrEqual(latency ?? .infinity, RefreshPolicy.eventWindow + LookupBudget.tokenRefillInterval)
    }

    /// Changes every 6 s (each opens a new event window) for most of a UTC day: every change runs at once
    /// until the per-provider daily budgets are used up, and no provider ever exceeds its budget.
    func testFlappingAllDayStaysWithinEveryProviderDailyBudget() {
        let midnight = utc.startOfDay(for: date(12, 0, 0))
        var scenario = RefreshScenario(start: midnight)
        let inputs = stride(from: 0, to: 23 * 3_600, by: 6).map {
            (midnight.addingTimeInterval(TimeInterval($0)), RefreshScenario.Input.network)
        }
        scenario.run(inputs)
        XCTAssertFalse(scenario.stalled)

        var totalBudget = 0
        for provider in scenario.pool {
            let budget = LookupBudget.dailyBudget(for: provider)!
            totalBudget += budget
            XCTAssertEqual(scenario.lookups.filter { $0.provider == provider }.count, budget, "\(provider)")
            XCTAssertTrue(scenario.budget.isExhausted(provider, now: midnight))
        }
        XCTAssertEqual(scenario.lookups.count, totalBudget)
        XCTAssertTrue(scenario.lookups.allSatisfy { $0.trigger == "network" })
        XCTAssertEqual(scenario.gapViolations(), [])
        XCTAssertFalse(scenario.dailyBudgetPauses.isEmpty)
        XCTAssertTrue(scenario.dailyBudgetPauses.allSatisfy {
            $0.resetAt == midnight.addingTimeInterval(24 * 3_600)
        })
    }

    // MARK: Gap, queue, supersede

    func testSingleProviderPoolQueuesInsideTheGapAndKeepsNetworkUrgency() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, pool: [.ipinfoLite], budget: RefreshScenario.drainedBudget(at: start))
        scenario.run([
            (start, .manual),
            (start.addingTimeInterval(2), .network)
        ])
        XCTAssertFalse(scenario.stalled)
        guard scenario.queued.count == 1 else { return XCTFail("Expected one queued request: \(scenario.queued)") }
        XCTAssertEqual(scenario.queued[0].reason, "provider_gap")
        XCTAssertEqual(scenario.queued[0].urgency, .networkChange)
        XCTAssertEqual(scenario.queued[0].notBefore, start.addingTimeInterval(RefreshPolicy.minimumRefreshSpacing))
        // The queued lookup keeps network urgency, so the empty bucket does not delay it further.
        XCTAssertEqual(scenario.lookups.map(\.trigger), ["manual", "queued"])
        guard scenario.lookups.count == 2 else { return XCTFail("Expected two lookups: \(scenario.lookups)") }
        XCTAssertEqual(scenario.lookups[1].at, start.addingTimeInterval(RefreshPolicy.minimumRefreshSpacing))
    }

    /// A storm leaves a chained follow-up waiting for a burst token. A new real network change after the
    /// storm runs at once and supersedes that queued lookup, so no stale lookup fires later.
    func testNewNetworkChangeSupersedesABurstDeferredFollowUp() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, budget: RefreshScenario.drainedBudget(at: start))
        let storm = (0..<60).map { (start.addingTimeInterval(TimeInterval($0)), RefreshScenario.Input.network) }
        let change = start.addingTimeInterval(100)
        scenario.run(storm + [(change, .network)])
        XCTAssertFalse(scenario.stalled)

        XCTAssertTrue(scenario.queued.contains { $0.urgency == .followUp && $0.reason == "burst_budget" })
        XCTAssertEqual(scenario.latencyOfFirstLookup(atOrAfter: change), 0)
        XCTAssertEqual(scenario.superseded.count, 1)
        XCTAssertEqual(scenario.superseded.first?.at, change)
        XCTAssertFalse(scenario.lookups.contains { $0.trigger == "queued" })
    }

    // MARK: Provider pause

    /// ipapi.is answered `429` and is the active provider. Later network changes and Refresh now run at
    /// once on the other pool providers; ipapi.is is not called again before its deadline.
    func testPausedActiveProviderIsSkippedAndNetworkChangesStillRunImmediately() {
        let start = date(12, 0, 0)
        let deadline = start.addingTimeInterval(3_600)
        var scenario = RefreshScenario(start: start)
        scenario.preferred = .ipapiIs
        scenario.cooldowns = [.ipapiIs: deadline]
        let events = [start.addingTimeInterval(10), start.addingTimeInterval(300), start.addingTimeInterval(900)]
        scenario.run(events.map { ($0, .network) } + [(start.addingTimeInterval(600), .manual)])
        XCTAssertFalse(scenario.stalled)

        for event in events {
            XCTAssertEqual(scenario.latencyOfFirstLookup(atOrAfter: event), 0, "Network event at \(event) waited")
        }
        XCTAssertFalse(scenario.lookups.contains { $0.provider == .ipapiIs && $0.at < deadline })
        XCTAssertTrue(scenario.allPausedUntil.isEmpty)
    }

    func testEveryProviderPausedWaitsForEarliestDeadline() {
        let start = date(12, 0, 0)
        var scenario = RefreshScenario(start: start, pool: [.ipapiIs, .ipapiCo])
        scenario.cooldowns = [.ipapiIs: start.addingTimeInterval(3_600), .ipapiCo: start.addingTimeInterval(600)]
        scenario.run([(start.addingTimeInterval(10), .network)])
        XCTAssertTrue(scenario.lookups.isEmpty)
        XCTAssertEqual(scenario.allPausedUntil.map(\.until), [start.addingTimeInterval(600)])
    }
}
