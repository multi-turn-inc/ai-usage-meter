import Foundation

/// Which quota bucket a login draws from, established from the credential
/// itself rather than from a name written beside it.
///
/// Two logins with the same `key` are the same plan: they share one set of
/// limits, so they must be shown — and advised on — once.
public struct PlanIdentity: Codable, Sendable, Equatable {
    /// `<person>|<org or workspace>`; nil when the credential didn't say.
    public let key: String?
    /// The person, independent of org — groups one person's plans together.
    public let personKey: String?
    public let email: String?
    /// "Silla", "KAIST OverEdge", "Personal".
    public let orgName: String?
    /// "Max 20x", "Team 5x", "Business", "Pro".
    public let planName: String?

    public init(key: String?, personKey: String?, email: String?, orgName: String?, planName: String?) {
        self.key = key
        self.personKey = personKey
        self.email = email
        self.orgName = orgName
        self.planName = planName
    }
}

// MARK: - Plan names

public enum PlanNames {

    /// Claude plan label from the organisation type and rate-limit tiers.
    ///
    /// A Team seat carries its own tier ("default_claude_max_5x") separate from
    /// the organisation's, and that seat tier is what sets its limits — so it is
    /// named when present.
    public static func claude(organizationType: String?, rateLimitTier: String?,
                              userRateLimitTier: String? = nil) -> String? {
        let type = organizationType?.lowercased() ?? ""
        let tier = rateLimitTier?.lowercased() ?? ""
        let seat = userRateLimitTier?.lowercased() ?? ""

        func multiplier(_ raw: String) -> String? {
            if raw.contains("20x") { return "20x" }
            if raw.contains("5x") { return "5x" }
            return nil
        }

        if type.contains("max") || (type.isEmpty && tier.contains("max")) {
            return ["Max", multiplier(tier) ?? multiplier(seat)].compactMap { $0 }.joined(separator: " ")
        }
        if type.contains("team") || (type.isEmpty && tier.contains("team")) {
            return ["Team", multiplier(seat)].compactMap { $0 }.joined(separator: " ")
        }
        if type.contains("enterprise") { return "Enterprise" }
        if type.contains("pro") || (type.isEmpty && tier.contains("pro")) { return "Pro" }
        if type.contains("free") { return "Free" }
        return nil
    }

    /// ChatGPT plan label from the backend's `plan_type`.
    ///
    /// OpenAI renamed Team to Business and ships self-serve variants with long
    /// internal names ("self_serve_business_prolite"); users know them as
    /// Business.
    public static func chatGPT(planType: String?) -> String? {
        guard let raw = planType?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("enterprise") { return "Enterprise" }
        if raw.contains("business") || raw == "team" { return "Business" }
        if raw.contains("edu") { return "Edu" }
        switch raw {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "go": return "Go"
        case "free": return "Free"
        default:
            return raw.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

// MARK: - ChatGPT workspaces

/// One ChatGPT account a login belongs to — the personal account or a
/// workspace. Each has its own plan and its own Codex limits.
public struct ChatGPTWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Workspace name; nil for the personal account.
    public let name: String?
    public let isPersonal: Bool
    public let planType: String?

    public init(id: String, name: String?, isPersonal: Bool, planType: String?) {
        self.id = id
        self.name = name
        self.isPersonal = isPersonal
        self.planType = planType
    }

    public var displayName: String { name ?? "Personal" }
    public var planName: String? { PlanNames.chatGPT(planType: planType) }
}

public enum ChatGPTWorkspaceDirectory {

    /// Parses `backend-api/accounts/check`: every account the login can act in.
    ///
    /// The payload repeats the default account under the key "default"; that
    /// alias is dropped so each account appears once, in the order the backend
    /// lists them.
    public static func parse(_ data: Data) -> [ChatGPTWorkspace] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else { return [] }

        let ordering = (root["account_ordering"] as? [String]) ?? accounts.keys.sorted()
        return ordering.compactMap { key -> ChatGPTWorkspace? in
            guard key != "default",
                  let entry = accounts[key] as? [String: Any],
                  let account = entry["account"] as? [String: Any] else { return nil }
            if account["is_deactivated"] as? Bool == true { return nil }
            let id = (account["account_id"] as? String) ?? key
            let structure = account["structure"] as? String
            let name = (account["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChatGPTWorkspace(
                id: id,
                name: structure == "personal" ? nil : name,
                isPersonal: structure == "personal",
                planType: account["plan_type"] as? String
            )
        }
    }
}

// MARK: - Codex usage

/// What `backend-api/wham/usage` reports for the workspace a token is bound to.
///
/// Note the binding: the `ChatGPT-Account-Id` header does **not** select a
/// workspace. A token answers for the workspace it was issued in whatever the
/// header says, so every workspace needs its own login to be read.
public struct CodexUsageSnapshot: Sendable, Equatable {

    public struct Window: Sendable, Equatable {
        public let usedPercent: Double
        public let windowSeconds: TimeInterval?
        public let resetsAt: Date?
    }

    public let planType: String?
    public let primary: Window?
    public let secondary: Window?
    /// The per-member credit allowance Business workspaces set. It binds
    /// independently of the rate limit: a member can have most of the weekly
    /// rate limit left and almost none of their credits.
    public let spend: Window?
    /// The backend is refusing requests now.
    public let limitReached: Bool

    public static func parse(_ data: Data, now: Date = Date()) -> CodexUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let rateLimit = root["rate_limit"] as? [String: Any]
        let spendControl = root["spend_control"] as? [String: Any]

        func window(_ raw: Any?) -> Window? {
            guard let dict = raw as? [String: Any], let used = number(dict["used_percent"]) else { return nil }
            return Window(usedPercent: used, windowSeconds: number(dict["limit_window_seconds"]),
                          resetsAt: resetDate(dict, now: now))
        }

        var spend: Window?
        if let limit = spendControl?["individual_limit"] as? [String: Any] {
            var used = number(limit["used_percent"])
            if used == nil, let spent = number(limit["used"]), let cap = number(limit["limit"]), cap > 0 {
                used = spent / cap * 100
            }
            if let used {
                spend = Window(usedPercent: used, windowSeconds: number(limit["limit_window_seconds"]),
                               resetsAt: resetDate(limit, now: now))
            }
        }

        guard rateLimit != nil || spend != nil else { return nil }

        let refused = rateLimit?["limit_reached"] as? Bool == true
            || rateLimit?["allowed"] as? Bool == false
            || spendControl?["reached"] as? Bool == true

        return CodexUsageSnapshot(
            planType: root["plan_type"] as? String,
            primary: window(rateLimit?["primary_window"]),
            secondary: window(rateLimit?["secondary_window"]),
            spend: spend,
            limitReached: refused
        )
    }

    private static func resetDate(_ dict: [String: Any], now: Date) -> Date? {
        if let at = number(dict["reset_at"]) { return Date(timeIntervalSince1970: at) }
        if let after = number(dict["reset_after_seconds"]) { return now.addingTimeInterval(after) }
        return nil
    }
}

// MARK: - Codex token identity

/// Identity carried inside a Codex access token's own claims.
///
/// Unlike a name written next to a credential, claims cannot drift from the
/// token they are part of — this is evidence, not metadata.
public struct CodexTokenIdentity: Sendable, Equatable {
    public let userId: String?
    public let workspaceId: String?
    public let planType: String?
    public let email: String?
    public let expiresAt: Date?

    /// The quota bucket: one member in one workspace.
    public var planKey: String? {
        guard let userId, let workspaceId else { return nil }
        return "\(userId)|\(workspaceId)"
    }

    /// Reads an `auth.json` object. Prefers the access token — the credential
    /// actually sent — and falls back to the id token and the stored account id.
    public static func from(authJSON root: [String: Any]) -> CodexTokenIdentity? {
        guard let tokens = root["tokens"] as? [String: Any] else { return nil }
        let access = (tokens["access_token"] as? String).flatMap(AccountDiscovery.decodeJWTPayload)
        let id = (tokens["id_token"] as? String).flatMap(AccountDiscovery.decodeJWTPayload)
        guard access != nil || id != nil else { return nil }

        let authClaim = "https://api.openai.com/auth"
        let accessAuth = access?[authClaim] as? [String: Any]
        let idAuth = id?[authClaim] as? [String: Any]
        func claim(_ key: String) -> String? {
            (accessAuth?[key] as? String) ?? (idAuth?[key] as? String)
        }

        let profile = access?["https://api.openai.com/profile"] as? [String: Any]
        let email = (id?["email"] as? String) ?? (profile?["email"] as? String)

        return CodexTokenIdentity(
            userId: claim("chatgpt_user_id") ?? claim("user_id"),
            workspaceId: claim("chatgpt_account_id") ?? (tokens["account_id"] as? String),
            planType: claim("chatgpt_plan_type"),
            email: email.flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: number(access?["exp"]).map { Date(timeIntervalSince1970: $0) }
        )
    }
}

// MARK: - Claude profile

/// `api/oauth/profile` — who a Claude token belongs to and in which org.
///
/// Claude tokens are opaque, so this call is the only evidence of identity a
/// token carries. Parsed leniently: the account and organisation uuids are the
/// point, everything else is labelling.
public struct ClaudeProfile: Codable, Sendable, Equatable {
    public let accountUuid: String?
    public let email: String?
    public let organizationUuid: String?
    public let organizationName: String?
    public let organizationType: String?
    public let rateLimitTier: String?
    public let userRateLimitTier: String?

    public init(accountUuid: String?, email: String?, organizationUuid: String?,
                organizationName: String?, organizationType: String?,
                rateLimitTier: String?, userRateLimitTier: String?) {
        self.accountUuid = accountUuid
        self.email = email
        self.organizationUuid = organizationUuid
        self.organizationName = organizationName
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
        self.userRateLimitTier = userRateLimitTier
    }

    public var planKey: String? {
        guard let accountUuid, let organizationUuid else { return nil }
        return "\(accountUuid)|\(organizationUuid)"
    }

    public static func parse(_ data: Data) -> ClaudeProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account = root["account"] as? [String: Any]
        let org = root["organization"] as? [String: Any]

        func string(_ dicts: [[String: Any]?], _ keys: String...) -> String? {
            for dict in dicts {
                for key in keys {
                    if let value = dict?[key] as? String, !value.isEmpty { return value }
                }
            }
            return nil
        }

        let profile = ClaudeProfile(
            accountUuid: string([account], "uuid") ?? string([root], "account_uuid"),
            email: string([account], "email", "email_address") ?? string([root], "account_email"),
            organizationUuid: string([org], "uuid") ?? string([root], "organization_uuid"),
            organizationName: string([org], "name") ?? string([root], "organization_name"),
            organizationType: string([org, root], "organization_type"),
            rateLimitTier: string([org], "rate_limit_tier", "organization_rate_limit_tier")
                ?? string([root], "organization_rate_limit_tier"),
            userRateLimitTier: string([account, org, root], "user_rate_limit_tier")
        )
        return profile.accountUuid == nil && profile.organizationUuid == nil ? nil : profile
    }

    /// The same facts as Claude Code caches them in `.claude.json` under
    /// `oauthAccount`. Declared, not proven — good for labels only.
    public static func fromOAuthAccount(_ dict: [String: Any]) -> ClaudeProfile {
        func string(_ key: String) -> String? {
            (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ClaudeProfile(
            accountUuid: string("accountUuid"),
            email: string("emailAddress"),
            organizationUuid: string("organizationUuid"),
            organizationName: string("organizationName"),
            organizationType: string("organizationType"),
            rateLimitTier: string("organizationRateLimitTier"),
            userRateLimitTier: string("userRateLimitTier")
        )
    }

    public var planName: String? {
        PlanNames.claude(organizationType: organizationType, rateLimitTier: rateLimitTier,
                         userRateLimitTier: userRateLimitTier)
    }
}

// MARK: - Helpers

/// JSON numbers arrive as numbers or as strings ("9451.94"); accept both.
func number(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}
