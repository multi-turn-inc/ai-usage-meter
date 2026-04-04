import Foundation
import Security
import LocalAuthentication


class KeychainManager {
    static let shared = KeychainManager()
    private let serviceName = "com.aiusagemeter"
    private let fileManager = FileManager.default

    // Cache for Claude Code credentials to avoid repeated Keychain prompts.
    // Stored in-memory for the app session and updated on refresh.
    private var cachedClaudeCredentials: ClaudeCodeCredentials?

    // Cache for discovered Keychain service names (avoid repeated broad scans)
    private var cachedDiscoveredServices: Set<String>?

    /// Claude Code's public OAuth client_id from its open-source npm package
    /// (@anthropic-ai/claude-code). This is NOT a secret — OAuth public clients
    /// do not have client secrets and this value is freely available in the source.
    private let claudeCodeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private init() {}

    func save(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func retrieve(for key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.retrieveFailed(status)
        }

        return value
    }

    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func exists(for key: String) -> Bool {
        do {
            _ = try retrieve(for: key)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Claude Code Credentials

    /// Reads Claude Code OAuth credentials from system Keychain
    /// Uses single query + caching to minimize Keychain access prompts
    func getClaudeCodeCredentials(allowInteraction: Bool = true) -> ClaudeCodeCredentials? {
        // Return cached credentials if valid (avoid repeated Keychain prompts)
        if let cached = cachedClaudeCredentials {
            if !cached.isExpired {
                return cached
            }
            // Cached token expired — re-read from Keychain in case user re-authenticated
            cachedClaudeCredentials = nil
        }

        var records = getAllClaudeCodeCredentialRecords(includingDiscoveredServices: false, allowInteraction: allowInteraction)
        if records.isEmpty && allowInteraction {
            // Discovery enumerates Keychain items; keep it user-initiated only.
            records = getAllClaudeCodeCredentialRecords(includingDiscoveredServices: true, allowInteraction: allowInteraction)
        }

        var bestCredentials: ClaudeCodeCredentials?
        var bestExpiresAt: Int64 = 0
        var bestHasProfileScope = false

        for record in records {
            let creds = record.credentials
            let expiresAt = creds.expiresAtMs ?? 0
            let hasProfile = creds.scopes?.contains("user:profile") ?? false

            if !creds.isExpired {
                let isBetter: Bool
                if hasProfile && !bestHasProfileScope {
                    isBetter = true
                } else if hasProfile == bestHasProfileScope {
                    isBetter = expiresAt > bestExpiresAt
                } else {
                    isBetter = false
                }

                if isBetter || bestCredentials == nil {
                    bestCredentials = creds
                    bestExpiresAt = expiresAt
                    bestHasProfileScope = hasProfile
                }
            } else if bestCredentials == nil {
                bestCredentials = creds
                bestExpiresAt = expiresAt
                bestHasProfileScope = hasProfile
            }
        }

        // Cache the result
        cachedClaudeCredentials = bestCredentials
        return bestCredentials
    }

    /// Clears the cached credentials (call on account switch)
    func clearCredentialsCache() {
        cachedClaudeCredentials = nil
        cachedDiscoveredServices = nil
    }

    private struct ClaudeCodeCredentialsRecord {
        let storage: ClaudeCodeCredentialStorage
        let credentials: ClaudeCodeCredentials
    }

    private enum ClaudeCodeCredentialStorage {
        case keychain(service: String, account: String)
        case file(url: URL)
    }

    private func getAllClaudeCodeCredentialRecords(includingDiscoveredServices: Bool, allowInteraction: Bool) -> [ClaudeCodeCredentialsRecord] {
        let baseService = "Claude Code-credentials"
        var services: Set<String> = [baseService]

        if includingDiscoveredServices {
            services.formUnion(discoverClaudeCodeCredentialServices(allowInteraction: allowInteraction))
        }

        var records: [ClaudeCodeCredentialsRecord] = []
        for service in services.sorted() {
            records.append(contentsOf: fetchClaudeCodeCredentialRecords(service: service, allowInteraction: allowInteraction))
        }

        records.append(contentsOf: loadClaudeCodeCredentialRecordsFromFiles())

        var seen = Set<String>()
        return records.filter { record in
            let key = record.credentials.refreshToken ?? record.credentials.accessToken
            return seen.insert(key).inserted
        }
    }

    private func loadClaudeCodeCredentialRecordsFromFiles() -> [ClaudeCodeCredentialsRecord] {
        claudeCodeCredentialFileURLs().compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let credentials = parseCredentials(from: data) else {
                return nil
            }

            return ClaudeCodeCredentialsRecord(storage: .file(url: url), credentials: credentials)
        }
    }

    private func claudeCodeCredentialFileURLs() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".config/claude/.credentials.json"),
            home.appendingPathComponent(".config/claude-code/.credentials.json")
        ]
    }

    private func discoverClaudeCodeCredentialServices(allowInteraction: Bool) -> Set<String> {
        if let cached = cachedDiscoveredServices {
            return cached
        }

        let query = keychainQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ], allowInteraction: allowInteraction)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return []
        }

        let items = result as? [[String: Any]] ?? []
        let services = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix("Claude Code-credentials") }

        let discovered = Set(services)
        cachedDiscoveredServices = discovered
        return discovered
    }

    private func fetchClaudeCodeCredentialRecords(service: String, allowInteraction: Bool) -> [ClaudeCodeCredentialsRecord] {
        let attrsQuery = keychainQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ], allowInteraction: allowInteraction)

        var attrsResult: AnyObject?
        let attrsStatus = SecItemCopyMatching(attrsQuery as CFDictionary, &attrsResult)


        guard attrsStatus == errSecSuccess else {
            if attrsStatus != errSecItemNotFound {
            }
            return []
        }

        let attrItems: [[String: Any]]
        if let array = attrsResult as? [[String: Any]] {
            attrItems = array
        } else if let dict = attrsResult as? [String: Any] {
            attrItems = [dict]
        } else {
            attrItems = []
        }

        var records: [ClaudeCodeCredentialsRecord] = []

        for item in attrItems {
            guard let account = item[kSecAttrAccount as String] as? String else {
                continue
            }

            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            let dataQueryWithUI = keychainQuery(dataQuery, allowInteraction: allowInteraction)

            var dataResult: AnyObject?
            let dataStatus = SecItemCopyMatching(dataQueryWithUI as CFDictionary, &dataResult)

            guard dataStatus == errSecSuccess,
                  let data = dataResult as? Data,
                  let creds = parseCredentials(from: data) else {
                continue
            }

            records.append(
                ClaudeCodeCredentialsRecord(
                    storage: .keychain(service: service, account: account),
                    credentials: creds
                )
            )
        }

        return records
    }

    private func parseCredentials(from data: Data) -> ClaudeCodeCredentials? {
        do {
            // The JSON is wrapped in {"claudeAiOauth": {...}}
            let wrapper = try JSONDecoder().decode(ClaudeCodeCredentialsWrapper.self, from: data)
            return wrapper.claudeAiOauth
        } catch {
            // Try direct decode as fallback
            return try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
        }
    }

    private func keychainQuery(_ base: [String: Any], allowInteraction: Bool) -> [String: Any] {
        guard !allowInteraction else { return base }
        var query = base
        // Avoid showing Keychain password / permission dialogs during automatic refresh.
        // (Preferred over deprecated kSecUseAuthenticationUI.)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}

struct ClaudeCodeCredentialsWrapper: Codable {
    let claudeAiOauth: ClaudeCodeCredentials
}

struct ClaudeCodeCredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAtMs: Int64?  // Seconds or milliseconds since epoch
    let idToken: String?
    let rateLimitTier: String?
    let subscriptionType: String?
    let scopes: [String]?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAtMs = "expiresAt"
        case idToken
        case rateLimitTier
        case subscriptionType
        case scopes
    }

    private var expiresAtEpochMilliseconds: Int64? {
        guard let value = expiresAtMs else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }

    var expiresAt: Date? {
        guard let ms = expiresAtEpochMilliseconds else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() >= expiresAt
    }

    var willExpireSoon: Bool {
        guard let expiresAt = expiresAt else { return false }
        // Consider expired if less than 5 minutes remaining
        return Date().addingTimeInterval(300) >= expiresAt
    }
}

// MARK: - Token Refresh

extension KeychainManager {
    /// Attempts to refresh the Claude Code OAuth token using the refresh token
    func refreshClaudeCodeToken(allowInteraction: Bool = true) async throws -> ClaudeCodeCredentials {
        let cachedAccessToken = cachedClaudeCredentials?.accessToken

        var records = getAllClaudeCodeCredentialRecords(includingDiscoveredServices: false, allowInteraction: allowInteraction)
        var usedDiscovery = false
        if records.isEmpty && allowInteraction {
            records = getAllClaudeCodeCredentialRecords(includingDiscoveredServices: true, allowInteraction: allowInteraction)
            usedDiscovery = true
        }

        guard !records.isEmpty else {
            throw TokenRefreshError.noCredentials
        }

        let clientId = claudeCodeClientId

        var seenRefreshToken = false
        var lastError: Error?
        var attempted = Set<String>()

        func attemptRefresh(from records: [ClaudeCodeCredentialsRecord]) async -> ClaudeCodeCredentials? {
            let orderedRecords = records.sorted {
                let aIsCached = $0.credentials.accessToken == cachedAccessToken
                let bIsCached = $1.credentials.accessToken == cachedAccessToken
                if aIsCached != bIsCached { return aIsCached }

                let aExpiresAt = $0.credentials.expiresAtMs ?? 0
                let bExpiresAt = $1.credentials.expiresAtMs ?? 0
                return aExpiresAt > bExpiresAt
            }

            for record in orderedRecords {
                let recordKey: String
                switch record.storage {
                case .keychain(let service, let account):
                    recordKey = "keychain|\(service)|\(account)"
                case .file(let url):
                    recordKey = "file|\(url.path)"
                }
                guard attempted.insert(recordKey).inserted else { continue }

                guard let refreshToken = record.credentials.refreshToken else {
                    continue
                }
                seenRefreshToken = true

                let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

                let fullScopes = "user:inference user:profile user:sessions:claude_code"
                let existingScopes = record.credentials.scopes?.joined(separator: " ") ?? "user:inference"
                let scopeCandidates = existingScopes != fullScopes ? [fullScopes, existingScopes] : [fullScopes]

                for scopes in scopeCandidates {
                    var request = URLRequest(url: tokenURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "grant_type": "refresh_token",
                        "refresh_token": refreshToken,
                        "client_id": clientId,
                        "scope": scopes
                    ]
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw TokenRefreshError.invalidResponse
                        }

                        guard httpResponse.statusCode == 200 else {
                            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                            throw TokenRefreshError.refreshFailed(httpResponse.statusCode, message)
                        }

                        let decoder = JSONDecoder()
                        let tokenResponse = try decoder.decode(TokenRefreshResponse.self, from: data)

                        let grantedScopes = scopes.split(separator: " ").map(String.init)
                        let newCredentials = ClaudeCodeCredentials(
                            accessToken: tokenResponse.accessToken,
                            refreshToken: tokenResponse.refreshToken ?? refreshToken,
                            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(tokenResponse.expiresIn * 1000),
                            idToken: tokenResponse.idToken,
                            rateLimitTier: record.credentials.rateLimitTier,
                            subscriptionType: record.credentials.subscriptionType,
                            scopes: grantedScopes
                        )

                        try updateClaudeCodeCredentials(newCredentials, storage: record.storage)
                        try synchronizeClaudeCodeCredentialsToFiles(newCredentials)
                        cachedClaudeCredentials = newCredentials
                        return newCredentials
                    } catch let error as TokenRefreshError {
                        if case .refreshFailed(400, _) = error, scopes == fullScopes {
                            continue
                        }
                        lastError = error
                    } catch {
                        lastError = error
                    }
                }
            }

            return nil
        }

        if let refreshed = await attemptRefresh(from: records) {
            return refreshed
        }

        if allowInteraction && !usedDiscovery {
            let allRecords = getAllClaudeCodeCredentialRecords(includingDiscoveredServices: true, allowInteraction: allowInteraction)
            if let refreshed = await attemptRefresh(from: allRecords) {
                return refreshed
            }
        }

        if !seenRefreshToken {
            throw TokenRefreshError.noRefreshToken
        }

        throw lastError ?? TokenRefreshError.invalidResponse
    }

    private func updateClaudeCodeCredentials(_ credentials: ClaudeCodeCredentials, storage: ClaudeCodeCredentialStorage) throws {
        switch storage {
        case .keychain(let service, let account):
            try updateClaudeCodeCredentialsInKeychain(credentials, service: service, account: account)
        case .file(let url):
            try updateClaudeCodeCredentialsFile(credentials, at: url)
        }
    }

    private func updateClaudeCodeCredentialsInKeychain(_ credentials: ClaudeCodeCredentials, service: String, account: String) throws {
        let wrapper = ClaudeCodeCredentialsWrapper(claudeAiOauth: credentials)
        let data = try JSONEncoder().encode(wrapper)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.saveFailed(status)
        }
    }

    private func synchronizeClaudeCodeCredentialsToFiles(_ credentials: ClaudeCodeCredentials) throws {
        for url in claudeCodeCredentialFileURLs() where fileManager.fileExists(atPath: url.path) {
            try updateClaudeCodeCredentialsFile(credentials, at: url)
        }
    }

    private func updateClaudeCodeCredentialsFile(_ credentials: ClaudeCodeCredentials, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let wrapperData = try encoder.encode(ClaudeCodeCredentialsWrapper(claudeAiOauth: credentials))
        let wrapperObject = try JSONSerialization.jsonObject(with: wrapperData) as? [String: Any] ?? [:]

        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        document["claudeAiOauth"] = wrapperObject["claudeAiOauth"]

        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}

struct TokenRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}

enum TokenRefreshError: LocalizedError {
    case noCredentials
    case noRefreshToken
    case invalidResponse
    case refreshFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found"
        case .noRefreshToken:
            return "No refresh token available"
        case .invalidResponse:
            return "Invalid response from token server"
        case .refreshFailed(let code, let message):
            return "Token refresh failed (\(code)): \(message)"
        }
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode value"
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve from Keychain: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain: \(status)"
        }
    }
}
