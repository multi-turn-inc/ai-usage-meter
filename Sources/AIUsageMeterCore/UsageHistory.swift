import Foundation

public struct UsageHistoryEntry: Codable, Identifiable {
    public let id: UUID
    public let serviceType: ServiceType
    public let timestamp: Date
    public let fiveHourUsage: Double?
    public let sevenDayUsage: Double?

    public init(
        id: UUID = UUID(),
        serviceType: ServiceType,
        timestamp: Date = Date(),
        fiveHourUsage: Double?,
        sevenDayUsage: Double?
    ) {
        self.id = id
        self.serviceType = serviceType
        self.timestamp = timestamp
        self.fiveHourUsage = fiveHourUsage
        self.sevenDayUsage = sevenDayUsage
    }
}

public final class UsageHistoryStore {
    public static let shared = UsageHistoryStore()

    private struct HourBucket: Hashable {
        let serviceType: ServiceType
        let era: Int
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
    }

    private let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private let fileURL: URL
    private let calendar: Calendar
    private let now: () -> Date

    private convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appFolder = appSupport.appendingPathComponent("AIUsageMeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appFolder,
            withIntermediateDirectories: true
        )

        self.init(
            fileURL: appFolder.appendingPathComponent("usage_history.json"),
            calendar: .current,
            now: Date.init
        )
    }

    init(fileURL: URL, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.now = now
    }

    public func loadHistory() -> [UsageHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([UsageHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    public func saveEntry(_ entry: UsageHistoryEntry) {
        let compacted = compact(loadHistory() + [entry], relativeTo: now())

        guard let data = try? JSONEncoder().encode(compacted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func getHistory(
        for serviceType: ServiceType,
        hours: Int = 24
    ) -> [UsageHistoryEntry] {
        let cutoff = now().addingTimeInterval(-Double(hours) * 60 * 60)
        return loadHistory()
            .filter { $0.serviceType == serviceType && $0.timestamp > cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func getHourlyAverages(
        for serviceType: ServiceType,
        hours: Int = 24
    ) -> [(hour: Int, fiveHour: Double?, sevenDay: Double?)] {
        let entries = getHistory(for: serviceType, hours: hours)
        var hourlyData: [Int: (fiveHourSum: Double, sevenDaySum: Double, count: Int)] = [:]

        for entry in entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            var data = hourlyData[hour] ?? (0, 0, 0)
            if let fiveHourUsage = entry.fiveHourUsage {
                data.fiveHourSum += fiveHourUsage
            }
            if let sevenDayUsage = entry.sevenDayUsage {
                data.sevenDaySum += sevenDayUsage
            }
            data.count += 1
            hourlyData[hour] = data
        }

        return (0..<24).map { hour in
            guard let data = hourlyData[hour], data.count > 0 else {
                return (hour, nil, nil)
            }
            return (
                hour,
                data.fiveHourSum / Double(data.count),
                data.sevenDaySum / Double(data.count)
            )
        }
    }

    public func getDailyHistory(
        for serviceType: ServiceType,
        days: Int = 7
    ) -> [(date: Date, fiveHour: Double?, sevenDay: Double?)] {
        let entries = loadHistory().filter { $0.serviceType == serviceType }
        var dailyData: [
            String: (fiveHourSum: Double, sevenDaySum: Double, count: Int, date: Date)
        ] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone

        for entry in entries {
            let key = formatter.string(from: entry.timestamp)
            var data = dailyData[key] ?? (0, 0, 0, entry.timestamp)
            if let fiveHourUsage = entry.fiveHourUsage {
                data.fiveHourSum += fiveHourUsage
            }
            if let sevenDayUsage = entry.sevenDayUsage {
                data.sevenDaySum += sevenDayUsage
            }
            data.count += 1
            dailyData[key] = data
        }

        let currentDate = now()
        let result: [(date: Date, fiveHour: Double?, sevenDay: Double?)] =
            (0..<days).compactMap { dayOffset in
                guard let date = calendar.date(
                    byAdding: .day,
                    value: -dayOffset,
                    to: currentDate
                ) else {
                    return nil
                }
                let key = formatter.string(from: date)

                guard let data = dailyData[key], data.count > 0 else {
                    return (date, nil, nil)
                }
                return (
                    date,
                    data.fiveHourSum / Double(data.count),
                    data.sevenDaySum / Double(data.count)
                )
            }
            .reversed()

        return Array(result)
    }

    func compact(
        _ entries: [UsageHistoryEntry],
        relativeTo referenceDate: Date
    ) -> [UsageHistoryEntry] {
        let cutoff = referenceDate.addingTimeInterval(-retentionInterval)
        var latestByHour: [HourBucket: UsageHistoryEntry] = [:]

        for entry in entries where entry.timestamp > cutoff {
            let components = calendar.dateComponents(
                [.era, .year, .month, .day, .hour],
                from: entry.timestamp
            )
            guard let era = components.era,
                  let year = components.year,
                  let month = components.month,
                  let day = components.day,
                  let hour = components.hour else {
                continue
            }

            let bucket = HourBucket(
                serviceType: entry.serviceType,
                era: era,
                year: year,
                month: month,
                day: day,
                hour: hour
            )
            if let existing = latestByHour[bucket],
               existing.timestamp >= entry.timestamp {
                continue
            }
            latestByHour[bucket] = entry
        }

        return latestByHour.values.sorted { $0.timestamp < $1.timestamp }
    }
}
