import Foundation
import Security
import AIUsageMeterCore

/// Which discovered accounts the user actually wants on screen, plus adding new
/// ones.
///
/// Accounts are *discovered*, not created, so "remove" can't mean deleting
/// someone's login — it hides the row. The one exception is an account this app
/// added itself, which owns its config home and can be deleted outright.
@MainActor
@Observable
final class AccountRegistry {
    static let shared = AccountRegistry()

    /// Outcome of the most recent "add account", shown in Settings.
    var addStatus: String?

    private let pinnedKey = "pinnedAccountIDs"
    private let hiddenKey = "hiddenAccountIDs"
    private let dismissedKey = "dismissedAccountIDs"
    private let aliasKey = "accountAliases"
    private let dismissedWorkspacesKey = "dismissedWorkspaceIDs"

    /// Discovered but not monitored — still listed, just switched off.
    private(set) var hidden: Set<String> {
        didSet { AppDefaults.userDefaults.set(Array(hidden), forKey: hiddenKey) }
    }

    /// Removed from the list entirely. Discovery would otherwise keep finding
    /// these every scan, so the choice has to be remembered rather than acted on
    /// once.
    private(set) var dismissed: Set<String> {
        didSet { AppDefaults.userDefaults.set(Array(dismissed), forKey: dismissedKey) }
    }

    /// ChatGPT workspaces the user doesn't want offered for connection.
    private(set) var dismissedWorkspaces: Set<String> {
        didSet { AppDefaults.userDefaults.set(Array(dismissedWorkspaces), forKey: dismissedWorkspacesKey) }
    }

    /// User-chosen names. "hebo1221 · ws 8fa88dcb" identifies nothing at a
    /// glance; "회사 결제" does.
    private(set) var aliases: [String: String] {
        didSet { AppDefaults.userDefaults.set(aliases, forKey: aliasKey) }
    }

    /// The account each provider shows in the menu bar, keyed by service.
    /// Without a choice the busiest account is used, which is a sensible default
    /// but jumps around as usage shifts; pinning makes it stay put.
    private(set) var pinned: [String: String] {
        didSet { AppDefaults.userDefaults.set(pinned, forKey: pinnedKey) }
    }

    private init() {
        pinned = AppDefaults.userDefaults.dictionary(forKey: pinnedKey) as? [String: String] ?? [:]
        hidden = Set(AppDefaults.userDefaults.stringArray(forKey: hiddenKey) ?? [])
        dismissed = Set(AppDefaults.userDefaults.stringArray(forKey: dismissedKey) ?? [])
        aliases = AppDefaults.userDefaults.dictionary(forKey: aliasKey) as? [String: String] ?? [:]
        dismissedWorkspaces = Set(AppDefaults.userDefaults.stringArray(forKey: dismissedWorkspacesKey) ?? [])
        // Removing the CLI's own login is no longer possible; forget any old
        // removal so "restore" doesn't count what is already back.
        dismissed = dismissed.filter { !$0.hasSuffix(":default") }
    }

    func dismissWorkspace(_ workspace: ChatGPTWorkspace) {
        dismissedWorkspaces.insert(workspace.id)
    }

    func isHidden(_ accountID: String) -> Bool { hidden.contains(accountID) }

    func setHidden(_ isHidden: Bool, for accountID: String) {
        if isHidden { hidden.insert(accountID) } else { hidden.remove(accountID) }
    }

    // MARK: - Menu-bar representative

    func pinnedAccountID(for service: ServiceType) -> String? {
        pinned[service.rawValue]
    }

    func isPinned(_ account: ProviderAccount) -> Bool {
        pinned[account.service.rawValue] == account.id
    }

    /// Tapping the pinned account again clears the choice and returns to
    /// "whichever is busiest".
    func togglePinned(_ account: ProviderAccount) {
        if pinned[account.service.rawValue] == account.id {
            pinned.removeValue(forKey: account.service.rawValue)
        } else {
            pinned[account.service.rawValue] = account.id
        }
    }

    // MARK: - Aliases

    func alias(for accountID: String) -> String? {
        aliases[accountID].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setAlias(_ alias: String, for accountID: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { aliases.removeValue(forKey: accountID) } else { aliases[accountID] = trimmed }
    }

    /// What the UI should call this account.
    func displayName(for account: ProviderAccount) -> String {
        alias(for: account.id) ?? account.label
    }

    /// Short form for tight spots such as the gauge caption.
    func shortDisplayName(for account: ProviderAccount) -> String {
        alias(for: account.id) ?? account.organizationName ?? account.shortName
    }

    // MARK: - Removal

    /// Removes an account from the list. A login this app created is deleted
    /// outright; anything else is only dismissed, because deleting another app's
    /// credentials isn't this app's call.
    func remove(_ account: ProviderAccount) {
        guard !account.isDefault else { return }
        if canDelete(account) {
            delete(account)
        } else {
            dismissed.insert(account.id)
        }
        hidden.remove(account.id)
    }

    func restoreDismissed() {
        dismissed.removeAll()
        dismissedWorkspaces.removeAll()
    }

    /// Everything the user has removed, for the "restore" count.
    var dismissedCount: Int { dismissed.count + dismissedWorkspaces.count }

    /// Accounts to monitor, in discovery order.
    func visibleAccounts() -> [ProviderAccount] {
        allAccounts().filter { !hidden.contains($0.id) }
    }

    func allAccounts() -> [ProviderAccount] {
        let accounts = collapseSharedCredentials(AccountDiscovery.discover())
        // The login the CLI itself uses is the plan in use, so it is always
        // listed; only other logins can be removed.
        return AccountDiscovery.mergeByEvidence(accounts, freshness: credentialExpiry)
            .filter { $0.isDefault || !dismissed.contains($0.id) }
    }

    /// When a file-backed Codex token expires, from its own claims — the
    /// fresher of two logins into one workspace is the one worth keeping.
    private func credentialExpiry(_ account: ProviderAccount) -> Date? {
        guard account.service == .codex, case .file(let path) = account.source,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return CodexTokenIdentity.from(authJSON: json)?.expiresAt
    }

    /// Merges rows that share a credential. The rule lives in Core (and is
    /// tested there); this only supplies the reader, since Keychain access
    /// belongs to the app layer.
    private func collapseSharedCredentials(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
        AccountDiscovery.mergeByCredential(accounts) { credentialFingerprint(for: $0) }
    }

    /// A stable fingerprint of the account's access token, or nil when reading it
    /// would prompt. Never returns or logs the token itself.
    private func credentialFingerprint(for account: ProviderAccount) -> String? {
        guard let raw = AccountCredentialStore.shared.rawCredentials(for: account, allowImport: false) else {
            return nil
        }
        let token: String?
        switch account.service {
        case .claude:
            token = ClaudeTokenRefresher.decode(raw)?.accessToken
        case .codex, .gemini:
            let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            token = (json?["tokens"] as? [String: Any])?["access_token"] as? String
        }
        guard let token, !token.isEmpty else { return nil }
        return SHA256Fingerprint.of(token)
    }

    /// True when this app owns the account's config home and can delete it.
    func canDelete(_ account: ProviderAccount) -> Bool {
        account.id.contains(":own:")
    }

    /// Deletes a self-managed account's config home. Only ever touches homes
    /// under our own directory — never the CLI's or another app's.
    func delete(_ account: ProviderAccount) {
        guard canDelete(account), let dir = account.configDir else { return }
        let root = AccountDiscovery.selfManagedRoot(
            home: FileManager.default.homeDirectoryForCurrentUser
        ).path
        guard dir.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(atPath: dir)
        hidden.remove(account.id)
        AccountCredentialStore.shared.forget(account)
    }

    /// Creates an empty config home and runs the provider's browser login into
    /// it. The resulting credentials land in a file this app owns, so the new
    /// account reads without a Keychain prompt.
    ///
    /// `workspace` pins a Codex login to one ChatGPT workspace. A token only
    /// ever reads the workspace it was issued in, so connecting a workspace the
    /// board found means a login made *for* that workspace.
    func addAccount(service: ServiceType, workspace: ChatGPTWorkspace? = nil,
                    onFinished: @escaping () -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = AccountDiscovery.newSelfManagedDir(for: service, home: home)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // A placeholder account carrying just the config home — enough for the
        // launcher to point the CLI at the right place.
        let pending = ProviderAccount(
            id: "pending:\(dir.lastPathComponent)",
            service: service,
            email: nil,
            organizationName: nil,
            identityKey: dir.path,
            source: .file(path: dir.appendingPathComponent(".credentials.json").path),
            isDefault: false,
            configDir: dir.path
        )

        addStatus = nil
        CLILoginLauncher.shared.login(service: service, account: pending,
                                      forcedWorkspace: workspace?.id) { [weak self] in
            // Nothing was written if the user abandoned the browser flow; don't
            // leave an empty home behind to be rediscovered as a broken account.
            self?.discardIfEmpty(dir, service: service)
            self?.reportAddOutcome(dir: dir, service: service)
            onFinished()
        }
    }

    /// Whether a workspace connection is running, so its button can show it.
    func isConnecting(_ workspace: ChatGPTWorkspace) -> Bool {
        CLILoginLauncher.shared.isRunning(workspaceLoginKey(workspace))
    }

    func workspaceLoginKey(_ workspace: ChatGPTWorkspace) -> String {
        "workspace:\(workspace.id)"
    }

    /// Says what the login actually produced.
    ///
    /// Signing in again usually lands on the account the browser is already
    /// signed into, which is one the list already has — dedup then removes the
    /// new row and "add account" looks like it silently failed. Naming the
    /// outcome is the difference between a bug and an explanation.
    private func reportAddOutcome(dir: URL, service: ServiceType) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            addStatus = "로그인이 완료되지 않았습니다."
            return
        }

        let discovered = AccountDiscovery.discover()
        guard let added = discovered.first(where: { $0.configDir == dir.path }) else {
            addStatus = "로그인 결과를 읽지 못했습니다."
            return
        }

        // Compare by credential, not by declared name: the CLI default can carry
        // a stale name, and matching on it rejected a genuinely new login as a
        // duplicate of a row that wasn't the same account at all.
        let addedPrint = credentialFingerprint(for: added)
        let existing = discovered.first { other in
            other.configDir != dir.path && other.service == added.service
                && addedPrint != nil && credentialFingerprint(for: other) == addedPrint
        }
        if let existing {
            // Our own redundant home — safe to remove, and leaving it would just
            // accumulate dead config dirs.
            try? fm.removeItem(at: dir)
            addStatus = "이미 등록된 계정입니다: \(displayName(for: existing))"
        } else {
            addStatus = "추가됨: \(displayName(for: added))"
        }
    }

    /// Removes the config home only when the login really produced nothing.
    ///
    /// The first version checked for a credentials *file* and deleted the home
    /// when it was missing — which is exactly what a successful Claude login
    /// looks like, because the CLI stores credentials in the Keychain under a
    /// name derived from the config dir. That threw away the account the user
    /// had just signed into and stranded its Keychain item.
    private func discardIfEmpty(_ dir: URL, service: ServiceType) {
        let fm = FileManager.default
        let succeeded: Bool
        switch service {
        case .claude:
            succeeded = fm.fileExists(atPath: dir.appendingPathComponent(".credentials.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path)
                || keychainItemExists(
                    service: AccountDiscovery.claudeScopedKeychainService(forConfigDir: dir.path),
                    account: NSUserName())
        case .codex:
            succeeded = fm.fileExists(atPath: dir.appendingPathComponent("auth.json").path)
        case .gemini:
            succeeded = true
        }
        if !succeeded {
            try? fm.removeItem(at: dir)
        }
    }

    /// Attribute-only lookup: asks whether the item exists without reading the
    /// secret, so it never triggers an ACL prompt.
    private func keychainItemExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}

import CryptoKit

/// Short, non-reversible fingerprint used to tell credentials apart without ever
/// holding or logging the secret.
enum SHA256Fingerprint {
    static func of(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
