import XCTest
@testable import ExitIPShared

final class ExitIPSharedTests: XCTestCase {
    private func snapshot(countryCode: String, countryName: String) -> ExitIPSnapshot {
        ExitIPSnapshot(
            ipAddress: "203.0.113.8",
            countryCode: countryCode,
            countryName: countryName,
            provider: .ipapiCo,
            checkedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testCountryChangeIsCreatedOnlyWhenTheCountryDiffers() {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous = snapshot(countryCode: "CA", countryName: "Canada")
        let current = snapshot(countryCode: "US", countryName: "United States")

        let changed = CountryChangeDetector.applyingCountryChange(
            to: current,
            previous: previous,
            at: now,
            highlightDuration: 600
        )

        XCTAssertEqual(changed.countryChange?.previousCode, "CA")
        XCTAssertEqual(changed.countryChange?.previousName, "Canada")
        XCTAssertTrue(changed.isCountryChangeHighlighted(at: now.addingTimeInterval(599)))
        XCTAssertFalse(changed.isCountryChangeHighlighted(at: now.addingTimeInterval(600)))
    }

    func testUnchangedCountryKeepsAnActiveHighlightButDropsExpiredHighlight() {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous = ExitIPSnapshot(
            ipAddress: "203.0.113.8",
            countryCode: "US",
            countryName: "United States",
            provider: .ipapiCo,
            checkedAt: now,
            countryChange: CountryChange(
                previousCode: "CA",
                previousName: "Canada",
                changedAt: now,
                highlightUntil: now.addingTimeInterval(600)
            )
        )
        let current = snapshot(countryCode: "US", countryName: "United States")

        XCTAssertNotNil(CountryChangeDetector.applyingCountryChange(to: current, previous: previous, at: now).countryChange)
        XCTAssertNil(CountryChangeDetector.applyingCountryChange(to: current, previous: previous, at: now.addingTimeInterval(600)).countryChange)
    }

    func testStaleSameNameCountryChangeIsNotDisplayedAsAChange() {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous = ExitIPSnapshot(
            ipAddress: "203.0.113.8",
            countryCode: "SG",
            countryName: "Singapore",
            provider: .ipapiCo,
            checkedAt: now,
            countryChange: CountryChange(
                previousCode: "SG",
                previousName: "Singapore",
                changedAt: now,
                highlightUntil: now.addingTimeInterval(600)
            )
        )
        let current = snapshot(countryCode: "SG", countryName: "Singapore")

        XCTAssertNil(CountryChangeDetector.applyingCountryChange(to: current, previous: previous, at: now).countryChange)
    }

    func testProviderErrorsDoNotUseFallbackToBypassRateLimits() {
        XCTAssertFalse(LookupError.rateLimited(retryAfter: nil).supportsResilienceRetry)
        XCTAssertFalse(LookupError.missingToken(.ipinfoLite).supportsResilienceRetry)
        XCTAssertTrue(LookupError.transport("offline").supportsResilienceRetry)
        XCTAssertTrue(LookupError.httpStatus(503, retryAfter: nil).supportsResilienceRetry)
    }

    func testCountryChangeConfirmationUsesADifferentProvider() {
        for primary in ProviderID.allCases {
            XCTAssertNotEqual(
                CountryChangeConfirmationPolicy.secondaryProvider(for: primary),
                primary,
                "The country-change confirmation provider must differ from the primary provider."
            )
        }
        XCTAssertEqual(CountryChangeConfirmationPolicy.secondaryProvider(for: .ipWhois), .ipapiCo)
    }

    func testWidgetContentChangeSkipsTimestampOnlyRefreshes() {
        let previous = snapshot(countryCode: "JP", countryName: "Japan")
        var refreshed = previous
        refreshed.checkedAt = previous.checkedAt.addingTimeInterval(900)

        XCTAssertFalse(refreshed.hasWidgetContentChange(comparedTo: previous))

        refreshed.ipAddress = "203.0.113.9"
        XCTAssertTrue(refreshed.hasWidgetContentChange(comparedTo: previous))
    }

    func testMenuLabelSupportsFlagOrCountryNameWithoutExtraIconography() {
        let japan = snapshot(countryCode: "JP", countryName: "Japan")

        XCTAssertEqual(japan.menuBarLabel(style: .flag), "🇯🇵")
        XCTAssertEqual(japan.menuBarLabel(style: .name), "Japan")
        XCTAssertEqual(japan.menuBarLabel(style: .flagAndName), "🇯🇵 Japan")
        XCTAssertEqual(japan.menuBarLabel(style: .code), "JP")
    }

    func testCountryCodeResolverRejectsPlaceholdersAndResolvesNames() {
        XCTAssertEqual(CountryCodeResolver.resolvedCode(code: "--", countryName: "Singapore"), "SG")
        XCTAssertEqual(CountryCodeResolver.resolvedCode(code: "us", countryName: "United States"), "US")
        XCTAssertNil(CountryCodeResolver.resolvedCode(code: "--", countryName: "Unknown Place"))
    }

    func testSnapshotStaleThreshold() {
        let checked = Date(timeIntervalSince1970: 1_000)
        let snapshot = ExitIPSnapshot(
            ipAddress: "203.0.113.8",
            countryCode: "SG",
            countryName: "Singapore",
            provider: .ipapiCo,
            checkedAt: checked
        )
        XCTAssertFalse(snapshot.isStale(at: checked.addingTimeInterval(599), threshold: 600))
        XCTAssertTrue(snapshot.isStale(at: checked.addingTimeInterval(600), threshold: 600))
    }

    func testProviderHealthAndDiagnosticPreferencesRoundTrip() {
        let suite = "ExitIPSharedTests.health.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let health = ProviderHealthStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 2_000)
        health.save(ProviderHealthRecord(lastAttempt: date, lastSuccess: date, consecutiveFailures: 0), for: .ipapiCo)
        XCTAssertEqual(health.load(for: .ipapiCo).lastSuccess, date)

        let diagnostics = DiagnosticPreferencesStore(defaults: defaults)
        diagnostics.save(DiagnosticPreferences(includeFullIPAddresses: true, retentionDays: 30))
        XCTAssertEqual(diagnostics.load(), DiagnosticPreferences(includeFullIPAddresses: true, retentionDays: 30))
    }

    func testEventWindowAndPerProviderGapAreFiveSeconds() {
        XCTAssertEqual(RefreshPolicy.eventWindow, 5)
        XCTAssertEqual(RefreshPolicy.minimumRefreshSpacing, 5)
        XCTAssertEqual(RefreshPolicy.eventStormGrace, 30)
    }

    func testEventWindowRunsFirstEventImmediatelyThenMergesIntoOneTrailingLookup() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var window = EventRefreshWindow()
        let end = start.addingTimeInterval(RefreshPolicy.eventWindow)
        XCTAssertEqual(window.register(.networkChange, now: start), .runNow(windowEndsAt: end))
        XCTAssertEqual(window.register(.networkChange, now: start.addingTimeInterval(0.4)), .mergedIntoTrailing(windowEndsAt: end))
        XCTAssertEqual(window.register(.networkChange, now: start.addingTimeInterval(2)), .mergedIntoTrailing(windowEndsAt: end))
        XCTAssertTrue(window.trailingPending)
        // Several merged events owe exactly one trailing lookup, which opens a new window.
        // It is the settle check for a real change, so it carries network-change urgency.
        let nextEnd = end.addingTimeInterval(RefreshPolicy.eventWindow)
        XCTAssertEqual(window.takeTrailing(now: end), .init(windowEndsAt: nextEnd, urgency: .networkChange))
        XCTAssertFalse(window.trailingPending)
        // An event inside the trailing lookup's window is merged again (a storm settles to one per window).
        XCTAssertEqual(window.register(.networkChange, now: end.addingTimeInterval(1)), .mergedIntoTrailing(windowEndsAt: nextEnd))
        // Chained trailing lookups within the storm grace still check real changes made seconds apart.
        let thirdEnd = nextEnd.addingTimeInterval(RefreshPolicy.eventWindow)
        XCTAssertEqual(window.takeTrailing(now: nextEnd), .init(windowEndsAt: thirdEnd, urgency: .networkChange))
        // A storm that outlasts the grace is throttled: its trailing lookups become follow-ups.
        var end2 = thirdEnd
        while end2.timeIntervalSince(start) <= RefreshPolicy.eventStormGrace {
            XCTAssertEqual(window.register(.networkChange, now: end2.addingTimeInterval(-1)), .mergedIntoTrailing(windowEndsAt: end2))
            XCTAssertEqual(window.takeTrailing(now: end2)?.urgency, .networkChange, "\(end2.timeIntervalSince(start))")
            end2 = end2.addingTimeInterval(RefreshPolicy.eventWindow)
        }
        XCTAssertEqual(window.register(.networkChange, now: end2.addingTimeInterval(-1)), .mergedIntoTrailing(windowEndsAt: end2))
        let late = window.takeTrailing(now: end2)
        XCTAssertEqual(late?.urgency, .followUp)
        // When the storm stops the window closes, and the next change is a fresh leading lookup again.
        let quietEnd = try! XCTUnwrap(late).windowEndsAt
        XCTAssertNil(window.takeTrailing(now: quietEnd))
        XCTAssertNil(window.leadingAt)
        let next = quietEnd.addingTimeInterval(1)
        XCTAssertEqual(window.register(.networkChange, now: next), .runNow(windowEndsAt: next.addingTimeInterval(RefreshPolicy.eventWindow)))
        XCTAssertEqual(window.register(.networkChange, now: next.addingTimeInterval(1)), .mergedIntoTrailing(windowEndsAt: next.addingTimeInterval(RefreshPolicy.eventWindow)))
        XCTAssertEqual(window.takeTrailing(now: next.addingTimeInterval(RefreshPolicy.eventWindow))?.urgency, .networkChange)
    }

    func testEventWindowAbsorbsRoutineEventsAndClosesQuietly() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var window = EventRefreshWindow()
        let end = start.addingTimeInterval(RefreshPolicy.eventWindow)
        XCTAssertEqual(window.register(.routine, now: start), .runNow(windowEndsAt: end))
        XCTAssertEqual(window.register(.routine, now: start.addingTimeInterval(1)), .absorbed)
        XCTAssertFalse(window.trailingPending)
        // No merged network events: no trailing lookup, and the window closes.
        XCTAssertNil(window.takeTrailing(now: end))
        XCTAssertNil(window.windowEndsAt)
        // The next event after a quiet period runs immediately again.
        let later = end.addingTimeInterval(30)
        XCTAssertEqual(window.register(.networkChange, now: later), .runNow(windowEndsAt: later.addingTimeInterval(RefreshPolicy.eventWindow)))
        // An event arriving after the window end (before the end task ran) also runs immediately.
        let afterEnd = later.addingTimeInterval(RefreshPolicy.eventWindow)
        XCTAssertEqual(window.register(.networkChange, now: afterEnd), .runNow(windowEndsAt: afterEnd.addingTimeInterval(RefreshPolicy.eventWindow)))
        window.reset()
        XCTAssertNil(window.windowEndsAt)
    }

    func testProviderSelectionRotatesAwayFromRecentlyCalledProviders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pool: [ProviderID] = [.ipapiCo, .ipWhois, .ipapiIs]
        // Preferred provider is free.
        XCTAssertEqual(
            RefreshPolicy.providerSelection(pool: pool, preferred: .ipWhois, lastAttempts: [.ipWhois: now.addingTimeInterval(-5)], at: now),
            .use(.ipWhois)
        )
        // Preferred was called 1 s ago: the next pool entry in rotation order runs immediately instead.
        XCTAssertEqual(
            RefreshPolicy.providerSelection(pool: pool, preferred: .ipWhois, lastAttempts: [.ipWhois: now.addingTimeInterval(-1)], at: now),
            .use(.ipapiIs)
        )
        // Rotation wraps around the pool and skips excluded providers.
        XCTAssertEqual(
            RefreshPolicy.providerSelection(
                pool: pool,
                preferred: .ipWhois,
                lastAttempts: [.ipWhois: now.addingTimeInterval(-1)],
                excluded: [.ipapiIs],
                at: now
            ),
            .use(.ipapiCo)
        )
        // Every provider was called recently: wait for the earliest one to become free.
        XCTAssertEqual(
            RefreshPolicy.providerSelection(
                pool: pool,
                preferred: .ipapiCo,
                lastAttempts: [
                    .ipapiCo: now.addingTimeInterval(-1),
                    .ipWhois: now.addingTimeInterval(-3),
                    .ipapiIs: now.addingTimeInterval(-2)
                ],
                at: now
            ),
            .waitUntil(now.addingTimeInterval(2))
        )
        // Nothing eligible at all.
        XCTAssertEqual(
            RefreshPolicy.providerSelection(pool: pool, preferred: .ipapiCo, lastAttempts: [:], excluded: Set(pool), at: now),
            .unavailable
        )
    }

    func testProviderSelectionWithSingleProviderPoolKeepsTheGap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let last = now.addingTimeInterval(-2)
        XCTAssertEqual(
            RefreshPolicy.providerSelection(pool: [.ipapiCo], preferred: .ipapiCo, lastAttempts: [.ipapiCo: last], at: now),
            .waitUntil(last.addingTimeInterval(RefreshPolicy.minimumRefreshSpacing))
        )
        XCTAssertEqual(
            RefreshPolicy.providerSelection(pool: [.ipapiCo], preferred: .ipapiCo, lastAttempts: [.ipapiCo: last], at: now.addingTimeInterval(3)),
            .use(.ipapiCo)
        )
    }

    func testRouteChangeFilterKeepsRouteGatewayAndInterfaceChanges() {
        // A TUN tool installing split default routes (static, gateway) on utun.
        XCTAssertTrue(RouteChangeFilter.isRelevant(
            messageType: RTM_ADD, routeFlags: RTF_UP | RTF_GATEWAY | RTF_STATIC, interfaceName: "utun5"
        ))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_DELETE, routeFlags: RTF_UP | RTF_GATEWAY, interfaceName: "en0"))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_CHANGE, routeFlags: RTF_UP | RTF_GATEWAY, interfaceName: "en0"))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_NEWADDR, interfaceName: "utun5"))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_DELADDR, interfaceName: "en0"))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_IFINFO, interfaceName: "en0"))
        XCTAssertTrue(RouteChangeFilter.isRelevant(messageType: RTM_ADD, routeFlags: RTF_UP, interfaceName: nil))
    }

    func testRouteChangeFilterIgnoresKernelNoiseAndPeerToPeerInterfaces() {
        // ARP/ND entries, per-destination clones, redirects, and lookup misses must not cost a lookup.
        XCTAssertFalse(RouteChangeFilter.isRelevant(
            messageType: RTM_ADD, routeFlags: RTF_UP | RTF_HOST | RTF_LLINFO | RTF_WASCLONED, interfaceName: "en0"
        ))
        XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_ADD, routeFlags: RTF_UP | RTF_WASCLONED, interfaceName: "en0"))
        XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_CHANGE, routeFlags: RTF_UP | RTF_DYNAMIC, interfaceName: "en0"))
        XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_MISS, interfaceName: nil))
        XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_GET, interfaceName: "en0"))
        XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_RESOLVE, interfaceName: "en0"))
        for name in ["lo0", "awdl0", "llw0", "anpi1", "gif0", "stf0"] {
            XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_IFINFO, interfaceName: name), name)
            XCTAssertFalse(RouteChangeFilter.isRelevant(messageType: RTM_ADD, routeFlags: RTF_UP, interfaceName: name), name)
        }
    }

    func testLookupBudgetAllowsPromptBurstThenThrottlesOnlyFollowUps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: start)
        for _ in 0..<Int(LookupBudget.burstCapacity) {
            XCTAssertEqual(budget.admit(.followUp, lastSuccess: nil, now: start), .proceed)
        }
        XCTAssertEqual(budget.tokens, 0)
        // Empty bucket: a follow-up is deferred to the next token, never dropped.
        XCTAssertEqual(
            budget.admit(.followUp, lastSuccess: nil, now: start),
            .deferUntil(start.addingTimeInterval(LookupBudget.tokenRefillInterval))
        )
        // Routine checks are dropped instead; the timer will come round again.
        XCTAssertEqual(budget.admit(.routine, lastSuccess: nil, now: start), .skip(reason: "burst_budget"))
        // A real network change and a manual refresh are never delayed by the bucket.
        XCTAssertEqual(budget.admit(.networkChange, lastSuccess: nil, now: start), .proceed)
        XCTAssertEqual(budget.admit(.manual, lastSuccess: nil, now: start), .proceed)
        XCTAssertEqual(budget.tokens, 0)
        // One refill interval later, exactly one more follow-up is allowed.
        let later = start.addingTimeInterval(LookupBudget.tokenRefillInterval)
        XCTAssertEqual(budget.admit(.followUp, lastSuccess: nil, now: later), .proceed)
        if case .deferUntil = budget.admit(.followUp, lastSuccess: nil, now: later) {} else {
            XCTFail("Second follow-up in the same refill interval must be deferred")
        }
        // Network changes still spend tokens, so they count against later follow-ups.
        let refilled = later.addingTimeInterval(LookupBudget.tokenRefillInterval)
        XCTAssertEqual(budget.admit(.networkChange, lastSuccess: nil, now: refilled), .proceed)
        if case .deferUntil = budget.admit(.followUp, lastSuccess: nil, now: refilled) {} else {
            XCTFail("A network change must spend the token a follow-up would have used")
        }
        // A long idle period refills to the cap, not beyond it.
        let muchLater = later.addingTimeInterval(24 * 60 * 60)
        for _ in 0..<Int(LookupBudget.burstCapacity) {
            XCTAssertEqual(budget.admit(.followUp, lastSuccess: nil, now: muchLater), .proceed)
        }
        if case .deferUntil = budget.admit(.followUp, lastSuccess: nil, now: muchLater) {} else {
            XCTFail("Bucket must not exceed its burst capacity")
        }
    }

    /// A follow-up deferred to `(1 - tokens) * refill` must be admitted when it fires, even when
    /// floating-point refill lands a hair below one token; otherwise it re-queues for the same instant.
    func testDeferredFollowUpIsAdmittedAtItsBoundaryDespiteRoundingError() {
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000.123)
        var budget = LookupBudget(now: start)
        for _ in 0..<Int(LookupBudget.burstCapacity) { _ = budget.admit(.manual, lastSuccess: nil, now: start) }
        var now = start.addingTimeInterval(37.3)
        for _ in 0..<5 {
            guard case .deferUntil(let boundary) = budget.admit(.followUp, lastSuccess: nil, now: now) else {
                return XCTFail("Expected a deferral with an empty bucket")
            }
            XCTAssertGreaterThan(boundary, now)
            XCTAssertEqual(budget.admit(.followUp, lastSuccess: nil, now: boundary), .proceed)
            now = boundary.addingTimeInterval(13.7)
        }
    }

    func testRefreshUrgencyOrderAndLogNames() {
        XCTAssertLessThan(RefreshUrgency.routine, .followUp)
        XCTAssertLessThan(RefreshUrgency.followUp, .networkChange)
        XCTAssertLessThan(RefreshUrgency.networkChange, .manual)
        XCTAssertEqual(
            [RefreshUrgency.routine, .followUp, .networkChange, .manual].map(\.logName),
            ["routine", "follow_up", "network_change", "manual"]
        )
    }

    func testRefreshGateRotatesAwayFromRecentProviderAndRecordsTheCall() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        let decision = RefreshGate.decide(
            urgency: .networkChange,
            pool: [.ipapiCo, .ipWhois, .ipapiIs],
            preferred: .ipapiCo,
            lastAttempts: [.ipapiCo: now.addingTimeInterval(-2)],
            budget: &budget,
            lastSuccess: now.addingTimeInterval(-2),
            now: now
        )
        XCTAssertEqual(decision, .run(provider: .ipWhois, rotatedFrom: .ipapiCo))
        XCTAssertEqual(budget.callsToday(for: .ipWhois, now: now), 1)
        XCTAssertEqual(budget.callsToday(for: .ipapiCo, now: now), 0)
        XCTAssertEqual(budget.tokens, LookupBudget.burstCapacity - 1)
    }

    func testRefreshGateNetworkChangeRunsWithEmptyBucketButFollowUpAndRoutineDoNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func drained() -> LookupBudget {
            var budget = LookupBudget(now: now)
            for _ in 0..<Int(LookupBudget.burstCapacity) { _ = budget.admit(.manual, lastSuccess: nil, now: now) }
            return budget
        }
        let stale = now.addingTimeInterval(-600)
        func decide(_ urgency: RefreshUrgency) -> RefreshGate.Decision {
            var budget = drained()
            return RefreshGate.decide(urgency: urgency, pool: [.ipapiCo], preferred: .ipapiCo, lastAttempts: [:], budget: &budget, lastSuccess: stale, now: now)
        }
        XCTAssertEqual(decide(.networkChange), .run(provider: .ipapiCo, rotatedFrom: nil))
        XCTAssertEqual(decide(.manual), .run(provider: .ipapiCo, rotatedFrom: nil))
        XCTAssertEqual(decide(.followUp), .queue(until: now.addingTimeInterval(LookupBudget.tokenRefillInterval), reason: "burst_budget"))
        XCTAssertEqual(decide(.routine), .skip(reason: "burst_budget"))
        // A deferred or skipped request does not count against the provider's daily budget.
        var budget = drained()
        _ = RefreshGate.decide(urgency: .followUp, pool: [.ipapiCo], preferred: .ipapiCo, lastAttempts: [:], budget: &budget, lastSuccess: stale, now: now)
        XCTAssertEqual(budget.callsToday(for: .ipapiCo, now: now), 0)
    }

    func testRefreshGateQueuesOnProviderGapOrSkipsFreshRoutine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let attempts: [ProviderID: Date] = [.ipapiCo: now.addingTimeInterval(-1), .ipWhois: now.addingTimeInterval(-3)]
        var budget = LookupBudget(now: now)
        XCTAssertEqual(
            RefreshGate.decide(urgency: .networkChange, pool: [.ipapiCo, .ipWhois], preferred: .ipapiCo, lastAttempts: attempts, budget: &budget, lastSuccess: now, now: now),
            .queue(until: now.addingTimeInterval(2), reason: "provider_gap")
        )
        XCTAssertEqual(
            RefreshGate.decide(urgency: .routine, pool: [.ipapiCo, .ipWhois], preferred: .ipapiCo, lastAttempts: attempts, budget: &budget, lastSuccess: now, now: now),
            .skip(reason: "fresh")
        )
        // Nothing was spent by either decision.
        XCTAssertEqual(budget.tokens, LookupBudget.burstCapacity)
    }

    func testRefreshGateStartupBypassesGapAndBurstOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        for _ in 0..<Int(LookupBudget.burstCapacity) { _ = budget.admit(.manual, lastSuccess: nil, now: now) }
        let decision = RefreshGate.decide(
            urgency: .networkChange,
            pool: [.ipapiCo],
            preferred: .ipapiCo,
            lastAttempts: [.ipapiCo: now.addingTimeInterval(-1)],
            budget: &budget,
            lastSuccess: nil,
            bypassLimits: true,
            now: now
        )
        XCTAssertEqual(decision, .run(provider: .ipapiCo, rotatedFrom: nil))
        XCTAssertEqual(budget.callsToday(for: .ipapiCo, now: now), 1)
    }

    func testRefreshGateSkipsExhaustedProvidersAndPausesWhenAllAreExhausted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        for _ in 0..<LookupBudget.dailyBudget(for: .ipapiIs)! { budget.recordCall(to: .ipapiIs, now: now) }
        XCTAssertEqual(
            RefreshGate.decide(urgency: .networkChange, pool: [.ipapiIs, .ipWhois], preferred: .ipapiIs, lastAttempts: [:], budget: &budget, lastSuccess: nil, now: now),
            .run(provider: .ipWhois, rotatedFrom: .ipapiIs)
        )
        XCTAssertEqual(
            RefreshGate.decide(urgency: .manual, pool: [.ipapiIs], preferred: .ipapiIs, lastAttempts: [:], budget: &budget, lastSuccess: nil, now: now),
            .dailyBudgetExhausted(resetAt: LookupBudget.budgetResetDate(after: now))
        )
    }

    func testRefreshGateSkipsPausedPreferredProviderInNormalRotation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        let decision = RefreshGate.decide(
            urgency: .networkChange,
            pool: [.ipapiIs, .ipapiCo, .ipWhois],
            preferred: .ipapiIs,
            lastAttempts: [:],
            cooldowns: [.ipapiIs: now.addingTimeInterval(3_600)],
            budget: &budget,
            lastSuccess: now.addingTimeInterval(-600),
            now: now
        )
        XCTAssertEqual(decision, .run(provider: .ipapiCo, rotatedFrom: .ipapiIs))
        XCTAssertEqual(budget.callsToday(for: .ipapiIs, now: now), 0)
        XCTAssertEqual(budget.callsToday(for: .ipapiCo, now: now), 1)
    }

    func testRefreshGatePausesUntilEarliestDeadlineWhenEveryProviderIsPaused() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        let decision = RefreshGate.decide(
            urgency: .manual,
            pool: [.ipapiIs, .ipapiCo],
            preferred: .ipapiIs,
            lastAttempts: [:],
            cooldowns: [.ipapiIs: now.addingTimeInterval(3_600), .ipapiCo: now.addingTimeInterval(120)],
            budget: &budget,
            lastSuccess: nil,
            now: now
        )
        XCTAssertEqual(decision, .allProvidersPaused(until: now.addingTimeInterval(120)))
        XCTAssertEqual(budget.tokens, LookupBudget.burstCapacity)
    }

    func testRefreshGateMixedPauseAndExhaustionResumesAtEarliestUsableMoment() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = LookupBudget.budgetResetDate(after: now)
        var budget = LookupBudget(now: now)
        for _ in 0..<LookupBudget.dailyBudget(for: .ipapiIs)! { budget.recordCall(to: .ipapiIs, now: now) }
        let farPause = resetAt.addingTimeInterval(3_600)
        XCTAssertEqual(
            RefreshGate.decide(urgency: .manual, pool: [.ipapiIs, .ipapiCo], preferred: .ipapiCo, lastAttempts: [:], cooldowns: [.ipapiCo: farPause], budget: &budget, lastSuccess: nil, now: now),
            .allProvidersPaused(until: resetAt)
        )
        let nearPause = now.addingTimeInterval(60)
        XCTAssertEqual(
            RefreshGate.decide(urgency: .manual, pool: [.ipapiIs, .ipapiCo], preferred: .ipapiCo, lastAttempts: [:], cooldowns: [.ipapiCo: nearPause], budget: &budget, lastSuccess: nil, now: now),
            .allProvidersPaused(until: min(nearPause, resetAt))
        )
    }

    func testRefreshGateTreatsExpiredCooldownAsEligible() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        XCTAssertEqual(
            RefreshGate.decide(urgency: .networkChange, pool: [.ipapiIs, .ipapiCo], preferred: .ipapiIs, lastAttempts: [:], cooldowns: [.ipapiIs: now.addingTimeInterval(-1)], budget: &budget, lastSuccess: nil, now: now),
            .run(provider: .ipapiIs, rotatedFrom: nil)
        )
    }

    func testPendingRefreshKeepsEarliestBoundaryAndHighestUrgency() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pending = PendingRefresh()
        XCTAssertFalse(pending.isPending)
        XCTAssertTrue(pending.enqueue(at: now.addingTimeInterval(120), urgency: .followUp))
        // A later boundary never postpones the pending one, but raises its urgency.
        XCTAssertFalse(pending.enqueue(at: now.addingTimeInterval(200), urgency: .networkChange))
        XCTAssertEqual(pending.notBefore, now.addingTimeInterval(120))
        XCTAssertEqual(pending.urgency, .networkChange)
        // An earlier boundary moves it forward.
        XCTAssertTrue(pending.enqueue(at: now.addingTimeInterval(3), urgency: .routine))
        XCTAssertEqual(pending.notBefore, now.addingTimeInterval(3))
        XCTAssertEqual(pending.urgency, .networkChange)
        XCTAssertEqual(pending.take(), .networkChange)
        XCTAssertFalse(pending.isPending)
        XCTAssertNil(pending.take())
        // A started lookup supersedes the pending one.
        _ = pending.enqueue(at: now.addingTimeInterval(5), urgency: .followUp)
        XCTAssertEqual(pending.supersede(), now.addingTimeInterval(5))
        XCTAssertFalse(pending.isPending)
        XCTAssertNil(pending.supersede())
    }

    func testLookupBudgetSkipsRoutineChecksWhileResultIsFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        let fresh = now.addingTimeInterval(-30)
        XCTAssertEqual(budget.admit(.routine, lastSuccess: fresh, now: now), .skip(reason: "fresh"))
        XCTAssertEqual(budget.admit(.networkChange, lastSuccess: fresh, now: now), .proceed)
        let stale = now.addingTimeInterval(-LookupBudget.routineFreshness - 1)
        XCTAssertEqual(budget.admit(.routine, lastSuccess: stale, now: now), .proceed)
    }

    func testLookupBudgetEnforcesPerProviderDailyBudgetAndResetsAtUTCMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9)))
        var budget = LookupBudget(now: morning)
        XCTAssertEqual(LookupBudget.dailyBudget(for: .ipapiIs), 80)
        XCTAssertEqual(LookupBudget.dailyBudget(for: .ipWhois), 800)
        XCTAssertNil(LookupBudget.dailyBudget(for: .ipinfoLite))
        for _ in 0..<79 { budget.recordCall(to: .ipapiIs, now: morning) }
        XCTAssertFalse(budget.isExhausted(.ipapiIs, now: morning))
        budget.recordCall(to: .ipapiIs, now: morning)
        XCTAssertTrue(budget.isExhausted(.ipapiIs, now: morning))
        XCTAssertFalse(budget.isExhausted(.ipWhois, now: morning))
        for _ in 0..<10_000 { budget.recordCall(to: .ipinfoLite, now: morning) }
        XCTAssertFalse(budget.isExhausted(.ipinfoLite, now: morning))

        let reset = LookupBudget.budgetResetDate(after: morning)
        XCTAssertEqual(reset, calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        XCTAssertFalse(budget.isExhausted(.ipapiIs, now: reset))
        XCTAssertEqual(budget.callsToday(for: .ipapiIs, now: reset), 0)
    }

    func testLookupBudgetStoreRoundTrip() throws {
        let suiteName = "ExitIPSharedTests.budget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LookupBudgetStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = store.load(now: now)
        XCTAssertEqual(budget.tokens, LookupBudget.burstCapacity)
        _ = budget.admit(.networkChange, lastSuccess: nil, now: now)
        budget.recordCall(to: .ipWhois, now: now)
        store.save(budget)
        let reloaded = store.load(now: now)
        XCTAssertEqual(reloaded, budget)
        XCTAssertEqual(reloaded.callsToday(for: .ipWhois, now: now), 1)
    }

    func testProviderRefusalsPauseTheProviderWithoutFailover() {
        XCTAssertTrue(LookupError.rateLimited(retryAfter: nil).pausesProvider)
        XCTAssertTrue(LookupError.httpStatus(401, retryAfter: nil).pausesProvider)
        XCTAssertTrue(LookupError.httpStatus(403, retryAfter: nil).pausesProvider)
        XCTAssertTrue(LookupError.httpStatus(402, retryAfter: nil).pausesProvider)
        XCTAssertTrue(LookupError.providerMessage("RateLimited").pausesProvider)
        XCTAssertTrue(LookupError.providerMessage("You've hit the monthly limit").pausesProvider)
        XCTAssertTrue(LookupError.providerMessage("Quota exceeded").pausesProvider)
        XCTAssertFalse(LookupError.providerMessage("Reserved IP Address").pausesProvider)
        XCTAssertFalse(LookupError.httpStatus(503, retryAfter: nil).pausesProvider)
        XCTAssertFalse(LookupError.transport("offline").pausesProvider)
        for error in [LookupError.rateLimited(retryAfter: nil), .httpStatus(403, retryAfter: nil), .providerMessage("RateLimited")] {
            XCTAssertFalse(error.supportsResilienceRetry, "\(error) must never fail over")
        }
    }

    func testSnapshotStoreRoundTrip() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SnapshotStore(defaults: defaults)
        let value = snapshot(countryCode: "JP", countryName: "Japan")

        store.save(value)
        XCTAssertEqual(store.load(), value)

        store.clear()
        XCTAssertNil(store.load())
        defaults.removePersistentDomain(forName: suite)
    }

    func testProviderCooldownStoreRoundTrip() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ProviderCooldownStore(defaults: defaults)
        let retryAt = Date(timeIntervalSince1970: 2_000)

        store.save(retryNotBefore: retryAt, for: .ipapiCo)
        XCTAssertEqual(store.retryNotBefore(for: .ipapiCo), retryAt)
        XCTAssertNil(store.retryNotBefore(for: .ipWhois))

        store.clear(for: .ipapiCo)
        XCTAssertNil(store.retryNotBefore(for: .ipapiCo))
        defaults.removePersistentDomain(forName: suite)
    }

    func testRefreshAttemptStoreTracksEachProviderSeparately() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RefreshAttemptStore(defaults: defaults)
        let attempt = Date(timeIntervalSince1970: 2_000)
        defaults.set(attempt, forKey: ExitIPPreferenceKey.legacyLastRefreshAttempt)

        store.recordAttempt(for: .ipapiCo, at: attempt)
        store.recordAttempt(for: .ipWhois, at: attempt.addingTimeInterval(1))
        XCTAssertEqual(store.lastAttempt(for: .ipapiCo), attempt)
        XCTAssertEqual(store.lastAttempt(for: .ipWhois), attempt.addingTimeInterval(1))
        XCTAssertNil(store.lastAttempt(for: .ipapiIs))
        XCTAssertEqual(store.lastAttempts(), [.ipapiCo: attempt, .ipWhois: attempt.addingTimeInterval(1)])

        // Persisted per-provider gap survives a new store instance (e.g. an app relaunch).
        XCTAssertEqual(
            RefreshPolicy.providerSelection(
                pool: [.ipapiCo, .ipWhois],
                preferred: .ipapiCo,
                lastAttempts: RefreshAttemptStore(defaults: defaults).lastAttempts(),
                at: attempt.addingTimeInterval(2)
            ),
            .waitUntil(attempt.addingTimeInterval(5))
        )

        store.clear()
        XCTAssertTrue(store.lastAttempts().isEmpty)
        XCTAssertNil(defaults.object(forKey: ExitIPPreferenceKey.legacyLastRefreshAttempt))
        defaults.removePersistentDomain(forName: suite)
    }

    func testHighlightPreferenceRoundTrip() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = MonitoringPreferences(
            provider: .ipinfoLite,
            refreshInterval: .thirtyMinutes,
            menuBarDisplayStyle: .flagAndName,
            highlightCountryChanges: false
        )

        preferences.save(to: defaults)
        XCTAssertEqual(MonitoringPreferences.load(from: defaults), preferences)
        defaults.removePersistentDomain(forName: suite)
    }

    func testProviderPoolAndIndicatorStateRoundTrip() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = MonitoringPreferences(
            provider: .ipapiIs,
            providerPool: [.ipapiCo, .ipapiIs],
            refreshInterval: .fifteenMinutes,
            menuBarDisplayStyle: .flag,
            highlightCountryChanges: true
        )
        preferences.save(to: defaults)
        XCTAssertEqual(MonitoringPreferences.load(from: defaults), preferences)

        let indicators = IndicatorStore(defaults: defaults)
        indicators.save(MonitorIndicatorState(errorMessage: "offline", suppressLocation: true))
        XCTAssertEqual(indicators.load(), MonitorIndicatorState(errorMessage: "offline", suppressLocation: true))
        indicators.clear()
        XCTAssertEqual(indicators.load(), MonitorIndicatorState())
        defaults.removePersistentDomain(forName: suite)
    }

    func testIpapiIsIsAvailableInProviderCatalog() {
        XCTAssertEqual(ProviderID.ipapiIs.displayName, "ipapi.is")
        XCTAssertTrue(MonitoringPreferences().providerPool.contains(.ipapiIs))
    }

    func testIpapiIsAnonymousResponseUsesCurrentFlatSchema() throws {
        let data = Data("""
        {
            "ip": "203.0.113.8",
            "country": "Canada",
            "city": "Toronto",
            "region": "Ontario",
            "timezone": "America/Toronto",
            "asn": "AS64500 Example Network",
            "company": "Example Network"
        }
        """.utf8)

        let response = try JSONDecoder().decode(IpapiIsResponse.self, from: data)

        XCTAssertEqual(response.ip, "203.0.113.8")
        XCTAssertEqual(response.country, "Canada")
        XCTAssertEqual(response.region, "Ontario")
        XCTAssertEqual(response.asn, "AS64500 Example Network")
        XCTAssertEqual(response.company, "Example Network")
    }

    func testAllowedIPListValidatesAndDeduplicatesExactAddresses() {
        let list = AllowedIPList(addresses: ["203.0.113.8", "203.0.113.8", "not-an-ip", "2001:db8::1"])

        XCTAssertEqual(list.addresses, ["203.0.113.8", "2001:db8::1"])
        XCTAssertTrue(list.contains("203.0.113.8"))
        XCTAssertTrue(list.contains("2001:0DB8:0:0:0:0:0:1"))
        XCTAssertFalse(list.contains("203.0.113.9"))
    }

    func testAllowedIPStoreRoundTrip() {
        let suite = "ExitIPSharedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = AllowedIPStore(defaults: defaults)
        let value = AllowedIPList(addresses: ["198.51.100.12"])

        store.save(value)
        XCTAssertEqual(store.load(), value)
        defaults.removePersistentDomain(forName: suite)
    }

    func testCountryCodeResolverMapsProviderCountryNames() {
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "Singapore"), "SG")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "united states"), "US")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "United States of America"), "US")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "The Netherlands"), "NL")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "Turkey"), "TR")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "Côte d’Ivoire"), "CI")
        XCTAssertEqual(CountryCodeResolver.code(forCountryName: "Cote d'Ivoire"), "CI")
        XCTAssertNil(CountryCodeResolver.code(forCountryName: "Atlantis"))
        XCTAssertNil(CountryCodeResolver.code(forCountryName: ""))
    }

    func testLocationSummaryOmitsRepeatedPlaceNames() {
        func summary(city: String?, region: String?, country: String) -> String {
            ExitIPSnapshot(
                ipAddress: "203.0.113.8",
                countryCode: "SG",
                countryName: country,
                city: city,
                region: region,
                provider: .ipWhois
            ).locationSummary
        }

        XCTAssertEqual(summary(city: "Singapore", region: "Central Singapore", country: "Singapore"), "Central Singapore, Singapore")
        XCTAssertEqual(summary(city: "Singapore", region: "Singapore", country: "Singapore"), "Singapore")
        XCTAssertEqual(summary(city: "Toronto", region: "Ontario", country: "Canada"), "Toronto, Ontario, Canada")
        XCTAssertEqual(summary(city: "Tokyo", region: "tokyo", country: "Japan"), "Tokyo, Japan")
        XCTAssertEqual(summary(city: nil, region: " ", country: "Japan"), "Japan")
    }

    func testPlaceholderCountryCodeShowsGlobeAndNeverCreatesCountryChange() {
        let placeholder = snapshot(countryCode: "--", countryName: "Singapore")
        let singapore = snapshot(countryCode: "SG", countryName: "Singapore")

        XCTAssertFalse(placeholder.hasValidCountryCode)
        XCTAssertEqual(placeholder.countryFlag, "🌐")
        XCTAssertEqual(singapore.countryFlag, "🇸🇬")
        XCTAssertNil(CountryChangeDetector.applyingCountryChange(to: singapore, previous: placeholder).countryChange)
        XCTAssertNil(CountryChangeDetector.applyingCountryChange(to: placeholder, previous: singapore).countryChange)
    }

    func testIpapiIsLookupResolvesCountryCodeFromName() async throws {
        let session = StubURLProtocol.session(body: """
        {"ip":"203.0.113.8","is_bogon":false,"company":"Cloud Service","asn":"AS64500 Example Network",
         "city":"Singapore","region":"Singapore","country":"Singapore","lat":1.29,"lon":103.85,
         "timezone":"Asia/Singapore","docs":"https://ipapi.is/free-tier.html"}
        """)

        let result = try await IpapiIsProvider(session: session).lookup(ipinfoToken: nil)

        XCTAssertEqual(result.countryCode, "SG")
        XCTAssertEqual(result.countryName, "Singapore")
        XCTAssertEqual(result.autonomousSystem, "AS64500 Example Network")
        XCTAssertEqual(result.organization, "Cloud Service")
    }

    func testIpapiIsLookupRejectsUnresolvableCountryInsteadOfStoringPlaceholder() async {
        let session = StubURLProtocol.session(body: #"{"ip":"203.0.113.8","country":"Atlantis"}"#)

        do {
            _ = try await IpapiIsProvider(session: session).lookup(ipinfoToken: nil)
            XCTFail("An unknown country name must not produce a snapshot.")
        } catch {
            XCTAssertEqual(error as? LookupError, .invalidResponse)
        }
    }

    // MARK: IPinfo without a token

    func testRotationSkipsIPinfoWithoutTokenLikeAPausedProvider() {
        // The monitor excludes IPinfo Lite while no token is stored, so the lookup runs on the next pool
        // provider instead of failing with a missing-token error that would hide the location.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        let decision = RefreshGate.decide(
            urgency: .networkChange,
            pool: [.ipinfoLite, .ipapiCo, .ipWhois],
            preferred: .ipinfoLite,
            lastAttempts: [:],
            excluded: [.ipinfoLite],
            budget: &budget,
            lastSuccess: nil,
            now: now
        )
        XCTAssertEqual(decision, .run(provider: .ipapiCo, rotatedFrom: .ipinfoLite))
        XCTAssertEqual(budget.callsToday(for: .ipinfoLite, now: now), 0)
    }

    // MARK: Log redaction

    func testLogRedactionRemovesIPAddresses() {
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "203.0.113.8"), "<redacted-ip>")
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "2001:0db8:85a3:0000:0000:8a2e:0370:7334"), "<redacted-ip>")
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "2001:db8::1"), "<redacted-ip>")
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "::1"), "<redacted-ip>")
        XCTAssertEqual(
            LogRedactor.redactIPAddresses(in: "Exit IP 198.51.100.7 is not on the allowlist (was 2001:db8::2)."),
            "Exit IP <redacted-ip> is not on the allowlist (was <redacted-ip>)."
        )
    }

    func testLogRedactionKeepsClockTimes() {
        // Field values such as notBefore/resumeAt are ISO timestamps; `HH:MM:SS` must survive redaction.
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "2026-10-03T12:53:52Z"), "2026-10-03T12:53:52Z")
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "paused until 13:53"), "paused until 13:53")
        XCTAssertEqual(
            LogRedactor.redactIPAddresses(in: "203.0.113.8 at 2026-10-03T12:53:52Z"),
            "<redacted-ip> at 2026-10-03T12:53:52Z"
        )
        XCTAssertEqual(LogRedactor.redactIPAddresses(in: "999.1.1.1"), "999.1.1.1")
    }
}

/// Serves a fixed JSON body so provider parsing can be tested without network access.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var body = Data()

    static func session(body: String) -> URLSession {
        Self.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
