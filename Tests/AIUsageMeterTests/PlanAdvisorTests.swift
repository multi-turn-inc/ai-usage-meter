import XCTest
@testable import AIUsageMeterCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private let week: TimeInterval = 7 * day
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ used: Double, resetsIn: TimeInterval?) -> QuotaLimit {
    QuotaLimit(kind: .session, usedPercent: used,
               resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowSeconds: 5 * hour)
}

private func weekly(_ used: Double, resetsIn: TimeInterval?) -> QuotaLimit {
    QuotaLimit(kind: .weekly, usedPercent: used,
               resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowSeconds: week)
}

private func plan(_ id: String, _ limits: [QuotaLimit], service: ServiceType = .claude,
                  limitReached: Bool = false, live: Bool = true) -> PlanQuota {
    PlanQuota(id: id, service: service, limits: limits, limitReached: limitReached, isLive: live)
}

final class PlanAdvisorTests: XCTestCase {

    // MARK: First-expiring, first-out

    // The core rule: of two plans with room, spend the one whose weekly quota
    // resets first — its remainder is the one about to be lost.
    func test_picksThePlanThatResetsFirst() {
        let plans = [
            plan("max", [session(10, resetsIn: 3 * hour), weekly(20, resetsIn: 5 * day)]),
            plan("team", [session(40, resetsIn: 2 * hour), weekly(70, resetsIn: 14 * hour)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)[.claude]!

        XCTAssertEqual(advice.useNow, "team")
        XCTAssertEqual(advice.reason, .expiresFirst)
        XCTAssertEqual(advice.then, "max")
        XCTAssertEqual(advice.handoff, .next)
        XCTAssertNil(advice.thenFreesAt)
    }

    // What comes next follows the same rule. A seat waiting out its 5-hour
    // window but expiring before the big plan is next in line — it frees up
    // long before the current pick is spent.
    func test_nextInLineMayBeWaitingOnItsSession() {
        let plans = [
            plan("personal", [session(34, resetsIn: 2 * hour), weekly(22, resetsIn: 5 * day)]),
            plan("acme", [session(8, resetsIn: 4 * hour), weekly(71, resetsIn: 14 * hour)]),
            plan("studio", [session(100, resetsIn: 80 * 60), weekly(55, resetsIn: 1 * day + 2 * hour)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)[.claude]!

        XCTAssertEqual(advice.useNow, "acme")
        XCTAssertEqual(advice.then, "studio")
        XCTAssertEqual(advice.handoff, .nextWhenFree)
        XCTAssertEqual(advice.thenFreesAt, now.addingTimeInterval(80 * 60))
    }

    // Plan size doesn't enter into it: a nearly-spent plan that resets tonight
    // still goes first, because its remainder is gone tonight either way.
    func test_smallRemainderThatExpiresSoonStillGoesFirst() {
        let plans = [
            plan("big", [weekly(5, resetsIn: 6 * day)]),
            plan("small", [weekly(88, resetsIn: 5 * hour)]),
        ]

        XCTAssertEqual(PlanAdvisor.recommend(plans, now: now)[.claude]?.useNow, "small")
    }

    // MARK: Session windows gate, and the advice says when to come back

    // The plan that expires first is stuck on its 5-hour window. Use the other
    // one now, and return when the session refills — it still expires sooner.
    func test_sessionBlockedPlanBecomesTheReturnPoint() {
        let plans = [
            plan("soon", [session(100, resetsIn: 40 * 60), weekly(50, resetsIn: 1 * day)]),
            plan("later", [session(0, resetsIn: nil), weekly(30, resetsIn: 4 * day)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)[.claude]!

        XCTAssertEqual(advice.useNow, "later")
        XCTAssertEqual(advice.then, "soon")
        XCTAssertEqual(advice.handoff, .returnTo)
        XCTAssertEqual(advice.thenFreesAt, now.addingTimeInterval(40 * 60))
        XCTAssertEqual(advice.evaluations["soon"]?.availability,
                       .blocked(until: now.addingTimeInterval(40 * 60)))
    }

    // A weekly cap that is spent keeps the plan out until the weekly reset,
    // even when the session window is fresh.
    func test_exhaustedWeeklyBlocksUntilWeeklyReset() {
        let evaluation = PlanAdvisor.evaluate(
            plan("p", [session(0, resetsIn: nil), weekly(100, resetsIn: 2 * day)]), now: now)

        XCTAssertEqual(evaluation.availability, .blocked(until: now.addingTimeInterval(2 * day)))
    }

    // MARK: What doesn't block

    // A model-specific weekly cap stops one model, not the plan.
    func test_modelOnlyCapDoesNotBlock() {
        let capped = QuotaLimit(kind: .model("Opus"), usedPercent: 100,
                                resetsAt: now.addingTimeInterval(day), windowSeconds: week)
        let evaluation = PlanAdvisor.evaluate(plan("p", [weekly(30, resetsIn: 3 * day), capped]), now: now)

        XCTAssertEqual(evaluation.availability, .available)
        XCTAssertEqual(evaluation.headroom, 70)
    }

    // A reset that has already passed means the window refilled, whatever the
    // last snapshot said.
    func test_resetInThePastCountsAsRefilled() {
        let evaluation = PlanAdvisor.evaluate(
            plan("p", [session(100, resetsIn: -5 * 60), weekly(40, resetsIn: 3 * day)]), now: now)

        XCTAssertEqual(evaluation.availability, .available)
        XCTAssertEqual(evaluation.headroom, 60)
    }

    // MARK: What blocks regardless of percentages

    func test_providerRefusalBlocks() {
        let evaluation = PlanAdvisor.evaluate(
            plan("p", [weekly(30, resetsIn: 3 * day)], limitReached: true), now: now)

        XCTAssertEqual(evaluation.availability, .blocked(until: nil))
    }

    // A spend allowance gates like any other limit: 97% of credits gone leaves
    // too little to be worth starting on.
    func test_spendAllowanceGates() {
        let spend = QuotaLimit(kind: .spend, usedPercent: 97,
                               resetsAt: now.addingTimeInterval(5 * day), windowSeconds: week)
        let evaluation = PlanAdvisor.evaluate(plan("p", [weekly(32, resetsIn: 6 * day), spend]), now: now)

        XCTAssertEqual(evaluation.availability, .nearlyOut)
        XCTAssertEqual(evaluation.expiresAt, now.addingTimeInterval(5 * day),
                       "The first long window to reset is the first loss")
    }

    // MARK: Nothing useful left

    func test_allOutPointsAtLeftoverAndFirstToFree() {
        let plans = [
            plan("crumbs", [session(10, resetsIn: 2 * hour), weekly(97, resetsIn: 1 * day)]),
            plan("walled", [session(100, resetsIn: 3 * hour), weekly(40, resetsIn: 3 * day)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)[.claude]!

        XCTAssertEqual(advice.reason, .allOut)
        XCTAssertEqual(advice.useNow, "crumbs")
        XCTAssertEqual(advice.then, "walled")
        XCTAssertEqual(advice.handoff, .nextWhenFree)
        XCTAssertEqual(advice.thenFreesAt, now.addingTimeInterval(3 * hour))
    }

    func test_noLiveDataMeansNoAdvice() {
        let advice = PlanAdvisor.recommend([plan("p", [], live: false)], now: now)[.claude]!

        XCTAssertEqual(advice.reason, .noData)
        XCTAssertNil(advice.useNow)
    }

    // MARK: Windows that haven't started

    // An untouched weekly window isn't expiring at all, so it goes last.
    func test_untouchedWindowGoesLast() {
        let plans = [
            plan("fresh", [session(0, resetsIn: nil), weekly(0, resetsIn: nil)]),
            plan("running", [session(20, resetsIn: 4 * hour), weekly(60, resetsIn: 6 * day)]),
        ]

        XCTAssertEqual(PlanAdvisor.recommend(plans, now: now)[.claude]?.useNow, "running")
    }

    func test_whenNothingIsExpiring_mostRoomWins() {
        let plans = [
            plan("a", [weekly(0, resetsIn: nil)]),
            plan("b", [session(30, resetsIn: nil), weekly(0, resetsIn: nil)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)[.claude]!

        XCTAssertEqual(advice.useNow, "a")
        XCTAssertEqual(advice.reason, .mostRoom)
    }

    func test_singleCandidateSaysSo() {
        let plans = [
            plan("ok", [weekly(50, resetsIn: 2 * day)]),
            plan("out", [weekly(100, resetsIn: 1 * day)]),
        ]

        XCTAssertEqual(PlanAdvisor.recommend(plans, now: now)[.claude]?.reason, .onlyOption)
    }

    // MARK: Stickiness

    // Two plans resetting within the hour of each other are a coin toss; keep
    // the previous pick instead of flipping on every refresh.
    func test_previousPickSticksWhenTheDifferenceIsSmall() {
        let plans = [
            plan("a", [weekly(50, resetsIn: 10 * hour)]),
            plan("b", [weekly(50, resetsIn: 10 * hour + 30 * 60)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now, previous: [.claude: "b"])[.claude]!

        XCTAssertEqual(advice.useNow, "b")
    }

    func test_previousPickYieldsWhenAnotherExpiresClearlySooner() {
        let plans = [
            plan("a", [weekly(50, resetsIn: 5 * hour)]),
            plan("b", [weekly(50, resetsIn: 2 * day)]),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now, previous: [.claude: "b"])[.claude]!

        XCTAssertEqual(advice.useNow, "a")
    }

    // MARK: Providers are advised separately

    func test_eachProviderGetsItsOwnPick() {
        let plans = [
            plan("claude-1", [weekly(10, resetsIn: 2 * day)]),
            plan("gpt-1", [weekly(10, resetsIn: 1 * day)], service: .codex),
        ]

        let advice = PlanAdvisor.recommend(plans, now: now)

        XCTAssertEqual(advice[.claude]?.useNow, "claude-1")
        XCTAssertEqual(advice[.codex]?.useNow, "gpt-1")
    }

    // MARK: Pace projection

    // 10% used five days into a seven-day window: at that pace the week ends at
    // 14%, so 86% of it goes unused.
    func test_projectsUnusedShareAtReset() {
        let evaluation = PlanAdvisor.evaluate(plan("p", [weekly(10, resetsIn: 2 * day)]), now: now)

        XCTAssertEqual(evaluation.projectedUnused ?? -1, 86, accuracy: 0.001)
        XCTAssertNil(evaluation.projectedRunOut)
    }

    // 60% used three days in: 20%/day, so the remaining 40% lasts two days —
    // two days short of the reset.
    func test_projectsRunOutBeforeReset() {
        let evaluation = PlanAdvisor.evaluate(plan("p", [weekly(60, resetsIn: 4 * day)]), now: now)

        XCTAssertEqual(evaluation.projectedUnused, 0)
        XCTAssertEqual(evaluation.projectedRunOut?.timeIntervalSince(now) ?? -1, 2 * day, accuracy: 1)
    }

    // Too early in the window to call a pace.
    func test_noProjectionInTheFirstSliverOfAWindow() {
        let evaluation = PlanAdvisor.evaluate(plan("p", [weekly(3, resetsIn: week - 2 * hour)]), now: now)

        XCTAssertNil(evaluation.projectedUnused)
    }
}
