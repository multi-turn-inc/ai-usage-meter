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

/// One usage observation at the source event's timestamp. This preserves exact
/// rolling-window totals; the hourly buckets below remain for chart compatibility.
public struct TokenUsageEvent: Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let service: ServiceType
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let costUSD: Double

    public init(id: String, timestamp: Date, service: ServiceType,
                inputTokens: Int64, outputTokens: Int64, costUSD: Double = 0) {
        self.id = id
        self.timestamp = timestamp
        self.service = service
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    public var totalTokens: Int64 { inputTokens + outputTokens }
}

public struct TokenUsageSummary {
    public let daily: [DailyTokenUsage]
    public let hourly: [HourlyTokenUsage]
    public let events: [TokenUsageEvent]
    public let lastParsed: Date

    public init(daily: [DailyTokenUsage], hourly: [HourlyTokenUsage], events: [TokenUsageEvent] = [], lastParsed: Date) {
        self.daily = daily
        self.hourly = hourly
        self.events = events
        self.lastParsed = lastParsed
    }

    public var todayTokens: Int64 {
        let todayKey = Self.dayKey(for: lastParsed)
        return daily.first { $0.date == todayKey }?.totalTokens ?? 0
    }

    public var todayMessages: Int {
        let todayKey = Self.dayKey(for: lastParsed)
        return daily.first { $0.date == todayKey }?.messageCount ?? 0
    }

    public var todayCost: Double {
        let todayKey = Self.dayKey(for: lastParsed)
        return daily.first { $0.date == todayKey }?.costUSD ?? 0
    }

    public var weekTokens: Int64 {
        daily.reduce(0) { $0 + $1.totalTokens }
    }

    public var weekCost: Double {
        daily.reduce(0) { $0 + $1.costUSD }
    }

    public func cost(inLastHours hours: Int, now: Date = Date()) -> Double {
        guard hours > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        if !events.isEmpty {
            return events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.reduce(0) { $0 + $1.costUSD }
        }
        return hourly.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.reduce(0) { $0 + $1.costUSD }
    }

    public func todayTokens(for service: ServiceType) -> Int64 {
        let todayKey = Self.dayKey(for: lastParsed)
        return daily.first { $0.date == todayKey }?.byService[service] ?? 0
    }

    public func tokens(inLastHours hours: Int, now: Date = Date()) -> Int64 {
        guard hours > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        if !events.isEmpty {
            return events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.reduce(0) { $0 + $1.totalTokens }
        }
        return hourly.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.reduce(0) { $0 + $1.totalTokens }
    }

    public func messages(inLastHours hours: Int, now: Date = Date()) -> Int {
        guard hours > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        if !events.isEmpty {
            return events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.count
        }
        return hourly.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.reduce(0) { $0 + $1.messageCount }
    }

    /// Fixed-width buckets over a rolling period, using source event timestamps.
    /// The final bucket ends at `now`; future observations are excluded.
    public func buckets(inLastHours hours: Int, count: Int, now: Date = Date()) -> [Int64] {
        guard hours > 0, count > 0 else { return [] }
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        var buckets = Array(repeating: Int64(0), count: count)
        if !events.isEmpty {
            let width = Double(hours) * 3600 / Double(count)
            for event in events where event.timestamp >= start && event.timestamp <= now {
                let index = min(count - 1, max(0, Int(event.timestamp.timeIntervalSince(start) / width)))
                buckets[index] += event.totalTokens
            }
            return buckets
        }
        for entry in hourly {
            guard entry.timestamp >= start && entry.timestamp <= now else { continue }
            let width = Double(hours) * 3600 / Double(count)
            let index = min(count - 1, max(0, Int(entry.timestamp.timeIntervalSince(start) / width)))
            buckets[index] += entry.totalTokens
        }
        return buckets
    }

    public static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    public static let empty = TokenUsageSummary(daily: [], hourly: [], events: [], lastParsed: Date())
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
