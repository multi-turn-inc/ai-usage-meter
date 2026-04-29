import Foundation

/// Parses Claude Code JSONL session logs from ~/.claude/projects/ and
/// aggregates token usage per message timestamp (not per session).
final class ClaudeCodeTokenParser {
    static let shared = ClaudeCodeTokenParser()

    private let fileManager = FileManager.default
    private let baseDir: URL
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH"
        f.timeZone = .current
        return f
    }()

    private init() {
        baseDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    // MARK: - Public

    func parse(days: Int = 7) -> TokenUsageSummary {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let jsonlFiles = findJSONLFiles(modifiedAfter: cutoff)

        var dailyBuckets: [String: DailyTokenUsage] = [:]
        var hourlyBuckets: [String: HourlyTokenUsage] = [:]

        for file in jsonlFiles {
            parseMessages(file: file, cutoff: cutoff, dailyBuckets: &dailyBuckets, hourlyBuckets: &hourlyBuckets)
        }

        let sortedDaily = dailyBuckets.values.sorted { $0.date < $1.date }
        let sortedHourly = hourlyBuckets.values.sorted { $0.hourKey < $1.hourKey }

        return TokenUsageSummary(
            daily: sortedDaily,
            hourly: sortedHourly,
            lastParsed: Date()
        )
    }

    // MARK: - File Discovery

    private func findJSONLFiles(modifiedAfter cutoff: Date) -> [URL] {
        guard fileManager.fileExists(atPath: baseDir.path) else { return [] }

        var results: [URL] = []
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        ) else { return [] }

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fileManager.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate >= cutoff {
                    results.append(file)
                }
            }
        }

        return results
    }

    // MARK: - Per-message Parsing

    private func parseMessages(
        file url: URL,
        cutoff: Date,
        dailyBuckets: inout [String: DailyTokenUsage],
        hourlyBuckets: inout [String: HourlyTokenUsage]
    ) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return }

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            guard let type = obj["type"] as? String, type == "assistant" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            guard let usage = message["usage"] as? [String: Any] else { continue }
            guard let ts = parseTimestamp(obj["timestamp"] as? String), ts >= cutoff else { continue }

            // Match Claude Code /stats: count input + output only (no cache tokens)
            let input = int64(usage["input_tokens"])
            let output = int64(usage["output_tokens"])
            let total = input + output
            guard total > 0 else { continue }

            // Daily bucket (keyed by message timestamp)
            let dayKey = dayFormatter.string(from: ts)
            var daily = dailyBuckets[dayKey] ?? DailyTokenUsage(date: dayKey)
            daily.inputTokens += input
            daily.outputTokens += output
            daily.messageCount += 1
            daily.byService[.claude, default: 0] += total
            dailyBuckets[dayKey] = daily

            // Hourly bucket
            let hKey = hourFormatter.string(from: ts)
            let hourStart = Calendar.current.date(bySetting: .minute, value: 0, of: ts) ?? ts
            var hourly = hourlyBuckets[hKey] ?? HourlyTokenUsage(hourKey: hKey, timestamp: hourStart)
            hourly.totalTokens += total
            hourly.messageCount += 1
            hourly.byService[.claude, default: 0] += total
            hourlyBuckets[hKey] = hourly
        }
    }

    private func int64(_ value: Any?) -> Int64 {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        return 0
    }

    private func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
