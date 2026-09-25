import Foundation
import AIUsageMeterCore

/// One plan on the board — a person's quota in one org or workspace — shown
/// through the healthiest login into it.
@MainActor
struct PlanRow: Identifiable {
    /// The plan key when the credential proved one, else the login's own id.
    let id: String
    let login: ServiceViewModel
    /// Other logins into the same plan, folded into this row.
    let otherLogins: [ServiceViewModel]

    var extraLogins: Int { otherLogins.count }

    var service: ServiceType { login.config.serviceType }
    var identity: PlanIdentity? { login.usage.plan }

    /// Live numbers the advisor may act on.
    var isLive: Bool {
        login.hasLoaded && login.lastError == nil && !login.usage.windows.isEmpty
    }

    var quota: PlanQuota {
        PlanQuota(
            id: id,
            service: service,
            limits: login.usage.windows.map(\.quotaLimit),
            limitReached: login.usage.limitReached,
            isLive: isLive
        )
    }
}

/// A ChatGPT workspace a login can act in but has no login of its own, so its
/// limits can't be read yet.
struct UnconnectedWorkspace: Identifiable {
    let workspace: ChatGPTWorkspace
    let personKey: String
    let email: String?

    var id: String { "\(personKey)|\(workspace.id)" }
}

extension AppState {

    /// Plans in stable order — providers, then discovery order — so rows don't
    /// jump around as numbers change. Logins proven to share a plan collapse
    /// into one row.
    var planRows: [PlanRow] {
        let logins = services.filter { $0.config.isEnabled && $0.config.serviceType != .gemini }

        var order: [String] = []
        var groups: [String: [ServiceViewModel]] = [:]
        for login in logins {
            let key = Self.planKey(of: login).map { "\(login.config.serviceType.rawValue):\($0)" }
                ?? login.id.uuidString
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(login)
        }

        let rows = order.map { key -> PlanRow in
            let members = groups[key]!
            let best = members.max { Self.health(of: $0) < Self.health(of: $1) }!
            return PlanRow(id: key, login: best, otherLogins: members.filter { $0.id != best.id })
        }
        return ServiceType.allCases.flatMap { type in rows.filter { $0.service == type } }
    }

    /// Workspaces reachable from a connected login that have no login yet.
    var unconnectedWorkspaces: [UnconnectedWorkspace] {
        let rows = planRows
        let connected = Set(rows.compactMap { Self.planKey(of: $0.login) })
        let dismissed = AccountRegistry.shared.dismissedWorkspaces

        var seen = Set<String>()
        var result: [UnconnectedWorkspace] = []
        for row in rows where row.service == .codex {
            guard let person = row.identity?.personKey ?? row.login.account?.personKey else { continue }
            for workspace in row.login.usage.workspaces {
                let key = "\(person)|\(workspace.id)"
                guard !connected.contains(key), !dismissed.contains(workspace.id),
                      seen.insert(key).inserted else { continue }
                result.append(UnconnectedWorkspace(workspace: workspace, personKey: person,
                                                   email: row.identity?.email))
            }
        }
        return result
    }

    /// Re-runs the advisor. Cheap; called after every refresh and on a timer so
    /// a reset passing between refreshes is noticed.
    func updateAdvice(now: Date = Date()) {
        let advice = PlanAdvisor.recommend(planRows.map(\.quota), now: now, previous: previousPicks)
        let picksChanged = advice.mapValues(\.useNow) != recommendations.mapValues(\.useNow)
        recommendations = advice
        for (service, recommendation) in advice {
            if let pick = recommendation.useNow { previousPicks[service] = pick }
        }
        if picksChanged { menuBarNeedsRedraw += 1 }
    }

    /// The plan a provider is being used on now: the one whose usage rose most
    /// recently (within three hours), else the login the CLI itself uses.
    func inUseRow(for service: ServiceType, in rows: [PlanRow]? = nil) -> PlanRow? {
        let candidates = (rows ?? planRows).filter { $0.service == service }
        let now = Date()
        let burning = candidates
            .compactMap { row -> (PlanRow, Date)? in
                let latest = ([row.login] + row.otherLogins).compactMap(\.lastIncreaseAt).max()
                guard let latest, now.timeIntervalSince(latest) < 3 * 3600 else { return nil }
                return (row, latest)
            }
            .max { $0.1 < $1.1 }
        if let burning { return burning.0 }
        return candidates.first { row in
            ([row.login] + row.otherLogins).contains { $0.account?.isDefault == true }
        }
    }

    /// The login the menu bar shows for a provider: the user's pinned choice,
    /// else the plan in use, else the plan to use now, else the one closest to
    /// its limit.
    func menuBarRepresentative(for service: ServiceType) -> ServiceViewModel? {
        let logins = services.filter { $0.config.isEnabled && $0.config.serviceType == service }
        if let pinned = logins.first(where: { $0.account.map(AccountRegistry.shared.isPinned) == true }) {
            return pinned
        }
        if let inUse = inUseRow(for: service) {
            return inUse.login
        }
        if let pick = recommendations[service]?.useNow,
           let row = planRows.first(where: { $0.id == pick }) {
            return row.login
        }
        return logins.max { Self.pressure(of: $0) < Self.pressure(of: $1) }
    }

    // MARK: - Helpers

    /// Evidence of which plan a login draws from: the API's answer once it has
    /// loaded, else — for Codex — the token's own claims.
    static func planKey(of login: ServiceViewModel) -> String? {
        if login.hasLoaded, let key = login.usage.plan?.key { return key }
        if let key = login.account?.evidenceKey { return key }
        // A login this app created keeps its identity file in its own config
        // home, written by the CLI together with the credential. When neither
        // of two such logins can be read, that is still enough to show one
        // plan instead of two identical broken rows.
        if let account = login.account, account.isSelfManaged { return account.declaredPlanKey }
        return nil
    }

    static func isHealthy(_ login: ServiceViewModel) -> Bool {
        login.hasLoaded && login.lastError == nil
    }

    /// Orders logins into one plan: working beats failing, fresh beats stale,
    /// and the CLI's own login wins a tie.
    private static func health(of login: ServiceViewModel) -> (Int, Date, Int) {
        let working = login.hasLoaded && login.lastError == nil ? 1 : 0
        let updated = login.hasLoaded ? login.usage.lastUpdated : .distantPast
        return (working, updated, login.account?.isDefault == true ? 1 : 0)
    }

    private static func pressure(of login: ServiceViewModel) -> Double {
        max(login.fiveHourUsage ?? login.usagePercentage, login.sevenDayUsage ?? 0)
    }
}
