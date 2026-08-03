import Foundation
import AIUsageMeterCore

class AnthropicClient: BaseAPIClient, AIServiceAPI {
    private let oauthUsageURL = "https://api.anthropic.com/api/oauth/usage"
    private let allowKeychainInteraction: Bool
    /// When set, this client reports one specific account instead of whatever
    /// credentials happen to be active on the machine.
    private let account: ProviderAccount?

    override init(config: ServiceConfig) {
        self.allowKeychainInteraction = true
        self.account = nil
        super.init(config: config)
    }

    init(config: ServiceConfig, allowKeychainInteraction: Bool, account: ProviderAccount? = nil) {
        self.allowKeychainInteraction = allowKeychainInteraction
        self.account = account
        super.init(config: config)
    }

    // MARK: - OAuth Usage Response Models

    private struct OAuthUsageResponse: Codable {
        let fiveHour: UsageWindowPayload?
        let sevenDay: UsageWindowPayload?
        let sevenDayOpus: UsageWindowPayload?
        let sevenDaySonnet: UsageWindowPayload?
        let sevenDayOAuthApps: UsageWindowPayload?
        let extraUsage: ExtraUsage?
        /// Self-describing list of every active quota window. Preferred over the
        /// fixed fields above: Anthropic adds windows over time (a per-model
        /// weekly cap for Fable, for instance) and only this list names them.
        let limits: [LimitEntry]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case sevenDayOAuthApps = "seven_day_oauth_apps"
            case extraUsage = "extra_usage"
            case limits
        }
    }

    private struct LimitEntry: Codable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: LimitScope?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
        }
    }

    private struct LimitScope: Codable {
        let model: LimitScopeModel?
    }

    private struct LimitScopeModel: Codable {
        let id: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    private struct UsageWindowPayload: Codable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct ExtraUsage: Codable {
        let monthlyLimitCents: Int?
        let creditsUsedCents: Int?

        enum CodingKeys: String, CodingKey {
            case monthlyLimitCents = "monthly_limit_cents"
            case creditsUsedCents = "credits_used_cents"
        }
    }

    // MARK: - AIServiceAPI

    func fetchUsage() async throws -> UsageData {
        if let account {
            return try await fetchUsage(for: account)
        }
        if var credentials = KeychainManager.shared.getClaudeCodeCredentials(allowInteraction: allowKeychainInteraction) {
            if credentials.isExpired || credentials.willExpireSoon {
                print("🔄 Token expired or expiring soon, attempting refresh...")
                do {
                    credentials = try await KeychainManager.shared.refreshClaudeCodeToken(allowInteraction: allowKeychainInteraction)
                    print("✅ Token refreshed automatically")
                } catch {
                    print("⚠️ Auto-refresh failed: \(error.localizedDescription)")
                    // Try with the existing token anyway — some tokens work past their stated expiry
                    do {
                        return try await fetchOAuthUsage(accessToken: credentials.accessToken, tier: credentials.rateLimitTier)
                    } catch {
                        print("⚠️ Expired token also failed: \(error.localizedDescription)")
                    }
                    KeychainManager.shared.clearCredentialsCache()
                    throw APIError.httpError(
                        statusCode: 401,
                        message: "토큰이 만료되었습니다. 터미널에서 'claude'를 실행해주세요."
                    )
                }
            }

            do {
                return try await fetchOAuthUsage(accessToken: credentials.accessToken, tier: credentials.rateLimitTier)
            } catch let oauthError as APIError {
                switch oauthError {
                case .unauthorized:
                    print("🔄 OAuth 401 → trying token refresh...")
                case .httpError(let code, _) where code == 403:
                    print("🔄 OAuth 403 (scope issue) → trying token refresh...")
                default:
                    throw oauthError
                }

                do {
                    let refreshed = try await KeychainManager.shared.refreshClaudeCodeToken(allowInteraction: allowKeychainInteraction)
                    return try await fetchOAuthUsage(accessToken: refreshed.accessToken, tier: refreshed.rateLimitTier)
                } catch {
                    print("⚠️ Token refresh failed: \(error.localizedDescription)")
                }

                KeychainManager.shared.clearCredentialsCache()
                throw APIError.httpError(
                    statusCode: 401,
                    message: "토큰이 만료되었습니다. 터미널에서 'claude'를 실행해주세요."
                )
            }
        }

        if !config.apiKey.isEmpty {
            let localUsage = getLocalUsage()
            return convertToUsageData(localUsage: localUsage, tier: "Local Tracking")
        }

        throw APIError.missingAPIKey
    }

    // MARK: - Per-account usage

    /// Reports one specific account, **read-only**.
    ///
    /// Two deliberate omissions, both about not damaging credentials we don't own:
    ///
    /// 1. No refresh. Claude and Codex OAuth use *rotating* refresh tokens: a
    ///    refresh consumes the old token and issues a new one. If this monitor
    ///    refreshed an account owned by Claude Code or a launcher, that app would
    ///    be left holding a dead refresh token and the user would be silently
    ///    logged out of an account they actually work in. A read-only monitor must
    ///    never take that risk — whichever app owns the login keeps it fresh, and
    ///    we report what we can read.
    /// 2. No pre-emptive refresh on `expiresAt` either. That timestamp isn't
    ///    authoritative for `/api/oauth/usage`; credentials keep authenticating
    ///    there past their nominal expiry, so acting on it would only invent work.
    private func fetchUsage(for account: ProviderAccount) async throws -> UsageData {
        let store = await AccountCredentialStore.shared
        guard let raw = await store.rawCredentials(for: account, allowImport: allowKeychainInteraction),
              let credentials = ClaudeTokenRefresher.decode(raw) else {
            let needsImport = await store.needsImport(account)
            throw APIError.httpError(
                statusCode: 401,
                message: needsImport
                    ? "\(account.label): 키체인 접근을 한 번 허용해 주세요 (새로고침)"
                    : "\(account.label): 자격증명을 찾을 수 없습니다"
            )
        }

        do {
            return try await fetchOAuthUsage(accessToken: credentials.accessToken,
                                             tier: credentials.rateLimitTier)
        } catch let error as APIError {
            switch error {
            case .unauthorized, .httpError(401, _), .httpError(403, _):
                // A login this app created has no other owner, so renewing it is
                // both safe and the only thing that can renew it: no CLI ever runs
                // in that config home, so the token would otherwise stay dead.
                if account.isSelfManaged,
                   let renewed = try? await renew(credentials, for: account) {
                    return try await fetchOAuthUsage(accessToken: renewed.accessToken,
                                                     tier: renewed.rateLimitTier)
                }
                throw APIError.httpError(
                    statusCode: 401,
                    message: account.isSelfManaged
                        ? "\(account.label): 로그인이 만료되었습니다 — 다시 로그인해 주세요"
                        : "\(account.label): 토큰이 만료됨 — 해당 계정을 한 번 사용하면 자동 복구됩니다"
                )
            default:
                throw error
            }
        }
    }

    /// Refreshes a self-owned login and keeps the result.
    private func renew(_ credentials: ClaudeCodeCredentials,
                       for account: ProviderAccount) async throws -> ClaudeCodeCredentials {
        let renewed = try await ClaudeTokenRefresher.refresh(credentials)
        // Store before use: a rotating refresh token that is spent but not saved
        // locks the account out for good.
        if let json = ClaudeTokenRefresher.encode(renewed) {
            await AccountCredentialStore.shared.store(json, for: account)
        }
        return renewed
    }

    // MARK: - OAuth API

    private func fetchOAuthUsage(accessToken: String, tier: String?, retryCount: Int = 0) async throws -> UsageData {
        guard let url = URL(string: oauthUsageURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AIUsageMeter/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                guard retryCount < 2 else {
                    throw APIError.rateLimitExceeded(resetDate: nil)
                }
                let raw = parseRetryAfter(from: httpResponse) ?? 10
                let retryAfter = max(5, min(raw, 30))  // minimum 5s, maximum 30s
                print("⏳ Rate limited, retrying after \(retryAfter)s (attempt \(retryCount + 1)/2)...")
                try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                return try await fetchOAuthUsage(accessToken: accessToken, tier: tier, retryCount: retryCount + 1)
            }
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            if httpResponse.statusCode == 403 {
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("scope") || body.contains("permission") {
                    throw APIError.httpError(
                        statusCode: 403,
                        message: "토큰에 usage 조회 권한이 없습니다. 터미널에서 'claude /logout' 후 'claude'를 실행해주세요."
                    )
                }
                if body.contains("revoked") {
                    throw APIError.httpError(
                        statusCode: 403,
                        message: "토큰이 만료되었습니다. 터미널에서 'claude'를 실행해주세요."
                    )
                }
                throw APIError.unauthorized
            }
            let message = String(data: data, encoding: .utf8)
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        let usageResponse = try decoder.decode(OAuthUsageResponse.self, from: data)

        return convertOAuthToUsageData(response: usageResponse, tier: tier)
    }

    private func convertOAuthToUsageData(response: OAuthUsageResponse, tier: String?) -> UsageData {
        let now = Date()
        let calendar = Calendar.current

        // Use 5-hour window as primary, fall back to 7-day
        let primaryWindow = response.fiveHour ?? response.sevenDay
        let usagePercentage = primaryWindow?.utilization ?? 0

        let formatter = ISO8601DateFormatter()

        // Parse 5-hour reset date
        var resetDate: Date? = nil
        if let resetsAt = response.fiveHour?.resetsAt {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetDate = formatter.date(from: resetsAt)
            if resetDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resetDate = formatter.date(from: resetsAt)
            }
        }

        // Parse 7-day reset date
        var sevenDayResetDate: Date? = nil
        if let resetsAt = response.sevenDay?.resetsAt {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sevenDayResetDate = formatter.date(from: resetsAt)
            if sevenDayResetDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                sevenDayResetDate = formatter.date(from: resetsAt)
            }
        }

        // Calculate period
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth)!

        // Estimate tokens from usage percentage (rough estimate based on typical limits)
        let estimatedLimit: Int64 = 1_000_000 // 1M tokens as baseline
        let tokensUsed = Int64(Double(estimatedLimit) * (usagePercentage / 100.0))

        // Calculate cost from extra usage if available
        var currentCost: Decimal = 0
        if let extraUsage = response.extraUsage,
           let creditsUsed = extraUsage.creditsUsedCents {
            currentCost = Decimal(creditsUsed) / 100 // Convert cents to dollars
        }

        // Determine tier name (tier can be like "default_claude_max_5x")
        let tierName: String
        if let t = tier?.lowercased() {
            if t.contains("max") {
                tierName = "Claude Max"
            } else if t.contains("pro") {
                tierName = "Claude Pro"
            } else if t.contains("team") {
                tierName = "Claude Team"
            } else if t.contains("enterprise") {
                tierName = "Claude Enterprise"
            } else if t.contains("free") {
                tierName = "Claude Free"
            } else {
                tierName = tier ?? "Claude"
            }
        } else {
            tierName = "Claude Pro"
        }

        return UsageData(
            tokensUsed: tokensUsed,
            tokensLimit: estimatedLimit,
            inputTokens: nil,
            outputTokens: nil,
            periodStart: startOfMonth,
            periodEnd: endOfMonth,
            resetDate: resetDate ?? endOfMonth,
            sevenDayResetDate: sevenDayResetDate,
            currentCost: currentCost,
            projectedCost: nil,
            currency: "USD",
            tier: tierName,
            lastUpdated: now,
            fiveHourUsage: response.fiveHour?.utilization,
            sevenDayUsage: response.sevenDay?.utilization,
            windows: Self.windows(from: response, formatter: formatter)
        )
    }

    /// Turns the reported limits into display windows. Uses the `limits` list
    /// when present so per-model caps (Fable and whatever follows it) show up
    /// automatically; falls back to the two legacy fields otherwise.
    private static func windows(from response: OAuthUsageResponse,
                                formatter: ISO8601DateFormatter) -> [UsageWindow] {
        func parseDate(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }

        if let limits = response.limits, !limits.isEmpty {
            return limits.compactMap { entry in
                guard let percent = entry.percent else { return nil }
                let label: String
                switch entry.kind {
                case "session": label = "5h"
                case "weekly_all": label = "7d"
                default:
                    // A scoped cap names the model it applies to.
                    label = entry.scope?.model?.displayName
                        ?? entry.scope?.model?.id
                        ?? (entry.group == "weekly" ? "7d" : entry.kind ?? "?")
                }
                return UsageWindow(
                    label: label,
                    percent: percent,
                    resetsAt: parseDate(entry.resetsAt),
                    isCritical: entry.severity == "critical" || percent >= 100
                )
            }
        }

        var fallback: [UsageWindow] = []
        if let five = response.fiveHour?.utilization {
            fallback.append(UsageWindow(label: "5h", percent: five,
                                        resetsAt: parseDate(response.fiveHour?.resetsAt),
                                        isCritical: five >= 100))
        }
        if let seven = response.sevenDay?.utilization {
            fallback.append(UsageWindow(label: "7d", percent: seven,
                                        resetsAt: parseDate(response.sevenDay?.resetsAt),
                                        isCritical: seven >= 100))
        }
        return fallback
    }

    // MARK: - Local Tracking (Fallback)

    private func parseRetryAfter(from response: HTTPURLResponse) -> Int? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(retryAfter) {
            return seconds
        }
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after"),
           let seconds = Int(retryAfter) {
            return seconds
        }
        return nil
    }

    private func getLocalUsage() -> (input: Int, output: Int, limit: Int) {
        let key = "anthropic_usage_\(config.id)"
        let usage = AppDefaults.userDefaults.dictionary(forKey: key) ?? [:]

        let input = usage["inputTokens"] as? Int ?? 0
        let output = usage["outputTokens"] as? Int ?? 0
        let limit = usage["tokensLimit"] as? Int ?? 100_000

        return (input, output, limit)
    }

    private func convertToUsageData(localUsage: (input: Int, output: Int, limit: Int), tier: String) -> UsageData {
        let now = Date()
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth)!

        let tokensUsed = Int64(localUsage.input + localUsage.output)
        let tokensLimit = Int64(localUsage.limit)

        // Claude pricing (average): $3 per 1M input, $15 per 1M output
        let inputCost = Decimal(localUsage.input) * Decimal(3) / Decimal(1_000_000)
        let outputCost = Decimal(localUsage.output) * Decimal(15) / Decimal(1_000_000)
        let currentCost = inputCost + outputCost

        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let currentDay = calendar.component(.day, from: now)
        let projectedCost = currentCost * Decimal(Double(daysInMonth) / Double(max(currentDay, 1)))

        return UsageData(
            tokensUsed: tokensUsed,
            tokensLimit: tokensLimit,
            inputTokens: Int64(localUsage.input),
            outputTokens: Int64(localUsage.output),
            periodStart: startOfMonth,
            periodEnd: endOfMonth,
            resetDate: endOfMonth,
            sevenDayResetDate: nil,
            currentCost: currentCost,
            projectedCost: projectedCost,
            currency: "USD",
            tier: tier,
            lastUpdated: now,
            fiveHourUsage: nil,
            sevenDayUsage: nil
        )
    }
}
