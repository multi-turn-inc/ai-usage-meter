import Foundation

// MARK: - Time Scope

enum TokenTimeScope: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hours24 = "24h"
    case days7 = "7d"

    var id: String { rawValue }

    var scanDays: Int {
        switch self {
        case .hour1, .hours24: return 1
        case .days7: return 7
        }
    }
}

// MARK: - Summary

struct TokenUsageSummary {
    let daily: [DailyTokenUsage]
    let hourly: [HourlyTokenUsage]
    let lastParsed: Date

    var todayTokens: Int64 {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.totalTokens ?? 0
    }

    var todayMessages: Int {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.messageCount ?? 0
    }

    var todayCost: Double {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.costUSD ?? 0
    }

    var weekTokens: Int64 {
        daily.reduce(0) { $0 + $1.totalTokens }
    }

    var weekCost: Double {
        daily.reduce(0) { $0 + $1.costUSD }
    }

    func cost(inLastHours hours: Int) -> Double {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.costUSD }
    }

    func todayTokens(for service: ServiceType) -> Int64 {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.byService[service] ?? 0
    }

    func tokens(inLastHours hours: Int) -> Int64 {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.totalTokens }
    }

    func messages(inLastHours hours: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.messageCount }
    }

    static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    static let empty = TokenUsageSummary(daily: [], hourly: [], lastParsed: Date())
}

// MARK: - Daily

struct DailyTokenUsage: Identifiable {
    var id: String { date }
    let date: String // yyyy-MM-dd
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var messageCount: Int = 0
    var costUSD: Double = 0
    var byService: [ServiceType: Int64] = [:]

    var totalTokens: Int64 {
        inputTokens + outputTokens
    }
}

// MARK: - Hourly

struct HourlyTokenUsage: Identifiable {
    var id: String { hourKey }
    let hourKey: String // yyyy-MM-dd HH
    let timestamp: Date
    var totalTokens: Int64 = 0
    var messageCount: Int = 0
    var costUSD: Double = 0
    var byService: [ServiceType: Int64] = [:]
}
