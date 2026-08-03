import Foundation
import Security
import AIUsageMeterCore

/// Supplies each account's OAuth credentials, and — critically — stops macOS from
/// asking for the login password over and over.
///
/// A Keychain item's ACL lists the app that created it. Reading an item another
/// app created (Claude Code's, or a launcher's) makes securityd prompt, and the
/// "Always Allow" grant is fragile. So a foreign item is read exactly **once**
/// and immediately copied into an item this app owns; every read after that hits
/// our own copy and never prompts. Refreshed tokens are written only to our copy —
/// we never write back into another app's item.
///
/// File-backed accounts (Codex `auth.json`, Claude's default `.credentials.json`)
/// skip all of this: reading a file never prompts.
@MainActor
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()

    private let keychain = KeychainManager.shared
    /// In-memory cache so a refresh cycle doesn't re-read the same secret repeatedly.
    private var cache: [String: String] = [:]
    /// Accounts whose source refused a silent read. Retrying costs nothing when
    /// suppression works — but if it ever fails on some future OS, retrying is a
    /// password prompt every refresh cycle, so one refusal ends the attempts until
    /// the user asks for a refresh themselves.
    private var silentReadRefused: Set<String> = []

    private init() {}

    /// Raw credentials JSON for an account.
    /// - Parameter allowImport: whether a *first-time* import from a foreign
    ///   Keychain item may prompt. Background refreshes pass `false` so they stay
    ///   silent; a user-initiated refresh passes `true`.
    func rawCredentials(for account: ProviderAccount, allowImport: Bool) -> String? {
        switch account.source {
        case .file(let path):
            // Always read through: the CLI rewrites this file on its own refreshes.
            return try? String(contentsOfFile: path, encoding: .utf8)

        case .keychain(let service, let item):
            // Interactive path: re-read the source so our copy can't drift. The
            // owning app rotates these tokens, so a copy taken once and kept
            // forever eventually stops authenticating. This read may prompt the
            // first time; granting "Always Allow" puts this app on the item's ACL
            // and later reads — including background ones — stay silent.
            if allowImport, let fresh = readForeignKeychainItem(service: service, account: item) {
                silentReadRefused.remove(account.id)
                adopt(fresh, for: account)
                return fresh
            }

            let copy = cache[account.id] ?? (try? keychain.retrieve(for: ownedKey(for: account)))
            if let copy {
                cache[account.id] = copy
                if !isExpired(copy) { return copy }
            }

            // The copy is missing or has expired, so it is worth nothing as it
            // stands. An access token lives about eight hours; the owning app
            // refreshes the item and our snapshot of it simply rots, which is why
            // accounts went red overnight and stayed red until someone clicked.
            // Re-read the source with UI suppressed: if a previous grant put us on
            // the item's ACL this succeeds silently and the account heals itself,
            // and if it did not the call fails rather than raising a prompt behind
            // the user's back.
            if !silentReadRefused.contains(account.id) {
                if let fresh = readForeignKeychainItemSilently(service: service, account: item) {
                    adopt(fresh, for: account)
                    return fresh
                }
                silentReadRefused.insert(account.id)
            }
            // Hand back the stale copy anyway: an expired token produces a precise
            // "this login went stale" from the API, which beats "no credentials".
            return copy
        }
    }

    /// Re-reads an account's credentials right after its own CLI wrote them.
    ///
    /// Discarding the copy alone left a hole — the account had no readable
    /// credentials at all until something later asked interactively, so finishing
    /// a login put the row into a hard authentication error, which is the exact
    /// opposite of what just happened.
    func reimport(_ account: ProviderAccount) {
        forget(account)
        guard case .keychain(let service, let item) = account.source else { return }
        if let fresh = readForeignKeychainItem(service: service, account: item) {
            adopt(fresh, for: account)
        }
    }

    /// Whether stored credentials have passed their expiry.
    private func isExpired(_ json: String) -> Bool {
        guard let expiresAtMs = ClaudeTokenRefresher.decode(json)?.expiresAtMs else { return false }
        return Date().timeIntervalSince1970 * 1000 >= Double(expiresAtMs)
    }

    /// True when this account still needs its one-time import (i.e. asking to
    /// refresh it would surface a Keychain prompt).
    func needsImport(_ account: ProviderAccount) -> Bool {
        guard case .keychain = account.source else { return false }
        if cache[account.id] != nil { return false }
        return !keychain.exists(for: ownedKey(for: account))
    }

    /// Drops the cached copy so the next read re-imports. Used when an account's
    /// stored credentials stop working and the owning app has since re-authed.
    func refreshImportedCopy(for account: ProviderAccount) {
        forget(account)
    }

    func forget(_ account: ProviderAccount) {
        cache[account.id] = nil
        silentReadRefused.remove(account.id)
        try? keychain.delete(for: ownedKey(for: account))
    }

    // MARK: - Internals

    /// Namespaced so an account's copy can never collide with other settings.
    private func ownedKey(for account: ProviderAccount) -> String {
        "account-credentials:\(account.id)"
    }

    /// The one interactive read. Deliberately allows UI: this is the single
    /// prompt the user approves per account, after which the copy is ours.
    private func readForeignKeychainItem(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = String(data: data, encoding: .utf8), !json.isEmpty else {
            return nil
        }
        return json
    }

    /// The same read with every route to a password prompt closed off.
    ///
    /// Two locks because they cover different eras of the API: the modern
    /// `SecItem` layer honours `kSecUseAuthenticationUIFail`, while the ACL prompt
    /// on a login-keychain item predates it and answers to
    /// `SecKeychainSetUserInteractionAllowed`. A silent read is only worth
    /// attempting if it is genuinely silent — a background refresh that puts a
    /// password dialog on screen is the failure this whole class exists to avoid.
    private func readForeignKeychainItemSilently(service: String, account: String) -> String? {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = String(data: data, encoding: .utf8), !json.isEmpty else {
            return nil
        }
        return json
    }

    /// Replaces our copy with refreshed credentials. Only ever called for logins
    /// this app owns.
    func store(_ json: String, for account: ProviderAccount) {
        adopt(json, for: account)
    }

    private func adopt(_ json: String, for account: ProviderAccount) {
        cache[account.id] = json
        try? keychain.save(json, for: ownedKey(for: account))
    }
}
