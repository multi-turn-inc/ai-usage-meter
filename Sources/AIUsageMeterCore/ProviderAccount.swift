import Foundation

/// One monitorable provider login. A machine can hold several paid accounts per
/// provider: the CLI's own default plus any a launcher (Orca) keeps in isolated
/// config homes.
///
/// Identity is **email + organization**, never email alone — the same person
/// routinely has a personal org and one or more team orgs under one address, and
/// those bill and rate-limit separately. Collapsing them by email would hide
/// real accounts.
public struct ProviderAccount: Identifiable, Sendable, Equatable {

    /// Where this account's OAuth credentials actually live.
    public enum CredentialSource: Sendable, Equatable {
        /// A JSON file we can read directly — no Keychain, no prompt.
        case file(path: String)
        /// A Keychain generic-password item. Reading an item another app created
        /// triggers an ACL prompt, so callers import it once and keep their own
        /// copy afterwards.
        case keychain(service: String, account: String)
    }

    public let id: String
    public let service: ServiceType
    public let email: String?
    /// Claude organization name, or the Codex workspace identifier.
    public let organizationName: String?
    /// Dedup key: `email|organizationUuid` (Claude) or the workspace id (Codex).
    public let identityKey: String
    public let source: CredentialSource
    /// True for the account the CLI itself uses (`~/.claude`, `~/.codex`).
    public let isDefault: Bool
    /// Codex only — sent as the `ChatGPT-Account-Id` header so usage is scoped
    /// to the right workspace.
    public let chatGPTAccountId: String?
    /// The config home this login lives in (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`),
    /// so a re-login can be pointed at this account instead of the machine default.
    public let configDir: String?

    public init(id: String, service: ServiceType, email: String?, organizationName: String?,
                identityKey: String, source: CredentialSource, isDefault: Bool,
                chatGPTAccountId: String? = nil, configDir: String? = nil) {
        self.id = id
        self.service = service
        self.email = email
        self.organizationName = organizationName
        self.identityKey = identityKey
        self.source = source
        self.isDefault = isDefault
        self.chatGPTAccountId = chatGPTAccountId
        self.configDir = configDir
    }

    /// Local part of the email, or a short fallback.
    public var shortName: String {
        guard let email, let at = email.firstIndex(of: "@") else {
            return email ?? String(id.suffix(8))
        }
        return String(email[email.startIndex..<at])
    }

    /// What the UI shows: enough to tell two orgs on one email apart.
    public var label: String {
        if let organizationName, !organizationName.isEmpty {
            return "\(shortName) · \(organizationName)"
        }
        return shortName
    }
}

/// Finds every Claude and Codex account on the machine.
///
/// Two families of location:
/// 1. The CLI default — `~/.claude`, `~/.codex`.
/// 2. Launcher-managed homes — Orca gives each account its own config dir
///    (`claude-accounts/<uuid>/auth`, `codex-accounts/<uuid>/home`). Codex keeps
///    tokens there as a plain `auth.json`; Claude keeps only identity there and
///    puts tokens in the Keychain under Orca's service, keyed by account uuid.
public enum AccountDiscovery {

    public static let orcaClaudeKeychainService = "Orca Claude Code Managed Credentials"

    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ProviderAccount] {
        discoverClaude(home: home) + discoverCodex(home: home)
    }

    // MARK: - Claude

    public static func discoverClaude(home: URL) -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        let fm = FileManager.default

        // 1. CLI default — credentials in a file, so reading never prompts.
        let defaultCreds = home.appendingPathComponent(".claude/.credentials.json")
        if fm.fileExists(atPath: defaultCreds.path) {
            let account = readJSONObject(at: home.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
            accounts.append(makeClaudeAccount(
                id: "claude:default",
                identity: account,
                source: .file(path: defaultCreds.path),
                isDefault: true,
                fallbackKey: defaultCreds.path,
                configDir: home.appendingPathComponent(".claude").path
            ))
        }

        // 2. Orca-managed — identity from the file, tokens from Orca's Keychain item.
        let root = orcaRoot(home: home).appendingPathComponent("claude-accounts")
        for uuid in sortedSubdirectories(of: root) {
            let identityFile = root.appendingPathComponent("\(uuid)/auth/oauth-account.json")
            guard let identity = readJSONObject(at: identityFile) else { continue }
            accounts.append(makeClaudeAccount(
                id: "claude:orca:\(uuid)",
                identity: identity,
                source: .keychain(service: orcaClaudeKeychainService, account: uuid),
                isDefault: false,
                fallbackKey: uuid,
                configDir: root.appendingPathComponent("\(uuid)/auth").path
            ))
        }

        return dedupe(accounts)
    }

    private static func makeClaudeAccount(
        id: String, identity: [String: Any]?, source: ProviderAccount.CredentialSource,
        isDefault: Bool, fallbackKey: String, configDir: String
    ) -> ProviderAccount {
        let email = (identity?["emailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let orgUuid = identity?["organizationUuid"] as? String
        let orgName = (identity?["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Email alone is not an identity — the same address spans several orgs.
        let key = (email != nil || orgUuid != nil)
            ? "\(email ?? "?")|\(orgUuid ?? "?")"
            : fallbackKey
        return ProviderAccount(
            id: id, service: .claude, email: email,
            organizationName: prettyOrgName(orgName, email: email),
            identityKey: key, source: source, isDefault: isDefault, configDir: configDir
        )
    }

    /// "hebo1221@gmail.com's Organization" is just the personal org — say so briefly.
    private static func prettyOrgName(_ name: String?, email: String?) -> String? {
        guard let name else { return nil }
        if name.hasSuffix("'s Organization") { return "Personal" }
        return name
    }

    // MARK: - Codex

    public static func discoverCodex(home: URL) -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        let fm = FileManager.default

        // 1. CLI default (respects CODEX_HOME).
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let defaultAuth = codexHome.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: defaultAuth.path) {
            accounts.append(makeCodexAccount(id: "codex:default", authFile: defaultAuth, isDefault: true))
        }

        // 2. Orca-managed homes — tokens are in the file, so no Keychain at all.
        let root = orcaRoot(home: home).appendingPathComponent("codex-accounts")
        for uuid in sortedSubdirectories(of: root) {
            let auth = root.appendingPathComponent("\(uuid)/home/auth.json")
            guard fm.fileExists(atPath: auth.path) else { continue }
            accounts.append(makeCodexAccount(id: "codex:orca:\(uuid)", authFile: auth, isDefault: false))
        }

        return dedupe(accounts)
    }

    private static func makeCodexAccount(id: String, authFile: URL, isDefault: Bool) -> ProviderAccount {
        let root = readJSONObject(at: authFile)
        let tokens = root?["tokens"] as? [String: Any]
        let workspaceId = tokens?["account_id"] as? String
        let claims = (tokens?["id_token"] as? String).flatMap(decodeJWTPayload)
        let email = codexEmail(from: claims)
        // The ChatGPT workspace id *is* the account identity: one login can hold
        // several workspaces that bill separately.
        let key = workspaceId ?? "\(email ?? "?")|\(authFile.path)"
        let workspaceLabel = workspaceId.map { "ws " + String($0.prefix(8)) }
        return ProviderAccount(
            id: id, service: .codex, email: email,
            organizationName: workspaceLabel,
            identityKey: key, source: .file(path: authFile.path),
            isDefault: isDefault, chatGPTAccountId: workspaceId,
            configDir: authFile.deletingLastPathComponent().path
        )
    }

    private static func codexEmail(from claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let email = claims["email"] as? String, !email.isEmpty { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty { return email }
        return nil
    }

    /// Decodes a JWT payload. The signature is irrelevant — this is already-trusted
    /// local state read only for a display label and workspace id.
    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Helpers

    static func orcaRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/orca")
    }

    /// One login reachable two ways (CLI default plus a managed home) must appear
    /// once. The CLI default wins: its credentials sit in a file, so refreshing it
    /// never triggers a Keychain prompt.
    static func dedupe(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
        var seen = Set<String>()
        var result: [ProviderAccount] = []
        for account in accounts.sorted(by: { lhs, rhs in
            lhs.isDefault && !rhs.isDefault
        }) where seen.insert(account.identityKey).inserted {
            result.append(account)
        }
        // Keep discovery order stable for the UI: defaults first, then by label.
        return result.sorted {
            $0.isDefault != $1.isDefault ? $0.isDefault : $0.label < $1.label
        }
    }

    private static func sortedSubdirectories(of url: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
