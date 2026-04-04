import Foundation

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
