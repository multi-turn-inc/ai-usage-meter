import Foundation
import AIUsageMeterCore

/// Who each Claude token belongs to, and in which organisation.
///
/// Keyed by a fingerprint of the access token: an unchanged token is never
/// asked about twice, and a rotated one — a refresh, or a re-login that may have
/// landed in a different org — is checked again. Tokens rotate every few hours,
/// so this costs a handful of calls a day per account.
actor ClaudeProfileCache {
    static let shared = ClaudeProfileCache()

    private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private var profiles: [String: ClaudeProfile] = [:]
    /// A token whose profile call failed isn't retried every refresh.
    private var failedAt: [String: Date] = [:]

    func profile(accessToken: String) async -> ClaudeProfile? {
        let key = SHA256Fingerprint.of(accessToken)
        if let cached = profiles[key] { return cached }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 3600 { return nil }

        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("AIUsageMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let profile = ClaudeProfile.parse(data) else {
            failedAt[key] = Date()
            return nil
        }
        profiles[key] = profile
        return profile
    }
}

/// Remembers Anthropic's lockouts so they aren't made longer.
///
/// The usage endpoint answers an over-eager poller with a `Retry-After` of
/// tens of minutes, per account. Retrying inside that window — as every
/// refresh used to, twice — only extends it, so until it passes the account
/// isn't asked at all.
///
/// Kept across launches: Anthropic has already said when the lockout ends, so
/// a restart shouldn't spend a request per account to be told again.
actor ClaudeRateLimitGate {
    static let shared = ClaudeRateLimitGate()

    private static let defaultsKey = "claudeRateLimitedUntil"
    private var blockedUntil: [String: Date]

    init() {
        let stored = AppDefaults.userDefaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        blockedUntil = stored.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > Date() }
    }

    func blocked(_ key: String) -> Date? {
        guard let until = blockedUntil[key], until > Date() else { return nil }
        return until
    }

    func block(_ key: String, until: Date) {
        blockedUntil = blockedUntil.filter { $0.value > Date() }
        blockedUntil[key] = until
        AppDefaults.userDefaults.set(blockedUntil.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
    }
}

/// Refresh tokens the provider has refused.
///
/// A spent refresh token stays spent: retrying it every refresh only adds a
/// usage call and a token call per account against the same rate limits.
/// Until the credentials change — the user signing in again — such a login
/// is reported as needing a sign-in without asking the network.
actor DeadLoginRegistry {
    static let shared = DeadLoginRegistry()

    private var dead: Set<String> = []

    func isDead(refreshToken: String?) -> Bool {
        guard let refreshToken else { return false }
        return dead.contains(SHA256Fingerprint.of(refreshToken))
    }

    func markDead(refreshToken: String?) {
        guard let refreshToken else { return }
        dead.insert(SHA256Fingerprint.of(refreshToken))
    }
}
