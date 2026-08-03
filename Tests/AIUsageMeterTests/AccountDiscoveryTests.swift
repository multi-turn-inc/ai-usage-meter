import XCTest
@testable import AIUsageMeterCore

/// Builds a fake home tree: { relative path : file contents }.
private func makeHome(_ files: [String: String]) -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (relative, content) in files {
        let dest = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! content.write(to: dest, atomically: true, encoding: .utf8)
    }
    return root
}

/// A JWT whose payload carries `email`. Signature is never checked.
private func idToken(email: String) -> String {
    let payload = #"{"email":"\#(email)"}"#
    let b64 = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(b64).signature"
}

private func claudeIdentity(email: String, orgUuid: String, orgName: String) -> String {
    #"{"emailAddress":"\#(email)","organizationUuid":"\#(orgUuid)","organizationName":"\#(orgName)"}"#
}

private func codexAuth(email: String, accountId: String) -> String {
    #"{"tokens":{"id_token":"\#(idToken(email: email))","access_token":"a","refresh_token":"r","account_id":"\#(accountId)"}}"#
}

final class AccountDiscoveryTests: XCTestCase {

    private let orca = "Library/Application Support/orca"

    // MARK: Identity is email + organization, not email alone
    //
    // The regression this guards: one address commonly spans a personal org and a
    // team org. Those bill and rate-limit separately, so collapsing them by email
    // would silently hide a paid account the user expects to see.
    func test_sameEmailDifferentOrgs_areSeparateAccounts() {
        let home = makeHome([
            "\(orca)/claude-accounts/aaa/auth/oauth-account.json":
                claudeIdentity(email: "me@example.com", orgUuid: "org-1", orgName: "Personal Co"),
            "\(orca)/claude-accounts/bbb/auth/oauth-account.json":
                claudeIdentity(email: "me@example.com", orgUuid: "org-2", orgName: "Team Co"),
        ])

        let accounts = AccountDiscovery.discoverClaude(home: home)

        XCTAssertEqual(accounts.count, 2, "Same email in two orgs must stay two accounts")
        XCTAssertEqual(Set(accounts.map(\.organizationName)), ["Personal Co", "Team Co"])
    }

    // MARK: Discovery keeps rows apart until a credential proves they're one
    //
    // Two homes declaring the same email and org are still two homes. They may
    // hold different logins — declared metadata goes stale — so discovery lists
    // both and merging waits for evidence.
    func test_sameDeclaredIdentityInTwoHomes_bothDiscovered() {
        let identity = claudeIdentity(email: "me@example.com", orgUuid: "org-1", orgName: "Only Co")
        let home = makeHome([
            "\(orca)/claude-accounts/aaa/auth/oauth-account.json": identity,
            "\(orca)/claude-accounts/bbb/auth/oauth-account.json": identity,
        ])

        XCTAssertEqual(AccountDiscovery.discoverClaude(home: home).count, 2)
    }



    // MARK: Managed Claude accounts read tokens from Orca's Keychain service
    func test_managedClaudeAccount_usesOrcaKeychainSourceKeyedByUUID() {
        let home = makeHome([
            "\(orca)/claude-accounts/uuid-1/auth/oauth-account.json":
                claudeIdentity(email: "me@example.com", orgUuid: "org-1", orgName: "Co"),
        ])

        guard let account = AccountDiscovery.discoverClaude(home: home).first else {
            return XCTFail("No account discovered")
        }
        XCTAssertEqual(account.source,
                       .keychain(service: AccountDiscovery.orcaClaudeKeychainService, account: "uuid-1"))
    }

    // MARK: A personal org gets a compact label instead of "<email>'s Organization"
    func test_personalOrgName_isShortened() {
        let home = makeHome([
            "\(orca)/claude-accounts/aaa/auth/oauth-account.json":
                claudeIdentity(email: "me@example.com", orgUuid: "org-1",
                               orgName: "me@example.com's Organization"),
        ])

        XCTAssertEqual(AccountDiscovery.discoverClaude(home: home).first?.label, "me · Personal")
    }

    // MARK: Codex identity is the workspace id — one login, several workspaces
    func test_codex_sameEmailDifferentWorkspaces_areSeparateAccounts() {
        let home = makeHome([
            ".codex/auth.json": codexAuth(email: "me@example.com", accountId: "ws-1"),
            "\(orca)/codex-accounts/aaa/home/auth.json":
                codexAuth(email: "me@example.com", accountId: "ws-2"),
        ])

        let accounts = AccountDiscovery.discoverCodex(home: home)

        XCTAssertEqual(accounts.count, 2, "Distinct ChatGPT workspaces are distinct accounts")
        XCTAssertEqual(Set(accounts.compactMap(\.chatGPTAccountId)), ["ws-1", "ws-2"])
    }



    // MARK: Codex credentials always come from a file — never the Keychain
    func test_codexAccounts_areAlwaysFileBacked() {
        let home = makeHome([
            "\(orca)/codex-accounts/aaa/home/auth.json":
                codexAuth(email: "me@example.com", accountId: "ws-1"),
        ])

        guard case .file = AccountDiscovery.discoverCodex(home: home).first?.source else {
            return XCTFail("Codex credentials must be read from auth.json, never the Keychain")
        }
    }

    // MARK: The default account follows whichever store was written last
    //
    // The regression this guards: Claude Code 2.1 moved credentials from
    // ~/.claude/.credentials.json into a scoped Keychain item and stopped writing
    // the file. Machines upgraded from an older version still have that file,
    // frozen at the token it held on upgrade day. Preferring it because it exists
    // reports a login that expired long ago and cannot recover — signing in again
    // writes the Keychain item, which was never read.
    func test_defaultAccount_prefersKeychainWhenItWasWrittenMoreRecently() {
        let home = makeHome([".claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"old"}}"#])
        let configDir = home.appendingPathComponent(".claude").path
        let expected = AccountDiscovery.claudeScopedKeychainService(forConfigDir: configDir)

        let accounts = AccountDiscovery.discoverClaude(home: home) { service, _ in
            service == expected ? Date().addingTimeInterval(3600) : nil
        }

        XCTAssertEqual(accounts.first?.source, .keychain(service: expected, account: NSUserName()))
    }

    func test_defaultAccount_keepsTheFileWhileItIsTheFresherStore() {
        let home = makeHome([".claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"live"}}"#])
        let credentials = home.appendingPathComponent(".claude/.credentials.json").path

        let accounts = AccountDiscovery.discoverClaude(home: home) { _, _ in
            Date().addingTimeInterval(-86_400)
        }

        XCTAssertEqual(accounts.first?.source, .file(path: credentials),
                       "A current file must not be abandoned for an older Keychain item")
    }

    // MARK: A machine that only ever had the Keychain item still has an account
    func test_defaultAccount_isFoundWithNoCredentialsFileAtAll() {
        let home = makeHome([".claude.json": #"{"oauthAccount":{"emailAddress":"me@example.com"}}"#])
        let expected = AccountDiscovery.claudeScopedKeychainService(
            forConfigDir: home.appendingPathComponent(".claude").path)

        let accounts = AccountDiscovery.discoverClaude(home: home) { service, _ in
            service == expected ? Date() : nil
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.email, "me@example.com")
    }

    // MARK: An empty machine yields no accounts rather than placeholders
    func test_noCredentials_yieldsNoAccounts() {
        let home = makeHome([:])
        XCTAssertTrue(AccountDiscovery.discover(home: home).isEmpty)
    }
}

final class ClaudeKeychainScopeTests: XCTestCase {

    // MARK: The Keychain name for a config dir must match what Claude Code writes
    //
    // Claude Code 2.1+ stores credentials under
    // "Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>".
    // Getting this wrong is silent: a freshly added account looks like a failed
    // login because its credentials appear to be missing. The expected value
    // below was read off a real machine, where the item for /Users/junghunkim/
    // .claude is "Claude Code-credentials-bb407e4b".
    func test_scopedServiceName_matchesClaudeCodesScheme() {
        XCTAssertEqual(
            AccountDiscovery.claudeScopedKeychainService(forConfigDir: "/Users/junghunkim/.claude"),
            "Claude Code-credentials-bb407e4b"
        )
    }

    func test_scopedServiceName_differsPerConfigDir() {
        let a = AccountDiscovery.claudeScopedKeychainService(forConfigDir: "/tmp/account-a")
        let b = AccountDiscovery.claudeScopedKeychainService(forConfigDir: "/tmp/account-b")
        XCTAssertNotEqual(a, b, "Each config home must map to its own Keychain item")
    }

    // MARK: A self-added account is found even though its credentials are in the
    // Keychain rather than a file — the case that made "add account" fail.
    func test_selfManagedClaudeAccount_isFoundWithKeychainCredentials() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("Library/Application Support/TokenBurn/accounts/claude/acct-1")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Claude Code writes this identity file; credentials go to the Keychain.
        try! #"{"oauthAccount":{"emailAddress":"new@example.com","organizationUuid":"org-9","organizationName":"New Co"}}"#
            .write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let accounts = AccountDiscovery.discoverClaude(home: root)

        XCTAssertEqual(accounts.count, 1, "A Keychain-backed self-added account must still be discovered")
        XCTAssertEqual(accounts.first?.email, "new@example.com")
        XCTAssertEqual(
            accounts.first?.source,
            .keychain(service: AccountDiscovery.claudeScopedKeychainService(forConfigDir: dir.path),
                      account: NSUserName())
        )
    }
}

/// The merge rule, exercised with a stubbed credential reader so it can be
/// tested without a Keychain.
final class CredentialMergeTests: XCTestCase {

    private func account(_ id: String, email: String?, org: String?, isDefault: Bool,
                         source: ProviderAccount.CredentialSource) -> ProviderAccount {
        ProviderAccount(id: id, service: .claude, email: email, organizationName: org,
                        identityKey: "\(email ?? "?")|\(org ?? "?")", source: source,
                        isDefault: isDefault, configDir: "/tmp/\(id)")
    }

    // MARK: Same token means one account, whatever the rows claim to be called
    func test_identicalTokens_mergeIntoOneRow() {
        let a = account("claude:default", email: "stale@example.com", org: "Stale Co",
                        isDefault: true, source: .file(path: "/tmp/a"))
        let b = account("claude:orca:x", email: "real@example.com", org: "Real Co",
                        isDefault: false, source: .keychain(service: "svc", account: "x"))

        let merged = AccountDiscovery.mergeByCredential([a, b]) { _ in "same-token" }

        XCTAssertEqual(merged.count, 1)
        // Keeps the prompt-free source…
        guard case .file = merged[0].source else { return XCTFail("Expected the file-backed source") }
        // …but the name that actually matches the credential.
        XCTAssertEqual(merged[0].email, "real@example.com")
        XCTAssertEqual(merged[0].organizationName, "Real Co")
    }

    // MARK: A genuinely different login is never folded into a stale-named row
    //
    // The regression: the CLI default declared one account while holding
    // another's token, so adding the real account was rejected as a duplicate
    // and its row disappeared.
    func test_differentTokens_staySeparateEvenWhenNamesCollide() {
        let stale = account("claude:default", email: "me@example.com", org: "Silla",
                            isDefault: true, source: .file(path: "/tmp/a"))
        let real = account("claude:own:new", email: "me@example.com", org: "Silla",
                           isDefault: false, source: .keychain(service: "svc", account: "n"))

        let merged = AccountDiscovery.mergeByCredential([stale, real]) { account in
            account.id == "claude:default" ? "token-overedge" : "token-silla"
        }

        XCTAssertEqual(merged.count, 2, "Different credentials are different accounts")
    }

    // MARK: Unreadable credentials are never guessed to be the same account
    func test_unreadableCredentials_areLeftAlone() {
        let a = account("claude:orca:a", email: "a@example.com", org: "A",
                        isDefault: false, source: .keychain(service: "svc", account: "a"))
        let b = account("claude:orca:b", email: "b@example.com", org: "B",
                        isDefault: false, source: .keychain(service: "svc", account: "b"))

        XCTAssertEqual(AccountDiscovery.mergeByCredential([a, b]) { _ in nil }.count, 2)
    }
}
