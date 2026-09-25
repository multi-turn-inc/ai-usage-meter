import Foundation
import CryptoKit
import Security

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
    /// "Max 20x", "Team 5x", "Business" — as declared where the login was found.
    public let planName: String?
    /// The person behind the login, across orgs (Claude account uuid, ChatGPT
    /// user id).
    public let personKey: String?
    /// The quota bucket, when the credential itself proves it: a Codex access
    /// token names its member and workspace in its own claims. Claude tokens are
    /// opaque, so theirs is only known after asking the API.
    public let evidenceKey: String?
    /// The quota bucket as the identity file beside the credential declares it,
    /// in the same `person|org` form as the evidence. Declared, not proven —
    /// trusted only where the CLI wrote file and credential together.
    public let declaredPlanKey: String?

    public init(id: String, service: ServiceType, email: String?, organizationName: String?,
                identityKey: String, source: CredentialSource, isDefault: Bool,
                chatGPTAccountId: String? = nil, configDir: String? = nil,
                planName: String? = nil, personKey: String? = nil, evidenceKey: String? = nil,
                declaredPlanKey: String? = nil) {
        self.id = id
        self.service = service
        self.email = email
        self.organizationName = organizationName
        self.identityKey = identityKey
        self.source = source
        self.isDefault = isDefault
        self.chatGPTAccountId = chatGPTAccountId
        self.configDir = configDir
        self.planName = planName
        self.personKey = personKey
        self.evidenceKey = evidenceKey
        self.declaredPlanKey = declaredPlanKey
    }

    /// True when this app created the login itself, in a config home it owns.
    ///
    /// It matters for token handling: nobody else holds these credentials, so
    /// refreshing them — which rotates the refresh token — cannot log anyone out
    /// of an account they work in. For every other account that same refresh
    /// would do exactly that.
    public var isSelfManaged: Bool { id.contains(":own:") }

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

    /// Reads only the item's modification date. `kSecReturnAttributes` without
    /// `kSecReturnData` never touches the secret, so this is safe to call for
    /// items owned by other apps: no ACL check, no password prompt.
    public static let defaultKeychainModified: KeychainTimestampReader = { service, account in
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return (attributes[kSecAttrModificationDate as String] as? Date)
            ?? (attributes[kSecAttrCreationDate as String] as? Date)
    }

    /// Claude Code 2.1+ scopes its Keychain item by config dir, appending the
    /// first 8 hex of sha256(CLAUDE_CONFIG_DIR). Credentials for a custom config
    /// home therefore live under this name — **not** in a file. Assuming a file
    /// is what made a freshly added account look like a failed login.
    public static func claudeScopedKeychainService(forConfigDir dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    /// Where Claude Code keeps the default login's credentials when
    /// CLAUDE_CONFIG_DIR is unset.
    public static let claudeUnscopedKeychainService = "Claude Code-credentials"

    /// Marks a config home this app created, so an abandoned login can be told
    /// apart from one whose credentials simply live in the Keychain.
    public static let selfManagedMarker = ".token-burn-account"

    /// Accounts this app added itself live here, one config home per account.
    /// Logging in with `CLAUDE_CONFIG_DIR`/`CODEX_HOME` pointed at one of these
    /// leaves the credentials in a file we own outright — no Keychain, so no
    /// prompt, ever.
    public static func selfManagedRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/TokenBurn/accounts")
    }

    public static func newSelfManagedDir(for service: ServiceType, home: URL) -> URL {
        selfManagedRoot(home: home)
            .appendingPathComponent(service.rawValue.lowercased())
            .appendingPathComponent(UUID().uuidString)
    }

    /// When a Keychain item was last written, or nil if there is no such item.
    /// Attribute-only, so it never reads the secret and never prompts.
    public typealias KeychainTimestampReader = @Sendable (_ service: String, _ account: String) -> Date?

    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychainModified: @escaping KeychainTimestampReader = defaultKeychainModified
    ) -> [ProviderAccount] {
        discoverClaude(home: home, keychainModified: keychainModified) + discoverCodex(home: home)
    }

    // MARK: - Claude

    /// - Parameter readsUnscopedItem: whether the unscoped Keychain item speaks
    ///   for this `home`. It belongs to the signed-in user rather than to a
    ///   path, so by default only the real home consults it.
    public static func discoverClaude(
        home: URL,
        keychainModified: @escaping KeychainTimestampReader = defaultKeychainModified,
        readsUnscopedItem: Bool? = nil
    ) -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        let fm = FileManager.default
        let readsUnscoped = readsUnscopedItem
            ?? (home.standardizedFileURL == fm.homeDirectoryForCurrentUser.standardizedFileURL)

        // 1. CLI default. Its credentials can sit in three places, and a machine
        // that has lived through several Claude Code versions has all three:
        //   - the file ~/.claude/.credentials.json, which older versions wrote;
        //   - the unscoped Keychain item, which current versions write when
        //     CLAUDE_CONFIG_DIR is unset — the everyday case;
        //   - the item scoped to ~/.claude, written only when CLAUDE_CONFIG_DIR
        //     was set to ~/.claude explicitly, as a launcher does.
        // The ones not in use stay frozen at whatever token they last held.
        // Reading the scoped item alone reported the everyday login as expired
        // for weeks while the CLI was signed in and working. Whichever store was
        // written last is the live one.
        let configDir = home.appendingPathComponent(".claude")
        let defaultCreds = configDir.appendingPathComponent(".credentials.json")
        let scopedService = claudeScopedKeychainService(forConfigDir: configDir.path)
        let fileWrittenAt = (try? fm.attributesOfItem(atPath: defaultCreds.path)[.modificationDate]) as? Date

        let stores: [(source: ProviderAccount.CredentialSource, writtenAt: Date)] = [
            fileWrittenAt.map { (.file(path: defaultCreds.path), $0) },
            (readsUnscoped ? keychainModified(claudeUnscopedKeychainService, NSUserName()) : nil).map {
                (.keychain(service: claudeUnscopedKeychainService, account: NSUserName()), $0)
            },
            keychainModified(scopedService, NSUserName()).map {
                (.keychain(service: scopedService, account: NSUserName()), $0)
            },
        ].compactMap { $0 }

        if let live = stores.max(by: { $0.writtenAt < $1.writtenAt }) {
            let account = readJSONObject(at: home.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
            accounts.append(makeClaudeAccount(
                id: "claude:default",
                identity: account,
                source: live.source,
                isDefault: true,
                fallbackKey: defaultCreds.path,
                configDir: configDir.path
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

        // 3. Accounts this app added — credentials in a file we own, no prompt.
        let ours = selfManagedRoot(home: home).appendingPathComponent("claude")
        for uuid in sortedSubdirectories(of: ours) {
            let dir = ours.appendingPathComponent(uuid)
            let creds = dir.appendingPathComponent(".credentials.json")
            // The CLI writes to the Keychain on macOS; the file only appears when
            // something else syncs one. Accept either.
            let source: ProviderAccount.CredentialSource = fm.fileExists(atPath: creds.path)
                ? .file(path: creds.path)
                : .keychain(service: claudeScopedKeychainService(forConfigDir: dir.path),
                            account: NSUserName())
            let identity = readJSONObject(at: dir.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
            // An abandoned login leaves the marker but no identity and no creds.
            guard identity != nil || fm.fileExists(atPath: creds.path) else { continue }
            accounts.append(makeClaudeAccount(
                id: "claude:own:\(uuid)",
                identity: identity,
                source: source,
                isDefault: false,
                fallbackKey: uuid,
                configDir: dir.path
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
        let declared = identity.map(ClaudeProfile.fromOAuthAccount)
        return ProviderAccount(
            id: id, service: .claude, email: email,
            organizationName: prettyOrgName(orgName),
            identityKey: key, source: source, isDefault: isDefault, configDir: configDir,
            planName: declared?.planName, personKey: declared?.accountUuid,
            declaredPlanKey: declared?.planKey
        )
    }

    /// "hebo1221@gmail.com's Organization" is just the personal org — say so briefly.
    public static func prettyOrgName(_ name: String?) -> String? {
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

        // 3. Accounts this app added.
        let ours = selfManagedRoot(home: home).appendingPathComponent("codex")
        for uuid in sortedSubdirectories(of: ours) {
            let auth = ours.appendingPathComponent("\(uuid)/auth.json")
            guard fm.fileExists(atPath: auth.path) else { continue }
            accounts.append(makeCodexAccount(id: "codex:own:\(uuid)", authFile: auth, isDefault: false))
        }

        return dedupe(accounts)
    }

    private static func makeCodexAccount(id: String, authFile: URL, isDefault: Bool) -> ProviderAccount {
        let root = readJSONObject(at: authFile)
        let tokens = root?["tokens"] as? [String: Any]
        let claims = (tokens?["id_token"] as? String).flatMap(decodeJWTPayload)
        let token = root.flatMap(CodexTokenIdentity.from(authJSON:))
        // The workspace the token was issued in, from its own claims when it
        // has them: one login can hold several workspaces that bill separately.
        let workspaceId = token?.workspaceId ?? tokens?["account_id"] as? String
        let email = codexEmail(from: claims) ?? token?.email
        let key = token?.planKey ?? workspaceId ?? "\(email ?? "?")|\(authFile.path)"
        let workspaceLabel = workspaceId.map { "ws " + String($0.prefix(8)) }
        return ProviderAccount(
            id: id, service: .codex, email: email,
            organizationName: workspaceLabel,
            identityKey: key, source: .file(path: authFile.path),
            isDefault: isDefault, chatGPTAccountId: workspaceId,
            configDir: authFile.deletingLastPathComponent().path,
            planName: PlanNames.chatGPT(planType: token?.planType),
            personKey: token?.userId,
            evidenceKey: token?.planKey
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

    /// Merges rows that are the same login, judged by credential rather than by
    /// declared name.
    ///
    /// `fingerprint` returns a stable, non-reversible digest of an account's
    /// token, or nil when the credential can't be read without prompting. Rows
    /// whose credentials are unreadable are left alone: guessing that two
    /// unreadable rows are the same login is how a real account gets hidden.
    ///
    /// The survivor keeps the file-backed source, so later reads stay
    /// prompt-free, but takes its name from a managed twin whose identity file
    /// is written alongside the credential and therefore matches it.
    public static func mergeByCredential(
        _ accounts: [ProviderAccount],
        fingerprint: (ProviderAccount) -> String?
    ) -> [ProviderAccount] {
        var groups: [String: [ProviderAccount]] = [:]
        var unreadable: [ProviderAccount] = []
        var order: [String] = []

        for account in accounts {
            guard let print = fingerprint(account) else {
                unreadable.append(account)
                continue
            }
            let key = "\(account.service.rawValue):\(print)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(account)
        }

        var merged: [ProviderAccount] = []
        for key in order {
            let group = groups[key]!
            guard group.count > 1 else {
                merged.append(group[0])
                continue
            }
            let preferred = group.first { if case .file = $0.source { return true } else { return false } } ?? group[0]
            let named = group.first { !$0.isDefault && $0.email != nil } ?? preferred
            merged.append(ProviderAccount(
                id: preferred.id,
                service: preferred.service,
                email: named.email,
                organizationName: named.organizationName,
                identityKey: named.identityKey,
                source: preferred.source,
                isDefault: preferred.isDefault,
                chatGPTAccountId: preferred.chatGPTAccountId ?? named.chatGPTAccountId,
                configDir: preferred.configDir,
                planName: named.planName ?? preferred.planName,
                personKey: named.personKey ?? preferred.personKey,
                evidenceKey: preferred.evidenceKey ?? named.evidenceKey,
                declaredPlanKey: named.declaredPlanKey ?? preferred.declaredPlanKey
            ))
        }

        return (merged + unreadable).sorted {
            $0.service == $1.service
                ? ($0.isDefault != $1.isDefault ? $0.isDefault : $0.label < $1.label)
                : $0.service.rawValue < $1.service.rawValue
        }
    }

    /// Collapses logins that the credential itself proves are one quota bucket.
    ///
    /// Two logins into the same workspace share every limit, so listing both
    /// doubles the row, the requests, and — once one of them goes stale — shows a
    /// broken twin of a healthy plan. Unlike `dedupe`, this trusts no declared
    /// name: `evidenceKey` comes from the token's own claims.
    ///
    /// The survivor holds the freshest credential; a tie goes to the CLI default,
    /// the login the user actually works in. Accounts without evidence pass
    /// through untouched.
    public static func mergeByEvidence(
        _ accounts: [ProviderAccount],
        freshness: (ProviderAccount) -> Date?
    ) -> [ProviderAccount] {
        func key(_ account: ProviderAccount) -> String? {
            account.evidenceKey.map { "\(account.service.rawValue):\($0)" }
        }
        var survivor: [String: ProviderAccount] = [:]
        for account in accounts {
            guard let key = key(account) else { continue }
            guard let current = survivor[key] else {
                survivor[key] = account
                continue
            }
            let candidateDate = freshness(account) ?? .distantPast
            let currentDate = freshness(current) ?? .distantPast
            if candidateDate > currentDate
                || (candidateDate == currentDate && account.isDefault && !current.isDefault) {
                survivor[key] = account
            }
        }
        return accounts.filter { account in
            guard let key = key(account) else { return true }
            return survivor[key]?.id == account.id
        }
    }

    /// Collapses only *exact* duplicates — the same config home found twice.
    ///
    /// Deliberately not by declared identity. Metadata goes stale: the CLI
    /// default's `~/.claude.json` can name one account while the credentials
    /// beside it belong to another, and treating that name as identity let a
    /// stale row shadow a real account — adding the genuine login was rejected
    /// as a "duplicate" of a row that wasn't it. Merging by credential is the
    /// caller's job (`AccountRegistry`), which can read tokens and compare what
    /// cannot go stale.
    static func dedupe(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
        var seen = Set<String>()
        var result: [ProviderAccount] = []
        for account in accounts.sorted(by: { lhs, rhs in
            lhs.isDefault && !rhs.isDefault
        }) where seen.insert(account.configDir ?? account.id).inserted {
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
