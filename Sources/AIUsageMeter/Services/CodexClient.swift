import Foundation
import AIUsageMeterCore

class CodexClient: BaseAPIClient, AIServiceAPI {
    private let codexHome: String
    /// When set, this client reports one specific workspace rather than the
    /// machine's default Codex login.
    private let account: ProviderAccount?

    override init(config: ServiceConfig) {
        // CODEX_HOME defaults to ~/.codex
        self.codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSHomeDirectory() + "/.codex"
        self.account = nil
        super.init(config: config)
    }

    init(config: ServiceConfig, account: ProviderAccount?) {
        self.account = account
        // A managed account keeps its whole CODEX_HOME beside its auth.json.
        if case .file(let path) = account?.source {
            self.codexHome = (path as NSString).deletingLastPathComponent
        } else {
            self.codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? NSHomeDirectory() + "/.codex"
        }
        super.init(config: config)
    }

    // MARK: - AIServiceAPI

    func fetchUsage() async throws -> UsageData {
        // Local rollouts are written by whichever login ~/.codex holds. They say
        // nothing about any other workspace — reading them for one showed the
        // default workspace's numbers under another workspace's name.
        let readsLocalLogs = account == nil || account?.isDefault == true
        var sessionStats = try await analyzeLocalSessions()
        if !readsLocalLogs { sessionStats.dropRateLimits() }

        var authRoot = loadAuthJSON()
        var snapshot: CodexUsageSnapshot?
        do {
            snapshot = try await fetchRemoteUsage(authRoot: authRoot)
        } catch APIError.unauthorized {
            // A login this app created has no other owner, so renewing it is
            // safe — and nothing else ever will.
            if let account, account.isSelfManaged, case .file(let path) = account.source,
               let renewed = try? await CodexTokenRefresher.renew(authFile: URL(fileURLWithPath: path)) {
                authRoot = renewed
                snapshot = try? await fetchRemoteUsage(authRoot: renewed)
            }
            if snapshot == nil, !readsLocalLogs {
                throw APIError.httpError(
                    statusCode: 401,
                    message: account?.isSelfManaged == true
                        ? "\(account?.label ?? "Codex"): 로그인이 만료되었습니다 — 다시 로그인해 주세요"
                        : "\(account?.label ?? "Codex"): 토큰이 만료됨 — 해당 계정을 한 번 사용하면 자동 복구됩니다"
                )
            }
        } catch {
            // The CLI's own login can fall back on what its rollouts recorded;
            // any other login has nothing else to go on.
            if !readsLocalLogs { throw error }
        }

        if let snapshot {
            applyRemoteRateLimits(RemoteRateLimitSnapshot(snapshot), to: &sessionStats, now: Date())
        }

        let identity = authRoot.flatMap(CodexTokenIdentity.from(authJSON:))
        var workspaces: [ChatGPTWorkspace] = []
        if let userId = identity?.userId, let token = accessToken(in: authRoot) {
            workspaces = await ChatGPTDirectoryCache.shared.workspaces(userId: userId, accessToken: token)
        }
        let workspace = workspaces.first { $0.id == identity?.workspaceId }

        var usage = UsageData(
            tokensUsed: sessionStats.totalTokens,
            tokensLimit: sessionStats.estimatedLimit,
            inputTokens: sessionStats.inputTokens,
            outputTokens: sessionStats.outputTokens,
            periodStart: sessionStats.periodStart,
            periodEnd: sessionStats.periodEnd,
            resetDate: sessionStats.resetDate,
            sevenDayResetDate: sessionStats.sevenDayResetDate,
            currentCost: sessionStats.estimatedCost,
            projectedCost: nil,
            currency: "USD",
            tier: sessionStats.tier,
            lastUpdated: Date(),
            fiveHourUsage: sessionStats.fiveHourUsagePercent,
            sevenDayUsage: sessionStats.sevenDayUsagePercent,
            windows: snapshot.map(Self.windows(from:)) ?? Self.windows(from: sessionStats)
        )
        usage.limitReached = snapshot?.limitReached ?? false
        usage.workspaces = workspaces
        usage.plan = PlanIdentity(
            key: identity?.planKey,
            personKey: identity?.userId ?? account?.personKey,
            email: identity?.email ?? account?.email,
            orgName: workspace?.displayName ?? account?.organizationName,
            planName: PlanNames.chatGPT(planType: snapshot?.planType ?? identity?.planType)
                ?? workspace?.planName ?? account?.planName
        )
        return usage
    }

    /// Windows as the backend reports them, each labelled by its real length.
    ///
    /// OpenAI changed this under us before: the primary window used to be five
    /// hours and is now weekly, with no secondary at all. The credit allowance
    /// is a separate limit and is shown as one — it can run out while most of
    /// the rate limit is left.
    private static func windows(from snapshot: CodexUsageSnapshot) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let rated = [(snapshot.primary, true), (snapshot.secondary, false)]
        for case let (window?, isPrimary) in rated {
            let seconds = window.windowSeconds
            let role: UsageWindow.Role = seconds.map { $0 >= 86_400 ? .weekly : .session }
                ?? (isPrimary && snapshot.secondary != nil ? .session : .weekly)
            windows.append(UsageWindow(
                label: seconds.map { UsageWindow.label(forSeconds: Int($0)) } ?? "—",
                percent: window.usedPercent,
                resetsAt: window.resetsAt,
                isCritical: window.usedPercent >= 100,
                role: role,
                windowSeconds: seconds
            ))
        }
        if let spend = snapshot.spend {
            windows.append(UsageWindow(
                label: "credits",
                percent: spend.usedPercent,
                resetsAt: spend.resetsAt,
                isCritical: spend.usedPercent >= 100,
                role: .spend,
                windowSeconds: spend.windowSeconds
            ))
        }
        return windows
    }

    /// Windows recovered from local rollouts, when the backend couldn't be
    /// reached. Labels come from the reported lengths; an unknown length is
    /// labelled as unknown rather than asserting "5h" over a weekly number.
    private static func windows(from stats: SessionStats) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let percent = stats.fiveHourUsagePercent {
            let minutes = stats.primaryWindowMinutes
            windows.append(UsageWindow(
                label: minutes.map { UsageWindow.label(forSeconds: $0 * 60) } ?? "—",
                percent: percent,
                resetsAt: stats.resetDate,
                isCritical: percent >= 100,
                role: (minutes ?? 0) >= 1440 ? .weekly : .session,
                windowSeconds: minutes.map { Double($0 * 60) }
            ))
        }
        if let percent = stats.sevenDayUsagePercent {
            let minutes = stats.secondaryWindowMinutes
            windows.append(UsageWindow(
                label: minutes.map { UsageWindow.label(forSeconds: $0 * 60) } ?? "—",
                percent: percent,
                resetsAt: stats.sevenDayResetDate,
                isCritical: percent >= 100,
                role: .weekly,
                windowSeconds: minutes.map { Double($0 * 60) }
            ))
        }
        return windows
    }

    // MARK: - Local Session Analysis

    private struct SessionStats {
        var totalTokens: Int64 = 0
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var messageCount: Int = 0
        var sessionCount: Int = 0
        var periodStart: Date
        var periodEnd: Date
        var resetDate: Date
        var sevenDayResetDate: Date?
        var estimatedLimit: Int64 = 225  // Default Plus limit (messages)
        var estimatedCost: Decimal = 0
        var tier: String = "Codex"
        var fiveHourUsagePercent: Double?
        var sevenDayUsagePercent: Double?
        /// Actual reported window lengths — the backend has changed these before,
        /// so labels are derived from them rather than assumed.
        var primaryWindowMinutes: Int?
        var secondaryWindowMinutes: Int?

        /// Forgets limits read from local rollouts, which belong to another login.
        mutating func dropRateLimits() {
            fiveHourUsagePercent = nil
            sevenDayUsagePercent = nil
            primaryWindowMinutes = nil
            secondaryWindowMinutes = nil
            tier = "Codex"
        }
    }

    private struct RemoteRateLimitSnapshot {
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryWindowMinutes: Int?
        var secondaryWindowMinutes: Int?
        var primaryResetTime: Date?
        var secondaryResetTime: Date?
        var planType: String?

        init(_ snapshot: CodexUsageSnapshot) {
            primaryUsedPercent = snapshot.primary?.usedPercent
            secondaryUsedPercent = snapshot.secondary?.usedPercent
            primaryWindowMinutes = snapshot.primary?.windowSeconds.map { Int($0) / 60 }
            secondaryWindowMinutes = snapshot.secondary?.windowSeconds.map { Int($0) / 60 }
            primaryResetTime = snapshot.primary?.resetsAt
            secondaryResetTime = snapshot.secondary?.resetsAt
            planType = snapshot.planType
        }
    }

    private func analyzeLocalSessions() async throws -> SessionStats {
        let now = Date()
        let calendar = Calendar.current

        // 5-hour window for usage calculation
        let fiveHoursAgo = calendar.date(byAdding: .hour, value: -5, to: now)!

        // Next reset (rolling 5-hour window)
        let nextReset = calendar.date(byAdding: .hour, value: 5, to: now)!

        // 7-day rolling window reset
        let sevenDayReset = calendar.date(byAdding: .day, value: 7, to: now)!

        var stats = SessionStats(
            periodStart: fiveHoursAgo,
            periodEnd: now,
            resetDate: nextReset,
            sevenDayResetDate: sevenDayReset
        )

        // Find session files from the last 24 hours to get recent rate_limits
        let sessionsPath = "\(codexHome)/sessions"
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sessionsPath) else {
            stats.tier = "Codex (No sessions)"
            return stats
        }

        // Per-turn deltas with replay/fork dedup (CodexSessionParser), so the 24h
        // window only counts tokens actually used inside it — summing each file's
        // session-cumulative total would leak usage from before the window.
        let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
        let parsed = CodexSessionParser.shared.parse(since: oneDayAgo)

        stats.sessionCount = parsed.sessionCount
        stats.messageCount = parsed.events.count

        var costUSD: Double = 0
        for event in parsed.events {
            stats.totalTokens += event.totalTokens
            stats.inputTokens += event.inputTokens
            stats.outputTokens += event.outputTokens
            costUSD += ModelPricing.shared.codexCost(
                model: event.model,
                input: event.inputTokens,
                cachedInput: event.cachedInputTokens,
                output: event.outputTokens
            )
        }

        let latestPrimaryPercent = parsed.rateLimits.primaryUsedPercent
        let latestSecondaryPercent = parsed.rateLimits.secondaryUsedPercent
        let latestPrimaryWindowMinutes = parsed.rateLimits.primaryWindowMinutes
        let latestSecondaryWindowMinutes = parsed.rateLimits.secondaryWindowMinutes
        let latestPrimaryResetTime = parsed.rateLimits.primaryResetTime
        let latestSecondaryResetTime = parsed.rateLimits.secondaryResetTime
        let latestPlanType = parsed.rateLimits.planType
        stats.primaryWindowMinutes = latestPrimaryWindowMinutes
        stats.secondaryWindowMinutes = latestSecondaryWindowMinutes

        if let resetTime = latestPrimaryResetTime {
            let windowMinutes = latestPrimaryWindowMinutes ?? 300
            stats.resetDate = nextResetDate(after: resetTime, windowMinutes: windowMinutes, now: now)
            if resetTime <= now {
                stats.fiveHourUsagePercent = 0
            } else {
                stats.fiveHourUsagePercent = latestPrimaryPercent
            }
        } else if let primary = latestPrimaryPercent {
            stats.fiveHourUsagePercent = primary
        }

        if let resetTime = latestSecondaryResetTime {
            let windowMinutes = latestSecondaryWindowMinutes ?? 10080
            stats.sevenDayResetDate = nextResetDate(after: resetTime, windowMinutes: windowMinutes, now: now)
            if resetTime <= now {
                stats.sevenDayUsagePercent = 0
            } else {
                stats.sevenDayUsagePercent = latestSecondaryPercent
            }
        } else if let secondary = latestSecondaryPercent {
            stats.sevenDayUsagePercent = secondary
        }

        // Determine tier from plan type or heuristics
        if let plan = latestPlanType {
            stats.tier = "Codex \(plan.capitalized)"
        } else {
            stats.tier = detectTier(messageCount: stats.messageCount)
        }

        // Set limits based on tier
        switch stats.tier.lowercased() {
        case let t where t.contains("pro"):
            stats.estimatedLimit = 1500
        default:
            stats.estimatedLimit = 225
        }

        // Fallback: calculate usage from message count if no rate_limits
        if stats.fiveHourUsagePercent == nil {
            let messageLimit = Double(stats.estimatedLimit)
            stats.fiveHourUsagePercent = min(100, Double(stats.messageCount) / messageLimit * 100)
        }

        // Real API-equivalent cost from per-event model pricing
        stats.estimatedCost = Decimal(costUSD)

        return stats
    }

    private struct CodexAuthInfo {
        let accessToken: String
        let baseURL: URL?
        /// ChatGPT workspace this token belongs to, sent as `ChatGPT-Account-Id`.
        let chatGPTAccountId: String?
    }

    /// Reads this login's usage from the backend.
    ///
    /// The token decides which workspace answers: the backend ignores a
    /// `ChatGPT-Account-Id` naming any other workspace and reports the token's
    /// own. The header is still sent because the CLI sends it.
    private func fetchRemoteUsage(authRoot: [String: Any]?) async throws -> CodexUsageSnapshot? {
        guard let authInfo = authRoot.flatMap(codexAuthInfo(from:)) else {
            return nil
        }

        let baseCandidates = buildBaseURLCandidates(authInfo: authInfo)
        var lastError: Error?

        for baseURL in baseCandidates {
            for endpoint in usageEndpointCandidates(for: baseURL) {
                do {
                    var headers = [
                        "Authorization": "Bearer \(authInfo.accessToken)",
                        "Accept": "application/json",
                        "User-Agent": "AIUsageMeter/1.0"
                    ]
                    if let workspace = authInfo.chatGPTAccountId ?? account?.chatGPTAccountId {
                        headers["ChatGPT-Account-Id"] = workspace
                    }
                    let (data, _) = try await performRequest(url: endpoint, headers: headers)

                    if let snapshot = CodexUsageSnapshot.parse(data) {
                        return snapshot
                    }
                } catch let error as APIError {
                    if case .unauthorized = error {
                        throw error
                    }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
        }

        if let error = lastError {
            throw error
        }

        return nil
    }

    private func applyRemoteRateLimits(_ snapshot: RemoteRateLimitSnapshot, to stats: inout SessionStats, now: Date) {
        // Carry the reported window lengths through. Dropping them meant the
        // labels fell back to an assumed 5h/7d pair, so a weekly window showed
        // up as "5h" with a reset six days out.
        if let minutes = snapshot.primaryWindowMinutes { stats.primaryWindowMinutes = minutes }
        if let minutes = snapshot.secondaryWindowMinutes { stats.secondaryWindowMinutes = minutes }

        if let resetTime = snapshot.primaryResetTime {
            let windowMinutes = snapshot.primaryWindowMinutes ?? stats.primaryWindowMinutes ?? 300
            stats.resetDate = nextResetDate(after: resetTime, windowMinutes: windowMinutes, now: now)
            if resetTime <= now {
                stats.fiveHourUsagePercent = 0
            } else if let percent = snapshot.primaryUsedPercent {
                stats.fiveHourUsagePercent = percent
            }
        } else if let percent = snapshot.primaryUsedPercent {
            stats.fiveHourUsagePercent = percent
        }

        if let resetTime = snapshot.secondaryResetTime {
            let windowMinutes = snapshot.secondaryWindowMinutes ?? stats.secondaryWindowMinutes ?? 10080
            stats.sevenDayResetDate = nextResetDate(after: resetTime, windowMinutes: windowMinutes, now: now)
            if resetTime <= now {
                stats.sevenDayUsagePercent = 0
            } else if let percent = snapshot.secondaryUsedPercent {
                stats.sevenDayUsagePercent = percent
            }
        } else if let percent = snapshot.secondaryUsedPercent {
            stats.sevenDayUsagePercent = percent
        }

        if let plan = snapshot.planType {
            stats.tier = "Codex \(plan.capitalized)"
        }
    }

    private func loadAuthJSON() -> [String: Any]? {
        let authPath = "\(codexHome)/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func accessToken(in json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let tokens = json["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String, !token.isEmpty {
            return token
        }
        let token = (json["access_token"] as? String)
            ?? (json["accessToken"] as? String)
            ?? (json["token"] as? String)
            ?? (json["OPENAI_API_KEY"] as? String)
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func codexAuthInfo(from json: [String: Any]) -> CodexAuthInfo? {
        guard let token = accessToken(in: json) else {
            return nil
        }

        let baseURLString = (json["api_base_url"] as? String)
            ?? (json["base_url"] as? String)
            ?? (json["baseURL"] as? String)

        let baseURL = baseURLString.flatMap { URL(string: $0) }
        let workspace = (json["tokens"] as? [String: Any])?["account_id"] as? String
        return CodexAuthInfo(accessToken: token, baseURL: baseURL, chatGPTAccountId: workspace)
    }

    /// Returns true if `url` is allowed to receive the Bearer token.
    /// Requires https and a host on the OpenAI/ChatGPT allowlist.
    private func isAllowedBaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        let allowed = ["api.openai.com", "chatgpt.com", "backend.chatgpt.com"]
        if allowed.contains(host) { return true }
        // *.openai.com subdomains
        if host.hasSuffix(".openai.com") { return true }
        return false
    }

    private func buildBaseURLCandidates(authInfo: CodexAuthInfo) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        if let baseURL = authInfo.baseURL {
            if isAllowedBaseURL(baseURL), !seen.contains(baseURL.absoluteString) {
                candidates.append(baseURL)
                seen.insert(baseURL.absoluteString)
            }
            // Non-allowed custom URLs are silently ignored; fall through to defaults.
        }

        if let configURL = loadCodexBaseURLFromConfig() {
            if isAllowedBaseURL(configURL), !seen.contains(configURL.absoluteString) {
                candidates.append(configURL)
                seen.insert(configURL.absoluteString)
            }
        }

        // chatgpt.com is the host that answers; trying api.openai.com first cost
        // two failed requests per account on every refresh.
        let defaults = ["https://chatgpt.com", "https://api.openai.com"]
        for base in defaults {
            if let url = URL(string: base), !seen.contains(url.absoluteString) {
                candidates.append(url)
                seen.insert(url.absoluteString)
            }
        }

        return candidates
    }

    private func loadCodexBaseURLFromConfig() -> URL? {
        let configPath = "\(codexHome)/config.toml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        let keys = ["api_base_url", "base_url"]
        for key in keys {
            if let value = parseTomlStringValue(content, key: key) {
                return URL(string: value)
            }
        }

        return nil
    }

    private func parseTomlStringValue(_ content: String, key: String) -> String? {
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let keyPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyPart == key else { continue }

            let valuePart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard valuePart.hasPrefix("\"") && valuePart.hasSuffix("\"") else { continue }

            return String(valuePart.dropFirst().dropLast())
        }

        return nil
    }

    private func usageEndpointCandidates(for baseURL: URL) -> [URL] {
        let isChatGPT = baseURL.host?.contains("chatgpt.com") == true || baseURL.path.contains("backend-api")
        let paths = isChatGPT
            ? ["/backend-api/wham/usage", "/api/codex/usage"]
            : ["/api/codex/usage", "/backend-api/wham/usage"]

        return paths.compactMap { buildURL(baseURL: baseURL, path: $0) }
    }

    private func buildURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = path
        components.query = nil
        return components.url
    }

    private func nextResetDate(after resetTime: Date, windowMinutes: Int, now: Date) -> Date {
        let windowSeconds = TimeInterval(windowMinutes * 60)
        guard windowSeconds > 0 else { return resetTime }
        if resetTime > now { return resetTime }

        let elapsed = now.timeIntervalSince(resetTime)
        let windowsElapsed = floor(elapsed / windowSeconds) + 1
        return resetTime.addingTimeInterval(windowsElapsed * windowSeconds)
    }

    private func detectTier(messageCount: Int) -> String {
        // Pro users typically have higher limits
        // This is a heuristic - could be improved with config file detection
        let configPath = "\(codexHome)/config.toml"
        if let config = try? String(contentsOfFile: configPath, encoding: .utf8) {
            if config.contains("pro") || config.contains("Pro") {
                return "Codex Pro"
            }
        }

        return "Codex Plus"
    }

    private func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
