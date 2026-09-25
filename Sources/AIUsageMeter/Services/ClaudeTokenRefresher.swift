import Foundation

/// Reads Claude credential JSON in the shapes it appears on disk and in the
/// Keychain.
///
/// Refreshing is restricted, not absent. Claude OAuth uses rotating refresh
/// tokens: a refresh consumes the old token and mints a new one, so refreshing an
/// account owned by Claude Code or a launcher would leave that app holding a dead
/// token and silently log the user out of an account they work in. Those accounts
/// stay read-only — whichever app owns the login keeps it fresh.
///
/// A login *this app* created is the exception. Nobody else holds those
/// credentials, so nobody can be logged out by rotating them, and without a
/// refresh they would be useless: no CLI ever runs in those config homes, so
/// nothing else would keep them alive and an account added for monitoring would
/// die about eight hours later and demand a fresh sign-in every day.
enum ClaudeTokenRefresher {

    /// Accepts both Claude Code's wrapped shape (`{"claudeAiOauth": {...}}`) and
    /// a bare credentials object.
    static func decode(_ json: String) -> ClaudeCodeCredentials? {
        guard let data = json.data(using: .utf8) else { return nil }
        if let wrapper = try? JSONDecoder().decode(ClaudeCodeCredentialsWrapper.self, from: data) {
            return wrapper.claudeAiOauth
        }
        return try? JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
    }

    /// Wraps credentials back into the shape they are stored in.
    static func encode(_ credentials: ClaudeCodeCredentials) -> String? {
        guard let data = try? JSONEncoder().encode(ClaudeCodeCredentialsWrapper(claudeAiOauth: credentials)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Exchanges a refresh token for a new access token.
    ///
    /// Call this **only** for accounts satisfying `ProviderAccount.isSelfManaged`.
    /// The returned refresh token replaces the one passed in — the old one is dead
    /// the moment this succeeds.
    static func refresh(_ credentials: ClaudeCodeCredentials) async throws -> ClaudeCodeCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw TokenRefreshError.noCredentials
        }
        // Claude Code moved its token endpoint from console.anthropic.com to
        // platform.claude.com; follow the CLI rather than a retired host.
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": credentials.scopes?.joined(separator: " ") ?? defaultScopes,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokenRefreshError.invalidResponse }
        guard http.statusCode == 200 else {
            throw TokenRefreshError.refreshFailed(http.statusCode,
                                                  String(data: data, encoding: .utf8) ?? "")
        }

        let refreshed = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return ClaudeCodeCredentials(
            accessToken: refreshed.accessToken,
            // A response without a new refresh token means the old one still
            // stands; dropping it here would strand the account permanently.
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(refreshed.expiresIn * 1000),
            idToken: refreshed.idToken,
            rateLimitTier: credentials.rateLimitTier,
            subscriptionType: credentials.subscriptionType,
            scopes: credentials.scopes
        )
    }

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let defaultScopes = "user:inference user:profile user:sessions:claude_code"
}
