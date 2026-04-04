import Foundation

class CodexClient: BaseAPIClient, AIServiceAPI {
    private let codexHome: String

    override init(config: ServiceConfig) {
        // CODEX_HOME defaults to ~/.codex
        self.codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSHomeDirectory() + "/.codex"
        super.init(config: config)
    }

    // MARK: - AIServiceAPI

    func fetchUsage() async throws -> UsageData {
        // Try to read local session logs
        var sessionStats = try await analyzeLocalSessions()

        if let remoteSnapshot = try? await fetchRemoteRateLimits() {
            applyRemoteRateLimits(remoteSnapshot, to: &sessionStats, now: Date())
        }

        return UsageData(
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
            sevenDayUsage: sessionStats.sevenDayUsagePercent
        )
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
    }

    private struct RemoteRateLimitSnapshot {
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryWindowMinutes: Int?
        var secondaryWindowMinutes: Int?
        var primaryResetTime: Date?
        var secondaryResetTime: Date?
        var planType: String?
    }

    private struct RateLimitStatusPayload: Decodable {
        let planType: String?
        let rateLimit: RateLimitContainer?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    private struct RateLimitContainer: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double?
        let resetAt: TimeInterval?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = Self.decodeDouble(from: container, forKey: .usedPercent)
            resetAt = Self.decodeDouble(from: container, forKey: .resetAt)
            limitWindowSeconds = Self.decodeInt(from: container, forKey: .limitWindowSeconds)
        }

        private static func decodeDouble(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return Double(value)
            }
            return nil
        }

        private static func decodeInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return Int(value)
            }
            return nil
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

        // Get recent session files (last 24 hours to find latest rate_limits)
        let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
        let sessionFiles = try findRecentSessionFiles(
            in: sessionsPath,
            since: oneDayAgo
        )

        stats.sessionCount = sessionFiles.count

        // Parse each session file, keeping the most recent rate_limits
        var latestPrimaryPercent: Double?
        var latestSecondaryPercent: Double?
        var latestPrimaryWindowMinutes: Int?
        var latestSecondaryWindowMinutes: Int?
        var latestPrimaryResetTime: Date?
        var latestSecondaryResetTime: Date?
        var latestPlanType: String?

        for filePath in sessionFiles {
            if let sessionData = parseSessionFile(at: filePath) {
                stats.totalTokens += sessionData.tokens
                stats.inputTokens += sessionData.inputTokens
                stats.outputTokens += sessionData.outputTokens
                stats.messageCount += sessionData.messageCount

                // Keep the most recent rate_limits data
                if let primary = sessionData.primaryUsedPercent {
                    latestPrimaryPercent = primary
                }
                if let secondary = sessionData.secondaryUsedPercent {
                    latestSecondaryPercent = secondary
                }
                if let windowMinutes = sessionData.primaryWindowMinutes {
                    latestPrimaryWindowMinutes = windowMinutes
                }
                if let windowMinutes = sessionData.secondaryWindowMinutes {
                    latestSecondaryWindowMinutes = windowMinutes
                }
                if let resetTime = sessionData.primaryResetTime {
                    latestPrimaryResetTime = resetTime
                }
                if let resetTime = sessionData.secondaryResetTime {
                    latestSecondaryResetTime = resetTime
                }
                if let plan = sessionData.planType {
                    latestPlanType = plan
                }
            }
        }

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

        // Estimate cost (~5 credits per local task, $0.01 per credit)
        stats.estimatedCost = Decimal(stats.messageCount) * Decimal(0.05)

        return stats
    }

    private struct CodexAuthInfo {
        let accessToken: String
        let baseURL: URL?
    }

    private func fetchRemoteRateLimits() async throws -> RemoteRateLimitSnapshot? {
        guard let authInfo = loadCodexAuthInfo() else {
            return nil
        }

        let baseCandidates = buildBaseURLCandidates(authInfo: authInfo)
        var lastError: Error?

        for baseURL in baseCandidates {
            for endpoint in usageEndpointCandidates(for: baseURL) {
                do {
                    let (data, _) = try await performRequest(
                        url: endpoint,
                        headers: [
                            "Authorization": "Bearer \(authInfo.accessToken)",
                            "Accept": "application/json",
                            "User-Agent": "AIUsageMonitor/1.0"
                        ]
                    )

                    if let snapshot = decodeRateLimitSnapshot(from: data) {
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

    private func decodeRateLimitSnapshot(from data: Data) -> RemoteRateLimitSnapshot? {
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(RateLimitStatusPayload.self, from: data) else {
            return nil
        }

        guard let rateLimit = payload.rateLimit else {
            return nil
        }

        let primaryWindowMinutes = rateLimit.primaryWindow?.limitWindowSeconds.map { $0 / 60 }
        let secondaryWindowMinutes = rateLimit.secondaryWindow?.limitWindowSeconds.map { $0 / 60 }

        return RemoteRateLimitSnapshot(
            primaryUsedPercent: rateLimit.primaryWindow?.usedPercent,
            secondaryUsedPercent: rateLimit.secondaryWindow?.usedPercent,
            primaryWindowMinutes: primaryWindowMinutes,
            secondaryWindowMinutes: secondaryWindowMinutes,
            primaryResetTime: rateLimit.primaryWindow?.resetAt.map { Date(timeIntervalSince1970: $0) },
            secondaryResetTime: rateLimit.secondaryWindow?.resetAt.map { Date(timeIntervalSince1970: $0) },
            planType: payload.planType
        )
    }

    private func applyRemoteRateLimits(_ snapshot: RemoteRateLimitSnapshot, to stats: inout SessionStats, now: Date) {
        if let resetTime = snapshot.primaryResetTime {
            let windowMinutes = snapshot.primaryWindowMinutes ?? 300
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
            let windowMinutes = snapshot.secondaryWindowMinutes ?? 10080
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

    private func loadCodexAuthInfo() -> CodexAuthInfo? {
        let authPath = "\(codexHome)/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var accessToken: String?
        if let tokens = json["tokens"] as? [String: Any] {
            accessToken = tokens["access_token"] as? String
        }

        if accessToken == nil {
            accessToken = (json["access_token"] as? String)
                ?? (json["accessToken"] as? String)
                ?? (json["token"] as? String)
                ?? (json["OPENAI_API_KEY"] as? String)
        }

        guard let token = accessToken, !token.isEmpty else {
            return nil
        }

        let baseURLString = (json["api_base_url"] as? String)
            ?? (json["base_url"] as? String)
            ?? (json["baseURL"] as? String)

        let baseURL = baseURLString.flatMap { URL(string: $0) }
        return CodexAuthInfo(accessToken: token, baseURL: baseURL)
    }

    private func buildBaseURLCandidates(authInfo: CodexAuthInfo) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        if let baseURL = authInfo.baseURL {
            candidates.append(baseURL)
            seen.insert(baseURL.absoluteString)
        }

        if let configURL = loadCodexBaseURLFromConfig(), !seen.contains(configURL.absoluteString) {
            candidates.append(configURL)
            seen.insert(configURL.absoluteString)
        }

        let defaults = ["https://api.openai.com", "https://chatgpt.com"]
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

    private func findRecentSessionFiles(in path: String, since date: Date) throws -> [String] {
        let fileManager = FileManager.default
        var sessionFiles: [(path: String, modDate: Date)] = []

        // Walk through YYYY/MM/DD structure
        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "jsonl" {
                // Check modification date
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate >= date {
                    sessionFiles.append((fileURL.path, modDate))
                }
            }
        }

        // Sort by modification date (oldest first, so newest is processed last)
        return sessionFiles.sorted { $0.modDate < $1.modDate }.map { $0.path }
    }

    private struct SessionData {
        var tokens: Int64 = 0
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var messageCount: Int = 0
        var primaryUsedPercent: Double?  // 5-hour window
        var secondaryUsedPercent: Double?  // 7-day window
        var primaryWindowMinutes: Int?
        var secondaryWindowMinutes: Int?
        var primaryResetTime: Date?  // 5-hour reset time
        var secondaryResetTime: Date?  // 7-day reset time
        var planType: String?
    }

    private func parseSessionFile(at path: String) -> SessionData? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var data = SessionData()
        let lines = content.components(separatedBy: .newlines)

        for line in lines where !line.isEmpty {
            guard let jsonData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Check for event_msg wrapper
            let payload: [String: Any]
            if let eventPayload = event["payload"] as? [String: Any] {
                payload = eventPayload
            } else {
                payload = event
            }

            // Count messages (turn.completed events)
            if let type = payload["type"] as? String {
                if type == "turn.completed" {
                    data.messageCount += 1
                }

                // Parse token_count events with rate_limits
                if type == "token_count" {
                    // Extract rate limits (most valuable data!)
                    if let rateLimits = payload["rate_limits"] as? [String: Any] {
                        if let primary = rateLimits["primary"] as? [String: Any] {
                            if let usedPercent = primary["used_percent"] as? Double {
                                data.primaryUsedPercent = usedPercent
                            }
                            if let windowMinutes = primary["window_minutes"] as? Int {
                                data.primaryWindowMinutes = windowMinutes
                            } else if let windowMinutes = primary["window_minutes"] as? Double {
                                data.primaryWindowMinutes = Int(windowMinutes)
                            }
                            // Parse reset time (Unix timestamp)
                            if let resetTimestamp = primary["resets_at"] as? Double {
                                data.primaryResetTime = Date(timeIntervalSince1970: resetTimestamp)
                            } else if let resetTimestamp = primary["resets_at"] as? Int {
                                data.primaryResetTime = Date(timeIntervalSince1970: Double(resetTimestamp))
                            }
                        }
                        if let secondary = rateLimits["secondary"] as? [String: Any] {
                            if let usedPercent = secondary["used_percent"] as? Double {
                                data.secondaryUsedPercent = usedPercent
                            }
                            if let windowMinutes = secondary["window_minutes"] as? Int {
                                data.secondaryWindowMinutes = windowMinutes
                            } else if let windowMinutes = secondary["window_minutes"] as? Double {
                                data.secondaryWindowMinutes = Int(windowMinutes)
                            }
                            if let resetTimestamp = secondary["resets_at"] as? Double {
                                data.secondaryResetTime = Date(timeIntervalSince1970: resetTimestamp)
                            } else if let resetTimestamp = secondary["resets_at"] as? Int {
                                data.secondaryResetTime = Date(timeIntervalSince1970: Double(resetTimestamp))
                            }
                        }
                        if let planType = rateLimits["plan_type"] as? String {
                            data.planType = planType
                        }
                    }

                    // Extract token usage
                    if let info = payload["info"] as? [String: Any],
                       let tokenUsage = info["total_token_usage"] as? [String: Any] {
                        if let input = tokenUsage["input_tokens"] as? Int {
                            data.inputTokens = Int64(input)
                        }
                        if let output = tokenUsage["output_tokens"] as? Int {
                            data.outputTokens = Int64(output)
                        }
                        if let total = tokenUsage["total_tokens"] as? Int {
                            data.tokens = Int64(total)
                        }
                    }
                }
            }
        }

        // If no token counts, estimate from messages
        if data.tokens == 0 && data.messageCount > 0 {
            // Rough estimate: ~2000 tokens per message average
            data.tokens = Int64(data.messageCount) * 2000
            data.inputTokens = Int64(Double(data.tokens) * 0.3)
            data.outputTokens = Int64(Double(data.tokens) * 0.7)
        }

        return data
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
