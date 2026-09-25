import Foundation

/// One limit on a plan, normalised across providers.
public struct QuotaLimit: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// A short rolling window — Claude's 5-hour session.
        case session
        /// The long window. When it resets, whatever was left of it is gone.
        case weekly
        /// A cap on one model only. Other models keep working, so it never
        /// blocks the plan.
        case model(String)
        /// A credit allowance (ChatGPT Business spend controls).
        case spend
    }

    public let kind: Kind
    /// Share used, 0–100.
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Window length when the provider reports it. Needed to know how far into
    /// the window we are, and therefore the pace so far.
    public let windowSeconds: TimeInterval?

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?, windowSeconds: TimeInterval?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// Running out of this limit stops the whole plan.
    public var gatesPlan: Bool {
        if case .model = kind { return false }
        return true
    }

    /// Holds the bulk of the plan's quota, as opposed to a short burst window.
    var isLong: Bool {
        switch kind {
        case .weekly, .spend: return true
        case .model: return false
        case .session: return (windowSeconds ?? 0) >= 86_400
        }
    }

    /// A snapshot taken before the reset still reports the old usage; past its
    /// reset time the window has in fact refilled.
    func refreshed(at now: Date) -> QuotaLimit {
        guard let resetsAt, resetsAt <= now else { return self }
        return QuotaLimit(kind: kind, usedPercent: 0, resetsAt: nil, windowSeconds: windowSeconds)
    }
}

/// One quota bucket: a person in one organisation or workspace. Two logins into
/// the same bucket are one plan.
public struct PlanQuota: Sendable, Equatable, Identifiable {
    public let id: String
    public let service: ServiceType
    public let limits: [QuotaLimit]
    /// The provider says requests are being refused right now (Codex
    /// `limit_reached`), whatever the percentages say.
    public let limitReached: Bool
    /// False when the numbers can't be trusted: not loaded yet, an auth error, a
    /// workspace that isn't connected.
    public let isLive: Bool

    public init(id: String, service: ServiceType, limits: [QuotaLimit],
                limitReached: Bool = false, isLive: Bool = true) {
        self.id = id
        self.service = service
        self.limits = limits
        self.limitReached = limitReached
        self.isLive = isLive
    }
}

public struct PlanEvaluation: Sendable, Equatable, Identifiable {

    public enum Availability: Sendable, Equatable {
        case available
        /// Some room, but too little to be worth switching to.
        case nearlyOut
        /// Out of quota; `until` is when it frees up, when the provider says.
        case blocked(until: Date?)
        /// No trustworthy numbers.
        case unknown
    }

    public let id: String
    public let availability: Availability
    /// Smallest remaining share across the limits that gate the plan.
    public let headroom: Double?
    /// Smallest remaining share across the long limits only — what is left once
    /// a short session window refills.
    public let longHeadroom: Double?
    /// When the long window resets and its unused remainder is lost. nil when no
    /// window is running, so nothing is expiring.
    public let expiresAt: Date?
    /// When a plan that is out, or nearly out, gets its room back.
    public let freesAt: Date?
    /// Share of the long window expected to be left unused at reset if usage
    /// continues at this window's average pace so far.
    public let projectedUnused: Double?
    /// When the long window runs dry at that pace, if that comes before reset.
    public let projectedRunOut: Date?

    static func unknown(_ id: String) -> PlanEvaluation {
        PlanEvaluation(id: id, availability: .unknown, headroom: nil, longHeadroom: nil,
                       expiresAt: nil, freesAt: nil, projectedUnused: nil, projectedRunOut: nil)
    }
}

public struct PlanRecommendation: Sendable, Equatable {

    public enum Reason: Sendable, Equatable {
        /// Its quota resets first, so what is left of it is lost soonest.
        case expiresFirst
        /// No plan has a running window; this one has the most room.
        case mostRoom
        /// The only plan with room right now.
        case onlyOption
        /// Every plan is out or nearly out.
        case allOut
        /// Nothing trustworthy to judge by.
        case noData
    }

    public enum Handoff: Sendable, Equatable {
        /// Next in line and usable now.
        case next
        /// Next in line once a short window refills at `thenFreesAt`.
        case nextWhenFree
        /// Expires before `useNow` but is waiting on a short window: switch
        /// back to it at `thenFreesAt`.
        case returnTo
    }

    public let service: ServiceType
    /// The plan to use now. nil when no plan has any room or data.
    public let useNow: String?
    public let reason: Reason
    /// Where to go after `useNow`, in first-expiring order.
    public let then: String?
    public let handoff: Handoff?
    /// Set when `then` is waiting on a reset rather than available now.
    public let thenFreesAt: Date?
    public let evaluations: [String: PlanEvaluation]
}

/// Decides which plan to spend first.
///
/// Quota is perishable: a window's unused remainder is lost at reset. Drawing
/// from whichever plan resets first — first-expiring, first-out — never leaves
/// less usable quota than any other order, since every unit taken from a plan
/// that expires later is a unit still available after the earlier one is gone.
/// The rule needs only reset times, not plan sizes, which is what makes it
/// comparable across a Max plan and a Team seat whose percentages mean
/// different amounts.
public enum PlanAdvisor {

    public struct Policy: Sendable {
        /// Below this much room a plan isn't worth switching to — a session
        /// started on it would stop almost immediately.
        public var minUsefulHeadroom: Double = 5
        /// Keep the previous pick unless another plan expires at least this much
        /// sooner. Stops the advice flipping between two near-identical plans on
        /// every refresh.
        public var stickiness: TimeInterval = 3600
        /// A pace measured over the first sliver of a window is noise.
        public var minElapsedFraction: Double = 0.05

        public init() {}
    }

    public static func evaluate(_ plan: PlanQuota, now: Date, policy: Policy = Policy()) -> PlanEvaluation {
        guard plan.isLive else { return .unknown(plan.id) }

        let gating = plan.limits.map { $0.refreshed(at: now) }.filter(\.gatesPlan)
        guard let headroom = gating.map(\.remainingPercent).min() else { return .unknown(plan.id) }

        let long = gating.filter(\.isLong)
        let longHeadroom = long.map(\.remainingPercent).min()

        // The first long window to reset is the first loss of unused quota. A
        // plan with no long window (session-only) expires with its session.
        let expiring = (long.isEmpty ? gating : long)
            .filter { $0.resetsAt != nil }
            .min { $0.resetsAt! < $1.resetsAt! }
        let expiresAt = expiring?.resetsAt

        var projectedUnused: Double?
        var projectedRunOut: Date?
        if let expiring, let resetsAt = expiring.resetsAt, let window = expiring.windowSeconds, window > 0 {
            let elapsed = window - resetsAt.timeIntervalSince(now)
            if elapsed >= window * policy.minElapsedFraction {
                let used = expiring.usedPercent
                let projected = used * window / elapsed
                projectedUnused = max(0, 100 - projected)
                if projected > 100, used > 0 {
                    let pacePerSecond = used / elapsed
                    let runOut = now.addingTimeInterval((100 - used) / pacePerSecond)
                    if runOut < resetsAt { projectedRunOut = runOut }
                }
            }
        }

        let exhausted = gating.filter { $0.remainingPercent <= 0 }
        let availability: PlanEvaluation.Availability
        let freesAt: Date?
        if plan.limitReached || !exhausted.isEmpty {
            // Every exhausted limit has to reset before the plan works again.
            let resets = exhausted.compactMap(\.resetsAt)
            freesAt = resets.count == exhausted.count && !exhausted.isEmpty ? resets.max() : nil
            availability = .blocked(until: freesAt)
        } else if headroom < policy.minUsefulHeadroom {
            let tightest = gating.filter { $0.remainingPercent < policy.minUsefulHeadroom }
            let resets = tightest.compactMap(\.resetsAt)
            freesAt = resets.count == tightest.count ? resets.max() : nil
            availability = .nearlyOut
        } else {
            freesAt = nil
            availability = .available
        }

        return PlanEvaluation(
            id: plan.id, availability: availability, headroom: headroom,
            longHeadroom: longHeadroom, expiresAt: expiresAt, freesAt: freesAt,
            projectedUnused: projectedUnused, projectedRunOut: projectedRunOut
        )
    }

    /// One recommendation per provider — Claude plans and ChatGPT plans run
    /// different tools, so they aren't interchangeable.
    public static func recommend(
        _ plans: [PlanQuota],
        now: Date,
        previous: [ServiceType: String] = [:],
        policy: Policy = Policy()
    ) -> [ServiceType: PlanRecommendation] {
        var result: [ServiceType: PlanRecommendation] = [:]
        for service in Set(plans.map(\.service)) {
            let group = plans.filter { $0.service == service }
            result[service] = recommend(service: service, plans: group, now: now,
                                        previous: previous[service], policy: policy)
        }
        return result
    }

    private static func recommend(
        service: ServiceType, plans: [PlanQuota], now: Date,
        previous: String?, policy: Policy
    ) -> PlanRecommendation {
        let evaluations = plans.map { evaluate($0, now: now, policy: policy) }
        let byID = Dictionary(evaluations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func expiry(_ e: PlanEvaluation) -> Date { e.expiresAt ?? .distantFuture }

        let candidates = evaluations
            .filter { $0.availability == .available }
            .sorted { lhs, rhs in
                if expiry(lhs) != expiry(rhs) { return expiry(lhs) < expiry(rhs) }
                return (lhs.headroom ?? 0) > (rhs.headroom ?? 0)
            }

        guard var pick = candidates.first else {
            return allOut(service: service, evaluations: evaluations, byID: byID)
        }

        if let previous, previous != pick.id,
           let incumbent = candidates.first(where: { $0.id == previous }),
           expiry(incumbent).timeIntervalSince(expiry(pick)) < policy.stickiness {
            pick = incumbent
        }

        let reason: PlanRecommendation.Reason
        if candidates.count == 1 {
            reason = .onlyOption
        } else if pick.expiresAt == nil {
            reason = .mostRoom
        } else {
            reason = .expiresFirst
        }

        // Plans held up only by a short window that refills before the pick
        // resets are still in the running — they just join a little later.
        let waiting = evaluations.filter { e in
            guard e.id != pick.id, e.availability != .available, let freesAt = e.freesAt else { return false }
            return (e.longHeadroom ?? 0) >= policy.minUsefulHeadroom && freesAt < expiry(pick)
        }

        let handoff: PlanRecommendation.Handoff?
        let then: PlanEvaluation?
        if let returning = waiting
            .filter({ expiry($0) < expiry(pick) })
            .min(by: { ($0.freesAt ?? .distantFuture) < ($1.freesAt ?? .distantFuture) }) {
            // It expires first; it's only out of the running until it frees.
            then = returning
            handoff = .returnTo
        } else if let upcoming = (candidates.filter { $0.id != pick.id } + waiting)
            .min(by: { expiry($0) != expiry($1) ? expiry($0) < expiry($1) : ($0.headroom ?? 0) > ($1.headroom ?? 0) }) {
            then = upcoming
            handoff = upcoming.availability == .available ? .next : .nextWhenFree
        } else {
            then = nil
            handoff = nil
        }

        return PlanRecommendation(
            service: service, useNow: pick.id, reason: reason,
            then: then?.id, handoff: handoff,
            thenFreesAt: handoff == .next ? nil : then?.freesAt, evaluations: byID
        )
    }

    /// Nothing has useful room. Point at whatever little is left, and at when
    /// room comes back.
    private static func allOut(
        service: ServiceType, evaluations: [PlanEvaluation], byID: [String: PlanEvaluation]
    ) -> PlanRecommendation {
        let judged = evaluations.filter { $0.availability != .unknown }
        guard !judged.isEmpty else {
            return PlanRecommendation(service: service, useNow: nil, reason: .noData,
                                      then: nil, handoff: nil, thenFreesAt: nil, evaluations: byID)
        }

        let leftover = judged
            .filter { $0.availability == .nearlyOut }
            .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }

        let firstFree = judged
            .filter { $0.id != leftover?.id && $0.freesAt != nil }
            .min { $0.freesAt! < $1.freesAt! }

        return PlanRecommendation(
            service: service, useNow: leftover?.id, reason: .allOut,
            then: firstFree?.id, handoff: firstFree == nil ? nil : .nextWhenFree,
            thenFreesAt: firstFree?.freesAt, evaluations: byID
        )
    }
}
