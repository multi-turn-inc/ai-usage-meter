import Foundation

class GeminiClient: BaseAPIClient, AIServiceAPI {
    private let geminiHome: String
    
    override init(config: ServiceConfig) {
        self.geminiHome = NSHomeDirectory() + "/.gemini"
        super.init(config: config)
    }
    
    func fetchUsage() async throws -> UsageData {
        guard let creds = loadOAuthCredentials() else {
            throw APIError.missingAPIKey
        }
        
        var accessToken = creds.accessToken
        
        if isTokenExpired(creds) {
            accessToken = try await refreshToken(creds)
        }
        
        do {
            let projectId = try await discoverProjectId(accessToken: accessToken)
            let quota = try await fetchQuota(accessToken: accessToken, projectId: projectId)
            return convertToUsageData(quota: quota)
        } catch APIError.unauthorized {
            accessToken = try await refreshToken(creds)
            let projectId = try await discoverProjectId(accessToken: accessToken)
            let quota = try await fetchQuota(accessToken: accessToken, projectId: projectId)
            return convertToUsageData(quota: quota)
        }
    }
    
    private struct OAuthCredentials {
        let accessToken: String
        let refreshToken: String
        let clientId: String
        let clientSecret: String
        let expiresAt: Date?
    }
    
    private struct QuotaBucket {
        let modelId: String
        let remainingFraction: Double
        let resetTime: Date?
    }
    
    private struct GeminiQuota {
        var proRemaining: Double?
        var flashRemaining: Double?
        var proResetTime: Date?
        var flashResetTime: Date?
        var tier: String
    }
    
    private func loadOAuthCredentials() -> OAuthCredentials? {
        let credPath = "\(geminiHome)/oauth_creds.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return nil
        }
        
        let clientId = json["client_id"] as? String ?? ""
        let clientSecret = json["client_secret"] as? String ?? ""
        
        var expiresAt: Date?
        if let expiryStr = json["token_expiry"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: expiryStr)
            if expiresAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiresAt = formatter.date(from: expiryStr)
            }
        } else if let expiryTimestamp = json["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiryTimestamp)
        }
        
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            expiresAt: expiresAt
        )
    }
    
    private func isTokenExpired(_ creds: OAuthCredentials) -> Bool {
        guard let expiresAt = creds.expiresAt else { return true } // No expiry info → assume expired, force refresh
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
    
    private func refreshToken(_ creds: OAuthCredentials) async throws -> String {
        var clientId = creds.clientId
        var clientSecret = creds.clientSecret
        
        if clientId.isEmpty || clientSecret.isEmpty {
            let extracted = extractClientCredentials()
            clientId = extracted.clientId
            clientSecret = extracted.clientSecret
        }
        
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            throw APIError.missingAPIKey
        }
        
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        let body = "grant_type=refresh_token&client_id=\(clientId)&client_secret=\(clientSecret)&refresh_token=\(creds.refreshToken)"
        
        let (data, _) = try await performRequest(
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            method: "POST",
            body: body.data(using: .utf8)
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw APIError.decodingError(NSError(domain: "GeminiClient", code: -1))
        }
        
        updateStoredToken(newToken: newToken, expiresIn: json["expires_in"] as? Int)
        
        return newToken
    }
    
    private func extractClientCredentials() -> (clientId: String, clientSecret: String) {
        let whichResult = try? shellSync("which gemini")
        if let path = whichResult?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let resolved = (try? shellSync("readlink -f '\(path)'"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? path
            let binDir = (resolved as NSString).deletingLastPathComponent
            let libDir = (binDir as NSString).deletingLastPathComponent

            let candidatePaths = [
                "\(libDir)/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                "\(libDir)/src/code_assist/oauth2.js",
                "\(libDir)/lib/oauth2.js",
            ]

            for candidate in candidatePaths {
                if FileManager.default.fileExists(atPath: candidate),
                   let creds = parseOAuth2JS(at: candidate) {
                    return creds
                }
            }
        }

        let fallbackPaths = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]

        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path),
               let creds = parseOAuth2JS(at: path) {
                return creds
            }
        }

        return ("", "")
    }
    
    private func parseOAuth2JS(at path: String) -> (clientId: String, clientSecret: String)? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        
        var clientId: String?
        var clientSecret: String?
        
        let patterns: [(NSRegularExpression?, (String) -> Void)] = [
            (try? NSRegularExpression(pattern: "OAUTH_CLIENT_ID\\s*=\\s*[\"']([^\"']+)[\"']"), { clientId = $0 }),
            (try? NSRegularExpression(pattern: "client_id[\"']?\\s*[:=]\\s*[\"']([^\"']+)[\"']"), { clientId = clientId ?? $0 }),
            (try? NSRegularExpression(pattern: "OAUTH_CLIENT_SECRET\\s*=\\s*[\"']([^\"']+)[\"']"), { clientSecret = $0 }),
            (try? NSRegularExpression(pattern: "client_secret[\"']?\\s*[:=]\\s*[\"']([^\"']+)[\"']"), { clientSecret = clientSecret ?? $0 }),
        ]
        
        let range = NSRange(content.startIndex..., in: content)
        
        for (pattern, setter) in patterns {
            if let match = pattern?.firstMatch(in: content, range: range),
               let matchRange = Range(match.range(at: 1), in: content) {
                setter(String(content[matchRange]))
            }
        }
        
        guard let id = clientId, let secret = clientSecret else { return nil }
        return (id, secret)
    }
    
    private func updateStoredToken(newToken: String, expiresIn: Int?) {
        let credPath = "\(geminiHome)/oauth_creds.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        json["access_token"] = newToken
        if let expiresIn = expiresIn {
            json["expires_at"] = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
        }
        
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? updatedData.write(to: URL(fileURLWithPath: credPath))
        }
    }
    
    private func discoverProjectId(accessToken: String) async throws -> String {
        let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects?pageSize=50")!
        
        let (data, _) = try await performRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ]
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]] else {
            throw APIError.decodingError(NSError(domain: "GeminiClient", code: -2))
        }
        
        let geminiProject = projects.first { project in
            let projectId = project["projectId"] as? String ?? ""
            return projectId.hasPrefix("gen-lang-client")
        }
        
        guard let projectId = geminiProject?["projectId"] as? String else {
            throw APIError.httpError(statusCode: 404, message: "No Gemini project found")
        }
        
        return projectId
    }
    
    private func fetchQuota(accessToken: String, projectId: String) async throws -> GeminiQuota {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        
        let bodyJson: [String: Any] = ["project": projectId]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyJson)
        
        let (data, _) = try await performRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            method: "POST",
            body: bodyData
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "GeminiClient", code: -3))
        }
        
        return parseQuotaResponse(json)
    }
    
    private func parseQuotaResponse(_ json: [String: Any]) -> GeminiQuota {
        var quota = GeminiQuota(tier: "Gemini")
        
        guard let buckets = json["buckets"] as? [[String: Any]] else {
            return quota
        }
        
        var lowestProFraction = 1.0
        var lowestFlashFraction = 1.0
        var proResetTime: Date?
        var flashResetTime: Date?
        var hasProModel = false
        
        let formatter = ISO8601DateFormatter()
        
        for bucket in buckets {
            let remainingFraction = bucket["remainingFraction"] as? Double ?? 1.0
            let rawModelId = bucket["modelId"] as? String ?? ""
            let modelId = rawModelId.lowercased()
            
            if modelId.hasSuffix("_vertex") { continue }
            
            var resetTime: Date?
            if let resetStr = bucket["resetTime"] as? String {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetTime = formatter.date(from: resetStr)
                if resetTime == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    resetTime = formatter.date(from: resetStr)
                }
            }
            
            if modelId.contains("pro") {
                hasProModel = true
                if remainingFraction < lowestProFraction {
                    lowestProFraction = remainingFraction
                    proResetTime = resetTime
                }
            } else if modelId.contains("flash") || modelId.contains("lite") {
                if remainingFraction < lowestFlashFraction {
                    lowestFlashFraction = remainingFraction
                    flashResetTime = resetTime
                }
            }
        }
        
        if let tierInfo = json["tier"] as? String ?? json["userTierId"] as? String {
            let tier = tierInfo.lowercased()
            if tier.contains("premium") || tier.contains("pro") || tier.contains("standard") {
                quota.tier = "Gemini Pro"
            } else {
                quota.tier = "Gemini Free"
            }
        } else {
            quota.tier = hasProModel ? "Gemini Pro" : "Gemini Free"
        }
        
        quota.proRemaining = lowestProFraction
        quota.flashRemaining = lowestFlashFraction
        quota.proResetTime = proResetTime
        quota.flashResetTime = flashResetTime
        
        return quota
    }
    
    private func convertToUsageData(quota: GeminiQuota) -> UsageData {
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let proUsedPercent = (1.0 - (quota.proRemaining ?? 1.0)) * 100.0
        let flashUsedPercent = (1.0 - (quota.flashRemaining ?? 1.0)) * 100.0
        
        return UsageData(
            tokensUsed: Int64(proUsedPercent * 10000),
            tokensLimit: 1_000_000,
            inputTokens: nil,
            outputTokens: nil,
            periodStart: startOfDay,
            periodEnd: endOfDay,
            resetDate: quota.proResetTime,
            sevenDayResetDate: quota.flashResetTime,
            currentCost: nil,
            projectedCost: nil,
            currency: "USD",
            tier: quota.tier,
            lastUpdated: now,
            fiveHourUsage: proUsedPercent,
            sevenDayUsage: flashUsedPercent
        )
    }
    
    private func shellSync(_ command: String) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        task.standardInput = nil
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
