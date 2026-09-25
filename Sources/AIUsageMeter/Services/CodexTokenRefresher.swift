import Foundation
import AIUsageMeterCore

/// Renews Codex logins this app created itself.
///
/// The same rule as `ClaudeTokenRefresher`: a refresh rotates the refresh
/// token, so refreshing a login the CLI or a launcher owns would log that app
/// out. A workspace login added from the plan board has no other owner — and
/// Codex access tokens only last ten days, so without this every connected
/// workspace would quietly die a week and a half after it was added.
enum CodexTokenRefresher {

    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Codex CLI's public OAuth client.
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// Exchanges the stored refresh token and writes the result back to
    /// `authFile`. Returns the updated `auth.json` object.
    ///
    /// Call this **only** for accounts satisfying `ProviderAccount.isSelfManaged`.
    static func renew(authFile: URL) async throws -> [String: Any] {
        guard let data = try? Data(contentsOf: authFile),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw TokenRefreshError.noRefreshToken
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw TokenRefreshError.invalidResponse
        }
        guard status == 200,
              let fresh = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              fresh["access_token"] is String else {
            throw TokenRefreshError.refreshFailed(status, String(data: body, encoding: .utf8) ?? "")
        }

        for key in ["id_token", "access_token", "refresh_token"] {
            if let value = fresh[key] as? String, !value.isEmpty { tokens[key] = value }
        }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        // Store before use: a spent refresh token that isn't saved locks the
        // login out for good.
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try updated.write(to: authFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
        return root
    }
}

/// Every ChatGPT account each login can act in, fetched at most hourly.
///
/// One login reaches several workspaces, but its token only reads the limits
/// of the workspace it was issued in. The directory is how the board knows the
/// others exist — and can offer to connect them.
actor ChatGPTDirectoryCache {
    static let shared = ChatGPTDirectoryCache()

    private let url = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!
    private var entries: [String: (fetched: Date, workspaces: [ChatGPTWorkspace])] = [:]

    func workspaces(userId: String, accessToken: String) async -> [ChatGPTWorkspace] {
        if let entry = entries[userId], Date().timeIntervalSince(entry.fetched) < 3600 {
            return entry.workspaces
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Keep the last good answer rather than making workspaces blink out
            // on a transient failure; retry on the next refresh.
            return entries[userId]?.workspaces ?? []
        }
        let workspaces = ChatGPTWorkspaceDirectory.parse(data)
        entries[userId] = (Date(), workspaces)
        return workspaces
    }
}
