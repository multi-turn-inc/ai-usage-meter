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

    // MARK: Genuine duplicates (same email AND same org) collapse to one
    func test_sameEmailSameOrg_collapsesToOneAccount() {
        let identity = claudeIdentity(email: "me@example.com", orgUuid: "org-1", orgName: "Only Co")
        let home = makeHome([
            "\(orca)/claude-accounts/aaa/auth/oauth-account.json": identity,
            "\(orca)/claude-accounts/bbb/auth/oauth-account.json": identity,
        ])

        XCTAssertEqual(AccountDiscovery.discoverClaude(home: home).count, 1)
    }

    // MARK: The file-backed CLI default wins over a Keychain-backed duplicate
    //
    // Reading the default's credentials file never prompts; reading another app's
    // Keychain item does. When both point at the same login, keep the quiet one.
    func test_duplicateAcrossDefaultAndManaged_prefersFileBackedDefault() {
        let home = makeHome([
            ".claude/.credentials.json": "{}",
            ".claude.json":
                #"{"oauthAccount":{"emailAddress":"me@example.com","organizationUuid":"org-1","organizationName":"Only Co"}}"#,
            "\(orca)/claude-accounts/aaa/auth/oauth-account.json":
                claudeIdentity(email: "me@example.com", orgUuid: "org-1", orgName: "Only Co"),
        ])

        let accounts = AccountDiscovery.discoverClaude(home: home)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, "claude:default")
        guard case .file = accounts.first?.source else {
            return XCTFail("Expected the file-backed source, got \(String(describing: accounts.first?.source))")
        }
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

    // MARK: Same workspace reachable twice collapses, default preferred
    func test_codex_sameWorkspaceTwice_collapsesToDefault() {
        let auth = codexAuth(email: "me@example.com", accountId: "ws-1")
        let home = makeHome([
            ".codex/auth.json": auth,
            "\(orca)/codex-accounts/aaa/home/auth.json": auth,
        ])

        let accounts = AccountDiscovery.discoverCodex(home: home)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, "codex:default")
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

    // MARK: An empty machine yields no accounts rather than placeholders
    func test_noCredentials_yieldsNoAccounts() {
        let home = makeHome([:])
        XCTAssertTrue(AccountDiscovery.discover(home: home).isEmpty)
    }
}
