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
        // Resumed/compacted sessions copy earlier messages into new JSONL files;
        // dedup across all files by message id + request id (ccusage's scheme).
        var seenMessages = Set<String>()

        for file in jsonlFiles {
            parseMessages(
                file: file, cutoff: cutoff,
                dailyBuckets: &dailyBuckets, hourlyBuckets: &hourlyBuckets,
                seenMessages: &seenMessages
            )
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
        hourlyBuckets: inout [String: HourlyTokenUsage],
        seenMessages: inout Set<String>
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

            // Dedup replayed history (session resume/compaction copies entries
            // verbatim, ids included). Entries without a message id pass through.
            if let messageId = message["id"] as? String {
                let requestId = obj["requestId"] as? String ?? ""
                guard seenMessages.insert("\(messageId)|\(requestId)").inserted else { continue }
            }

            // Match Claude Code /stats: count input + output only (no cache tokens)
            let input = int64(usage["input_tokens"])
            let output = int64(usage["output_tokens"])
            let total = input + output

            // Cost includes cache traffic — that's what the API would bill.
            let cacheRead = int64(usage["cache_read_input_tokens"])
            var cacheWrite5m = int64(usage["cache_creation_input_tokens"])
            var cacheWrite1h: Int64 = 0
            if let cacheCreation = usage["cache_creation"] as? [String: Any] {
                let ephemeral5m = int64(cacheCreation["ephemeral_5m_input_tokens"])
                let ephemeral1h = int64(cacheCreation["ephemeral_1h_input_tokens"])
                if ephemeral5m + ephemeral1h > 0 {
                    cacheWrite5m = ephemeral5m
                    cacheWrite1h = ephemeral1h
                }
            }
            let cost = ModelPricing.shared.claudeCost(
                model: message["model"] as? String,
                input: input, output: output,
                cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h, cacheRead: cacheRead
            )

            guard total > 0 || cost > 0 else { continue }

            // Daily bucket (keyed by message timestamp)
            let dayKey = dayFormatter.string(from: ts)
            var daily = dailyBuckets[dayKey] ?? DailyTokenUsage(date: dayKey)
            daily.inputTokens += input
            daily.outputTokens += output
            daily.messageCount += 1
            daily.costUSD += cost
            daily.byService[.claude, default: 0] += total
            dailyBuckets[dayKey] = daily

            // Hourly bucket
            let hKey = hourFormatter.string(from: ts)
            let hourStart = Calendar.current.dateInterval(of: .hour, for: ts)?.start ?? ts
            var hourly = hourlyBuckets[hKey] ?? HourlyTokenUsage(hourKey: hKey, timestamp: hourStart)
            hourly.totalTokens += total
            hourly.messageCount += 1
            hourly.costUSD += cost
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
