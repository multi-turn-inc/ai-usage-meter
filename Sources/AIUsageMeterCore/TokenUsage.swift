import Foundation

// MARK: - Time Scope

public enum TokenTimeScope: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hours24 = "24h"
    case days7 = "7d"

    public var id: String { rawValue }

    public var scanDays: Int {
        switch self {
        case .hour1, .hours24: return 1
        case .days7: return 7
        }
    }
}

// MARK: - Summary

public struct TokenUsageSummary {
    public let daily: [DailyTokenUsage]
    public let hourly: [HourlyTokenUsage]
    public let lastParsed: Date

    public init(daily: [DailyTokenUsage], hourly: [HourlyTokenUsage], lastParsed: Date) {
        self.daily = daily
        self.hourly = hourly
        self.lastParsed = lastParsed
    }

    public var todayTokens: Int64 {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.totalTokens ?? 0
    }

    public var todayMessages: Int {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.messageCount ?? 0
    }

    public var todayCost: Double {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.costUSD ?? 0
    }

    public var weekTokens: Int64 {
        daily.reduce(0) { $0 + $1.totalTokens }
    }

    public var weekCost: Double {
        daily.reduce(0) { $0 + $1.costUSD }
    }

    public func cost(inLastHours hours: Int) -> Double {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.costUSD }
    }

    public func todayTokens(for service: ServiceType) -> Int64 {
        let todayKey = Self.dayKey(for: Date())
        return daily.first { $0.date == todayKey }?.byService[service] ?? 0
    }

    public func tokens(inLastHours hours: Int) -> Int64 {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.totalTokens }
    }

    public func messages(inLastHours hours: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return hourly.filter { $0.timestamp >= cutoff }.reduce(0) { $0 + $1.messageCount }
    }

    public static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    public static let empty = TokenUsageSummary(daily: [], hourly: [], lastParsed: Date())
}

// MARK: - Daily

public struct DailyTokenUsage: Identifiable {
    public var id: String { date }
    public let date: String // yyyy-MM-dd
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var messageCount: Int = 0
    public var costUSD: Double = 0
    public var byService: [ServiceType: Int64] = [:]

    public init(date: String) {
        self.date = date
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens
    }
}

// MARK: - Hourly

public struct HourlyTokenUsage: Identifiable {
    public var id: String { hourKey }
    public let hourKey: String // yyyy-MM-dd HH
    public let timestamp: Date
    public var totalTokens: Int64 = 0
    public var messageCount: Int = 0
    public var costUSD: Double = 0
    public var byService: [ServiceType: Int64] = [:]

    public init(hourKey: String, timestamp: Date) {
        self.hourKey = hourKey
        self.timestamp = timestamp
    }
}
