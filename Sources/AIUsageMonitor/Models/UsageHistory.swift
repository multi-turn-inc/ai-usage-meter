import Foundation

struct UsageHistoryEntry: Codable, Identifiable {
    let id: UUID
    let serviceType: ServiceType
    let timestamp: Date
    let fiveHourUsage: Double?
    let sevenDayUsage: Double?

    init(serviceType: ServiceType, fiveHourUsage: Double?, sevenDayUsage: Double?) {
        self.id = UUID()
        self.serviceType = serviceType
        self.timestamp = Date()
        self.fiveHourUsage = fiveHourUsage
        self.sevenDayUsage = sevenDayUsage
    }
}

class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let maxEntries = 168 // 7 days * 24 hours
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("AIUsageMonitor", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        fileURL = appFolder.appendingPathComponent("usage_history.json")
    }

    func loadHistory() -> [UsageHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([UsageHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func saveEntry(_ entry: UsageHistoryEntry) {
        var entries = loadHistory()
        entries.append(entry)

        // Keep only recent entries
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        // Remove entries older than 7 days
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        entries = entries.filter { $0.timestamp > sevenDaysAgo }

        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    func getHistory(for serviceType: ServiceType, hours: Int = 24) -> [UsageHistoryEntry] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 60 * 60)
        return loadHistory()
            .filter { $0.serviceType == serviceType && $0.timestamp > cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func getHourlyAverages(for serviceType: ServiceType, hours: Int = 24) -> [(hour: Int, fiveHour: Double?, sevenDay: Double?)] {
        let entries = getHistory(for: serviceType, hours: hours)
        let calendar = Calendar.current

        // Group by hour
        var hourlyData: [Int: (fiveHourSum: Double, sevenDaySum: Double, count: Int)] = [:]

        for entry in entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            var data = hourlyData[hour] ?? (0, 0, 0)
            if let fh = entry.fiveHourUsage {
                data.fiveHourSum += fh
            }
            if let sd = entry.sevenDayUsage {
                data.sevenDaySum += sd
            }
            data.count += 1
            hourlyData[hour] = data
        }

        // Convert to averages
        return (0..<24).map { hour in
            if let data = hourlyData[hour], data.count > 0 {
                return (hour, data.fiveHourSum / Double(data.count), data.sevenDaySum / Double(data.count))
            }
            return (hour, nil, nil)
        }
    }

    func getDailyHistory(for serviceType: ServiceType, days: Int = 7) -> [(date: Date, fiveHour: Double?, sevenDay: Double?)] {
        let entries = loadHistory().filter { $0.serviceType == serviceType }
        let calendar = Calendar.current

        // Group by day
        var dailyData: [String: (fiveHourSum: Double, sevenDaySum: Double, count: Int, date: Date)] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for entry in entries {
            let key = formatter.string(from: entry.timestamp)
            var data = dailyData[key] ?? (0, 0, 0, entry.timestamp)
            if let fh = entry.fiveHourUsage {
                data.fiveHourSum += fh
            }
            if let sd = entry.sevenDayUsage {
                data.sevenDaySum += sd
            }
            data.count += 1
            dailyData[key] = data
        }

        // Get last N days
        let result: [(date: Date, fiveHour: Double?, sevenDay: Double?)] = (0..<days).compactMap { dayOffset in
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let key = formatter.string(from: date)

            if let data = dailyData[key], data.count > 0 {
                return (date, data.fiveHourSum / Double(data.count), data.sevenDaySum / Double(data.count))
            }
            return (date, nil, nil)
        }.reversed()

        return Array(result)
    }
}
