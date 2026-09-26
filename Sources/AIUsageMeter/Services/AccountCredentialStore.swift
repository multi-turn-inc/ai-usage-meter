import Foundation
import Security
import AIUsageMeterCore

/// Supplies each account's OAuth credentials without ever putting a Keychain
/// password dialog on screen by itself.
///
/// Claude Code (and Orca) keep a login in a Keychain item written with the
/// `security` tool, and that item trusts the tool — not this app. So it is read
/// through the same tool (`SecurityToolReader`), which needs no grant at all,
/// and copied into an item this app owns; later reads hit the copy until the
/// source is written again. Refreshed tokens are written only to our copy —
/// never back into another app's item.
///
/// Every read here is silent. Should one ever be refused — an item neither the
/// tool nor this app may read unasked — the account reports that it needs
/// access, and the Keychain's dialog appears only when the user asks for it
/// (`grantAccess`). Dialogs that appeared on their own, on launch and on every
/// refresh, are what this class exists to prevent.
///
/// File-backed accounts (Codex `auth.json`, Claude's default `.credentials.json`)
/// skip all of this: reading a file never prompts.
@MainActor
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()

    private let keychain = KeychainManager.shared
    /// In-memory cache so a refresh cycle doesn't re-read the same secret repeatedly.
    private var cache: [String: String] = [:]
    /// Accounts whose source refused a silent read: they need the user's grant.
    private var silentReadRefused: Set<String> = []

    private init() {}

    /// Raw credentials JSON for an account, read without any prompt.
    func rawCredentials(for account: ProviderAccount) -> String? {
        switch account.source {
        case .file(let path):
            // Always read through: the CLI rewrites this file on its own refreshes.
            return try? String(contentsOfFile: path, encoding: .utf8)

        case .keychain(let service, let item):
            let copy = ownedCopy(for: account)

            // A write to the source after our copy was taken supersedes it: the
            // user signed in again, or the CLI renewed a login it owns. A login
            // this app created, though, is renewed by this app alone, and our copy
            // holds the result — the CLI's item beside it was written once, at
            // sign-in, and still carries the refresh token our first renewal
            // spent; re-adopting it is what killed these logins within a day. So
            // that copy stands until the source is newer, even past expiry, and
            // the caller renews it.
            let usable = { (copy: String) in account.isSelfManaged || !self.isExpired(copy) }
            if let copy, usable(copy), !sourceIsNewer(account, service: service, item: item) {
                return copy
            }

            // Missing, expired or superseded: read the source again, silently.
            if !silentReadRefused.contains(account.id) {
                if let fresh = readForeignKeychainItemSilently(service: service, account: item) {
                    adopt(fresh, for: account)
                    return fresh
                }
                silentReadRefused.insert(account.id)
            }
            // Without access to the source, an expired copy of a login its CLI
            // renews would only produce a misleading "token expired"; report the
            // missing access instead.
            return copy.flatMap { usable($0) ? $0 : nil }
        }
    }

    /// Reads an account's source because the user asked — the "allow Keychain
    /// access" button — or has just signed in from this app. The silent routes
    /// go first, and for a Claude Code login one of them always works; the
    /// Keychain's own dialog is the last resort, for an item nothing here may
    /// read unasked. "Always Allow" there lasts: the app is signed the same way
    /// across updates, so the grant still matches after the next one.
    @discardableResult
    func grantAccess(for account: ProviderAccount) -> Bool {
        guard case .keychain(let service, let item) = account.source else { return true }
        guard let fresh = readForeignKeychainItemSilently(service: service, account: item)
                ?? readForeignKeychainItem(service: service, account: item) else { return false }
        silentReadRefused.remove(account.id)
        adopt(fresh, for: account)
        return true
    }

    /// Re-reads an account's credentials right after its own CLI wrote them.
    ///
    /// Discarding the copy alone left a hole — the account had no readable
    /// credentials at all until something later asked, so finishing a login put
    /// the row into an authentication error, the opposite of what just happened.
    func reimport(_ account: ProviderAccount) {
        forget(account)
        grantAccess(for: account)
    }

    /// Whether stored credentials have passed their expiry.
    private func isExpired(_ json: String) -> Bool {
        guard let expiresAtMs = ClaudeTokenRefresher.decode(json)?.expiresAtMs else { return false }
        return Date().timeIntervalSince1970 * 1000 >= Double(expiresAtMs)
    }

    /// True when this account can't be read until the user grants access.
    func needsImport(_ account: ProviderAccount) -> Bool {
        guard case .keychain = account.source else { return false }
        if silentReadRefused.contains(account.id) { return true }
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
        try? keychain.delete(for: legacyKey(for: account))
    }

    // MARK: - Internals

    /// Our copy: from memory, else our item, else — once — the item an earlier
    /// version kept under the old name, moved across without a prompt.
    private func ownedCopy(for account: ProviderAccount) -> String? {
        if let cached = cache[account.id] { return cached }
        if let stored = try? keychain.retrieve(for: ownedKey(for: account)) {
            cache[account.id] = stored
            return stored
        }
        if let legacy = try? keychain.retrieve(for: legacyKey(for: account)) {
            adopt(legacy, for: account)
            try? keychain.delete(for: legacyKey(for: account))
            return legacy
        }
        return nil
    }

    /// Whether the source item was written after our copy. Attributes only.
    private func sourceIsNewer(_ account: ProviderAccount, service: String, item: String) -> Bool {
        guard let sourceWritten = AccountDiscovery.defaultKeychainModified(service, item),
              let ownWritten = ownedItemModified(account) else { return false }
        return sourceWritten > ownWritten
    }

    /// When our copy was last written. Attribute-only: never reads the secret.
    private func ownedItemModified(_ account: ProviderAccount) -> Date? {
        let query = KeychainSilence.readQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.aiusagemeter",
            kSecAttrAccount as String: ownedKey(for: account),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        guard KeychainSilence.run({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return (attributes[kSecAttrModificationDate as String] as? Date)
            ?? (attributes[kSecAttrCreationDate as String] as? Date)
    }

    /// Our copies are kept apart per signing identity. An item can be read
    /// without a prompt only by code meeting its creator's requirement, so a
    /// differently signed build — an ad-hoc development build, or a copy an old
    /// updater re-signed — writing into the shared item would lock the real
    /// build out of it, and each lockout was a password dialog.
    private static let signingNamespace: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return "unsigned" }
        if let team = details[kSecCodeInfoTeamIdentifier as String] as? String { return team }
        if let unique = details[kSecCodeInfoUnique as String] as? Data {
            return "adhoc-" + unique.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        return "unsigned"
    }()

    private func ownedKey(for account: ProviderAccount) -> String {
        "account-credentials.\(Self.signingNamespace):\(account.id)"
    }

    /// Where versions up to 4.5.0 kept the copy, shared by every signature.
    private func legacyKey(for account: ProviderAccount) -> String {
        "account-credentials:\(account.id)"
    }

    /// The one read that may prompt. Called only from `grantAccess`, after the
    /// silent routes have failed.
    private func readForeignKeychainItem(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard KeychainSilence.allowingPrompt({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
              let data = result as? Data,
              let json = String(data: data, encoding: .utf8), !json.isEmpty else {
            return nil
        }
        return json
    }

    /// The same read with every route to a dialog closed off: in-process where
    /// an earlier grant covers this app, otherwise through the tool that wrote
    /// the item.
    private func readForeignKeychainItemSilently(service: String, account: String) -> String? {
        let query = KeychainSilence.readQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        if KeychainSilence.run({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
           let data = result as? Data,
           let json = String(data: data, encoding: .utf8), !json.isEmpty {
            return json
        }
        return SecurityToolReader.read(service: service, account: account)
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
