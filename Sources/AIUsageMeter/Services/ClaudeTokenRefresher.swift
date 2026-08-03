import Foundation

/// Reads Claude credential JSON in the shapes it appears on disk and in the
/// Keychain.
///
/// There is deliberately **no refresh** here. Claude OAuth uses rotating refresh
/// tokens: refreshing consumes the old token and mints a new one, so a monitor
/// that refreshed an account owned by Claude Code or a launcher would leave that
/// app holding a dead token and silently log the user out of an account they
/// work in. Reporting is read-only; the app that owns a login keeps it fresh.
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
}
