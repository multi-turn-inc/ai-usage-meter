import Foundation
import AIUsageMeterCore

/// One quota window as the provider describes it, rather than a fixed 5h/7d pair.
struct UsageWindow: Codable, Equatable, Identifiable {
    /// What a window limits — the advisor needs to know which windows stop the
    /// whole plan and which one holds its bulk.
    enum Role: String, Codable {
        /// Short rolling window (Claude's 5 hours).
        case session
        /// The long window; unused quota is lost when it resets.
        case weekly
        /// One model only — the rest of the plan keeps working.
        case model
        /// A credit allowance.
        case spend
    }

    /// Short display label: "5h", "7d", or a model name such as "Fable".
    let label: String
    /// 0–100 used.
    let percent: Double
    let resetsAt: Date?
    /// The provider flagged this window as exhausted or near it.
    let isCritical: Bool
    var role: Role = .weekly
    /// Window length when known.
    var windowSeconds: Double? = nil

    var id: String { label }

    /// The same window in the advisor's terms.
    var quotaLimit: QuotaLimit {
        let kind: QuotaLimit.Kind
        switch role {
        case .session: kind = .session
        case .weekly: kind = .weekly
        case .model: kind = .model(label)
        case .spend: kind = .spend
        }
        return QuotaLimit(kind: kind, usedPercent: percent, resetsAt: resetsAt, windowSeconds: windowSeconds)
    }

    /// Derives "5h"/"7d"-style labels from a window duration, so a provider
    /// changing its window length can't leave the UI lying about the period.
    static func label(forSeconds seconds: Int) -> String {
        switch seconds {
        case ..<0: return "?"
        case 0..<3600: return "\(max(1, seconds / 60))m"
        case 3600..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

struct UsageData: Codable, Equatable {
    let tokensUsed: Int64
    let tokensLimit: Int64
    let inputTokens: Int64?
    let outputTokens: Int64?

    let periodStart: Date
    let periodEnd: Date
    let resetDate: Date?          // 5-hour reset
    let sevenDayResetDate: Date?  // 7-day reset

    let currentCost: Decimal?
    let projectedCost: Decimal?
    let currency: String

    let tier: String
    let lastUpdated: Date

    // Claude-specific usage windows
    let fiveHourUsage: Double?
    let sevenDayUsage: Double?

    /// Every quota window the provider reports, in display order.
    ///
    /// Providers keep changing these — Anthropic added a per-model weekly window
    /// (Fable), OpenAI dropped its 5-hour window and made the primary one weekly
    /// — so the windows are carried as data with their own labels instead of two
    /// hard-coded "5h"/"7d" fields. Those two remain for the gauge and menu-bar
    /// meter, which need one headline number.
    var windows: [UsageWindow] = []

    /// Which plan these numbers belong to, from the credential rather than the
    /// row's declared name. Two rows with the same `plan.key` are one plan.
    var plan: PlanIdentity? = nil
    /// The provider is refusing requests now, whatever the percentages say.
    var limitReached: Bool = false
    /// Every ChatGPT account this login can act in (Codex only). Lets the board
    /// show workspaces that have no login of their own yet.
    var workspaces: [ChatGPTWorkspace] = []

    var usagePercentage: Double {
        // Use 5-hour usage if available (Claude), otherwise calculate from tokens
        if let fiveHour = fiveHourUsage {
            return fiveHour
        }
        guard tokensLimit > 0 else { return 0 }
        return (Double(tokensUsed) / Double(tokensLimit)) * 100
    }

    var remainingTokens: Int64 {
        tokensLimit - tokensUsed
    }

    var daysUntilReset: Int? {
        guard let resetDate = resetDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: resetDate).day
    }

    var daysUntilSevenDayReset: Int? {
        guard let sevenDayResetDate = sevenDayResetDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: sevenDayResetDate).day
    }

    static func placeholder(for type: ServiceType) -> UsageData {
        let now = Date()

        return UsageData(
            tokensUsed: 0,
            tokensLimit: 0,
            inputTokens: nil,
            outputTokens: nil,
            periodStart: now,
            periodEnd: now,
            resetDate: nil,
            sevenDayResetDate: nil,
            currentCost: nil,
            projectedCost: nil,
            currency: "USD",
            tier: "Loading",
            lastUpdated: now,
            fiveHourUsage: nil,
            sevenDayUsage: nil
        )
    }
}
