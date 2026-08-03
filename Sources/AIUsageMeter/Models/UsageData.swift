import Foundation
import AIUsageMeterCore

/// One quota window as the provider describes it, rather than a fixed 5h/7d pair.
struct UsageWindow: Codable, Equatable, Identifiable {
    /// Short display label: "5h", "7d", or a model name such as "Fable".
    let label: String
    /// 0–100 used.
    let percent: Double
    let resetsAt: Date?
    /// The provider flagged this window as exhausted or near it.
    let isCritical: Bool

    var id: String { label }

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
