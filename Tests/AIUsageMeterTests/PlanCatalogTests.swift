import XCTest
@testable import AIUsageMeterCore

/// An unsigned JWT with the given payload — only the payload is ever read.
private func jwt(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(b64).signature"
}

final class PlanCatalogTests: XCTestCase {

    // MARK: Plan names

    func test_claudePlanNames() {
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_pro", rateLimitTier: nil), "Pro")
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_enterprise", rateLimitTier: nil), "Enterprise")
        XCTAssertNil(PlanNames.claude(organizationType: nil, rateLimitTier: nil))
    }

    // A Team seat's limits come from the seat's own tier, not the org's.
    func test_teamSeatIsNamedByItsSeatTier() {
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_team", rateLimitTier: "default_raven",
                                        userRateLimitTier: "default_claude_max_5x"), "Team 5x")
        XCTAssertEqual(PlanNames.claude(organizationType: "claude_team", rateLimitTier: "default_raven"), "Team")
    }

    func test_chatGPTPlanNames() {
        XCTAssertEqual(PlanNames.chatGPT(planType: "self_serve_business_prolite"), "Business")
        XCTAssertEqual(PlanNames.chatGPT(planType: "team"), "Business")
        XCTAssertEqual(PlanNames.chatGPT(planType: "pro"), "Pro")
        XCTAssertEqual(PlanNames.chatGPT(planType: "plus"), "Plus")
        XCTAssertEqual(PlanNames.chatGPT(planType: "enterprise"), "Enterprise")
        XCTAssertNil(PlanNames.chatGPT(planType: nil))
    }

    // MARK: Workspace directory

    // One login, three accounts: two workspaces and a personal Pro. The
    // "default" key repeats one of them and must not become a fourth.
    func test_workspaceDirectoryListsEveryAccountOnce() {
        let payload = """
        {"account_ordering":["ws-a","ws-b","personal-1"],
         "accounts":{
          "ws-a":{"account":{"account_id":"ws-a","structure":"workspace","name":"Acme","plan_type":"self_serve_business_prolite"}},
          "ws-b":{"account":{"account_id":"ws-b","structure":"workspace","name":"Beta Co","plan_type":"team"}},
          "personal-1":{"account":{"account_id":"personal-1","structure":"personal","name":null,"plan_type":"pro"}},
          "default":{"account":{"account_id":"personal-1","structure":"personal","plan_type":"pro"}},
          "gone":{"account":{"account_id":"gone","structure":"workspace","name":"Old","is_deactivated":true}}
         }}
        """

        let workspaces = ChatGPTWorkspaceDirectory.parse(Data(payload.utf8))

        XCTAssertEqual(workspaces.map(\.id), ["ws-a", "ws-b", "personal-1"])
        XCTAssertEqual(workspaces.map(\.displayName), ["Acme", "Beta Co", "Personal"])
        XCTAssertEqual(workspaces.map(\.planName), ["Business", "Business", "Pro"])
        XCTAssertTrue(workspaces[2].isPersonal)
    }

    // MARK: Codex usage

    // The shape the backend returns today: a single weekly primary window and a
    // separate credit allowance that is nearly spent.
    func test_codexUsageReadsWeeklyWindowAndSpendAllowance() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = """
        {"plan_type":"self_serve_business_prolite",
         "rate_limit":{"allowed":true,"limit_reached":false,
           "primary_window":{"used_percent":32,"limit_window_seconds":604800,"reset_after_seconds":592045,"reset_at":1790927214},
           "secondary_window":null},
         "spend_control":{"reached":false,
           "individual_limit":{"unit":"credit","limit":"10000","used":"9451.94","used_percent":95,"reset_after_seconds":477630,"reset_at":1790812800}}}
        """

        let snapshot = CodexUsageSnapshot.parse(Data(payload.utf8), now: now)!

        XCTAssertEqual(snapshot.planType, "self_serve_business_prolite")
        XCTAssertEqual(snapshot.primary?.usedPercent, 32)
        XCTAssertEqual(snapshot.primary?.windowSeconds, 604_800)
        XCTAssertEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_790_927_214))
        XCTAssertNil(snapshot.secondary)
        XCTAssertEqual(snapshot.spend?.usedPercent, 95)
        XCTAssertEqual(snapshot.spend?.resetsAt, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertFalse(snapshot.limitReached)
    }

    // Without an explicit percentage the allowance is worked out from the
    // amounts, which arrive as strings.
    func test_spendPercentFallsBackToAmounts() {
        let payload = #"{"rate_limit":null,"spend_control":{"individual_limit":{"limit":"200","used":"50","reset_after_seconds":60}}}"#
        let now = Date(timeIntervalSince1970: 1_000)

        let snapshot = CodexUsageSnapshot.parse(Data(payload.utf8), now: now)!

        XCTAssertEqual(snapshot.spend?.usedPercent, 25)
        XCTAssertEqual(snapshot.spend?.resetsAt, Date(timeIntervalSince1970: 1_060))
    }

    func test_codexRefusalIsReported() {
        let refused = #"{"rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100}}}"#
        let spent = #"{"rate_limit":{"primary_window":{"used_percent":10}},"spend_control":{"reached":true}}"#

        XCTAssertTrue(CodexUsageSnapshot.parse(Data(refused.utf8))!.limitReached)
        XCTAssertTrue(CodexUsageSnapshot.parse(Data(spent.utf8))!.limitReached)
    }

    func test_codexUsageWithoutLimitsIsNotASnapshot() {
        XCTAssertNil(CodexUsageSnapshot.parse(Data(#"{"plan_type":"pro"}"#.utf8)))
    }

    // MARK: Codex token identity

    // The plan is the member *in* a workspace. The same person in two
    // workspaces is two plans; two logins into one workspace are one.
    func test_codexIdentityComesFromTheAccessTokenClaims() {
        let access = jwt([
            "exp": 1_791_186_266,
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "user-1",
                "chatgpt_account_id": "ws-a",
                "chatgpt_plan_type": "pro",
            ],
            "https://api.openai.com/profile": ["email": "me@example.com"],
        ])
        let auth: [String: Any] = ["tokens": ["access_token": access, "account_id": "stale-ws"]]

        let identity = CodexTokenIdentity.from(authJSON: auth)!

        XCTAssertEqual(identity.planKey, "user-1|ws-a", "Claims beat the stored account id")
        XCTAssertEqual(identity.planType, "pro")
        XCTAssertEqual(identity.email, "me@example.com")
        XCTAssertEqual(identity.expiresAt, Date(timeIntervalSince1970: 1_791_186_266))
    }

    func test_codexIdentityFallsBackToIdToken() {
        let id = jwt([
            "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_user_id": "user-1", "chatgpt_account_id": "ws-b"],
        ])
        let identity = CodexTokenIdentity.from(authJSON: ["tokens": ["id_token": id]])!

        XCTAssertEqual(identity.planKey, "user-1|ws-b")
        XCTAssertNil(identity.expiresAt)
    }

    // MARK: Claude profile

    func test_claudeProfileParsesNestedShape() {
        let payload = """
        {"account":{"uuid":"acc-1","email":"me@example.com","display_name":"me"},
         "organization":{"uuid":"org-1","name":"Silla","organization_type":"claude_team",
                         "rate_limit_tier":"default_raven","seat_tier":"team_tier_1"}}
        """

        let profile = ClaudeProfile.parse(Data(payload.utf8))!

        XCTAssertEqual(profile.planKey, "acc-1|org-1")
        XCTAssertEqual(profile.organizationName, "Silla")
        XCTAssertEqual(profile.planName, "Team")
    }

    func test_claudeProfileParsesFlatShape() {
        let payload = """
        {"account_uuid":"acc-1","account_email":"me@example.com","organization_uuid":"org-2",
         "organization_type":"claude_max","organization_rate_limit_tier":"default_claude_max_20x"}
        """

        let profile = ClaudeProfile.parse(Data(payload.utf8))!

        XCTAssertEqual(profile.planKey, "acc-1|org-2")
        XCTAssertEqual(profile.planName, "Max 20x")
    }

    func test_claudeProfileWithoutIdentityIsRejected() {
        XCTAssertNil(ClaudeProfile.parse(Data(#"{"error":"forbidden"}"#.utf8)))
    }

    func test_declaredOAuthAccountNamesTheSeat() {
        let declared = ClaudeProfile.fromOAuthAccount([
            "accountUuid": "acc-1", "emailAddress": "me@example.com",
            "organizationUuid": "org-1", "organizationName": "OverEdge",
            "organizationType": "claude_team", "organizationRateLimitTier": "default_raven",
            "userRateLimitTier": "default_claude_max_5x",
        ])

        XCTAssertEqual(declared.planName, "Team 5x")
        XCTAssertEqual(declared.planKey, "acc-1|org-1")
    }
}
