import XCTest
@testable import AIUsageMeterCore

private func jwt(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(b64).signature"
}

private func codexAuth(user: String, workspace: String, plan: String, exp: Int) -> String {
    let access = jwt([
        "exp": exp,
        "https://api.openai.com/auth": [
            "chatgpt_user_id": user, "chatgpt_account_id": workspace, "chatgpt_plan_type": plan,
        ],
    ])
    return #"{"tokens":{"access_token":"\#(access)","account_id":"\#(workspace)"}}"#
}

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

final class EvidenceMergeTests: XCTestCase {

    private let own = "Library/Application Support/TokenBurn/accounts/codex"

    // Discovery reads the plan and the bucket from the token's claims.
    func test_codexDiscoveryTakesIdentityFromTokenClaims() {
        let home = makeHome([
            ".codex/auth.json": codexAuth(user: "u1", workspace: "ws-a", plan: "self_serve_business_prolite", exp: 2_000),
        ])

        let account = AccountDiscovery.discoverCodex(home: home).first!

        XCTAssertEqual(account.evidenceKey, "u1|ws-a")
        XCTAssertEqual(account.personKey, "u1")
        XCTAssertEqual(account.planName, "Business")
        XCTAssertEqual(account.chatGPTAccountId, "ws-a")
    }

    // The regression this guards: a second login into the workspace the CLI
    // already uses, left to expire, showed up as a broken twin of a healthy
    // plan. One bucket is one row, and it's the live login that stays.
    func test_twoLoginsIntoOneWorkspace_keepTheFreshestCredential() {
        let home = makeHome([
            ".codex/auth.json": codexAuth(user: "u1", workspace: "ws-a", plan: "team", exp: 9_000),
            "\(own)/X/auth.json": codexAuth(user: "u1", workspace: "ws-a", plan: "team", exp: 1_000),
            "\(own)/Y/auth.json": codexAuth(user: "u1", workspace: "ws-b", plan: "pro", exp: 1_000),
        ])
        let accounts = AccountDiscovery.discoverCodex(home: home)
        let expiry = Dictionary(uniqueKeysWithValues: accounts.map { account -> (String, Date?) in
            let path = account.configDir! + "/auth.json"
            let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
            return (account.id, CodexTokenIdentity.from(authJSON: json)?.expiresAt)
        })

        let merged = AccountDiscovery.mergeByEvidence(accounts) { expiry[$0.id] ?? nil }

        XCTAssertEqual(merged.count, 2, "Same member in the same workspace is one plan")
        XCTAssertEqual(Set(merged.map(\.evidenceKey)), ["u1|ws-a", "u1|ws-b"])
        XCTAssertTrue(merged.contains { $0.id == "codex:default" }, "The live login survives")
    }

    // Different members of one workspace each have their own limits.
    func test_differentMembersOfOneWorkspace_stayApart() {
        let a = ProviderAccount(id: "a", service: .codex, email: nil, organizationName: nil,
                                identityKey: "a", source: .file(path: "/a"), isDefault: false,
                                evidenceKey: "u1|ws-a")
        let b = ProviderAccount(id: "b", service: .codex, email: nil, organizationName: nil,
                                identityKey: "b", source: .file(path: "/b"), isDefault: false,
                                evidenceKey: "u2|ws-a")

        XCTAssertEqual(AccountDiscovery.mergeByEvidence([a, b]) { _ in nil }.count, 2)
    }

    // Without evidence nothing is merged — declared names are not proof.
    func test_accountsWithoutEvidencePassThrough() {
        let a = ProviderAccount(id: "a", service: .claude, email: "me@example.com", organizationName: "Co",
                                identityKey: "same", source: .file(path: "/a"), isDefault: false)
        let b = ProviderAccount(id: "b", service: .claude, email: "me@example.com", organizationName: "Co",
                                identityKey: "same", source: .file(path: "/b"), isDefault: false)

        XCTAssertEqual(AccountDiscovery.mergeByEvidence([a, b]) { _ in nil }.count, 2)
    }
}
