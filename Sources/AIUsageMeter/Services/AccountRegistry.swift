import Foundation
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

    private let hiddenKey = "hiddenAccountIDs"
    private let dismissedKey = "dismissedAccountIDs"
    private let aliasKey = "accountAliases"

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

    /// User-chosen names. "hebo1221 · ws 8fa88dcb" identifies nothing at a
    /// glance; "회사 결제" does.
    private(set) var aliases: [String: String] {
        didSet { AppDefaults.userDefaults.set(aliases, forKey: aliasKey) }
    }

    private init() {
        hidden = Set(AppDefaults.userDefaults.stringArray(forKey: hiddenKey) ?? [])
        dismissed = Set(AppDefaults.userDefaults.stringArray(forKey: dismissedKey) ?? [])
        aliases = AppDefaults.userDefaults.dictionary(forKey: aliasKey) as? [String: String] ?? [:]
    }

    func isHidden(_ accountID: String) -> Bool { hidden.contains(accountID) }

    func setHidden(_ isHidden: Bool, for accountID: String) {
        if isHidden { hidden.insert(accountID) } else { hidden.remove(accountID) }
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
        if canDelete(account) {
            delete(account)
        } else {
            dismissed.insert(account.id)
        }
        hidden.remove(account.id)
    }

    func restoreDismissed() {
        dismissed.removeAll()
    }

    /// Accounts to monitor, in discovery order.
    func visibleAccounts() -> [ProviderAccount] {
        allAccounts().filter { !hidden.contains($0.id) }
    }

    func allAccounts() -> [ProviderAccount] {
        collapseSharedCredentials(AccountDiscovery.discover())
            .filter { !dismissed.contains($0.id) }
    }

    /// Collapses rows that turn out to be the *same login*.
    ///
    /// Declared identity can lie. A launcher that switches the active account
    /// rewrites `~/.claude/.credentials.json` but not the `~/.claude.json`
    /// metadata beside it, so the default row can carry one account's name and
    /// another account's token — which showed up as two rows reporting byte-for-
    /// byte identical usage. The credential is the only thing that can't be
    /// stale, so identical tokens mean one account.
    ///
    /// The surviving row keeps the file-backed source (reading it never prompts)
    /// but takes its name from the managed twin, whose identity file is written
    /// alongside the credential and therefore matches it.
    private func collapseSharedCredentials(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
        var byFingerprint: [String: [ProviderAccount]] = [:]
        var unfingerprinted: [ProviderAccount] = []

        for account in accounts {
            if let fingerprint = credentialFingerprint(for: account) {
                byFingerprint[fingerprint, default: []].append(account)
            } else {
                unfingerprinted.append(account)
            }
        }

        var collapsed: [ProviderAccount] = []
        for group in byFingerprint.values {
            guard group.count > 1 else {
                collapsed.append(group[0])
                continue
            }
            let preferred = group.first { if case .file = $0.source { return true } else { return false } } ?? group[0]
            let named = group.first { !$0.isDefault && $0.email != nil } ?? preferred
            collapsed.append(ProviderAccount(
                id: preferred.id,
                service: preferred.service,
                email: named.email,
                organizationName: named.organizationName,
                identityKey: named.identityKey,
                source: preferred.source,
                isDefault: preferred.isDefault,
                chatGPTAccountId: preferred.chatGPTAccountId ?? named.chatGPTAccountId,
                configDir: preferred.configDir
            ))
        }

        let ordered = collapsed + unfingerprinted
        return ordered.sorted {
            $0.service == $1.service
                ? ($0.isDefault != $1.isDefault ? $0.isDefault : $0.label < $1.label)
                : $0.service.rawValue < $1.service.rawValue
        }
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
        return "\(account.service.rawValue):\(SHA256Fingerprint.of(token))"
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
    func addAccount(service: ServiceType, onFinished: @escaping () -> Void) {
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

        CLILoginLauncher.shared.login(service: service, account: pending) { [weak self] in
            // Nothing was written if the user abandoned the browser flow; don't
            // leave an empty home behind to be rediscovered as a broken account.
            self?.discardIfEmpty(dir, service: service)
            onFinished()
        }
    }

    private func discardIfEmpty(_ dir: URL, service: ServiceType) {
        let marker = switch service {
        case .claude: dir.appendingPathComponent(".credentials.json")
        case .codex: dir.appendingPathComponent("auth.json")
        case .gemini: dir
        }
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: dir)
        }
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
