import Foundation

public final class ClaudeCodeTokenParser: @unchecked Sendable {
    public static let shared = ClaudeCodeTokenParser()
    let baseDir: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private struct Record {
        let key: String
        let timestamp: Date
        let model: String?
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite5m: Int64
        let cacheWrite1h: Int64
        let cost: Double
        let source: String
        let line: Int
        let richness: (Int, Int64, Int64, Int64)
    }

    private struct FileCacheEntry {
        let size: Int64
        let mtime: TimeInterval
        let records: [Record]
    }
    private var fileCache: [String: FileCacheEntry] = [:]
    private static let assistantNeedle = Data("\"assistant\"".utf8)
    private static let usageNeedle = Data("\"usage\"".utf8)
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
    private let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH"
        formatter.timeZone = .current
        return formatter
    }()
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private init() {
        baseDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    init(baseDirForTesting: URL) {
        baseDir = baseDirForTesting
    }

    public func parse(days: Int = 7, now: Date = Date()) -> TokenUsageSummary {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let files = findJSONLFiles(modifiedAfter: cutoff)
        var current: [String: FileCacheEntry] = [:]
        for file in files {
            let path = file.path
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? -1)
            let mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? -1
            if let cached = fileCache[path], cached.size == size, cached.mtime == mtime {
                current[path] = cached
            } else {
                current[path] = FileCacheEntry(size: size, mtime: mtime, records: parseFile(file))
            }
        }
        fileCache = current

        var resolved: [String: (record: Record, earliest: Date)] = [:]
        for entry in current.values {
            for record in entry.records {
                if let old = resolved[record.key] {
                    let earliest = min(old.earliest, record.timestamp)
                    let selected = isPreferred(record, over: old.record) ? record : old.record
                    resolved[record.key] = (selected, earliest)
                } else {
                    resolved[record.key] = (record, record.timestamp)
                }
            }
        }

        var daily: [String: DailyTokenUsage] = [:]
        var hourly: [String: HourlyTokenUsage] = [:]
        var events: [TokenUsageEvent] = []
        for value in resolved.values {
            let r = value.record
            let ts = value.earliest
            guard ts >= cutoff, ts <= now else { continue }
            let displayedInput = r.input + r.cacheRead + r.cacheWrite5m + r.cacheWrite1h
            guard displayedInput + r.output > 0 || r.cost > 0 else { continue }
            let day = dayFormatter.string(from: ts)
            var d = daily[day] ?? DailyTokenUsage(date: day)
            d.inputTokens += displayedInput
            d.outputTokens += r.output
            d.messageCount += 1
            d.costUSD += r.cost
            d.byService[.claude, default: 0] += displayedInput + r.output
            daily[day] = d
            let hour = hourFormatter.string(from: ts)
            let start = Calendar.current.dateInterval(of: .hour, for: ts)?.start ?? ts
            var h = hourly[hour] ?? HourlyTokenUsage(hourKey: hour, timestamp: start)
            h.totalTokens += displayedInput + r.output
            h.messageCount += 1
            h.costUSD += r.cost
            h.byService[.claude, default: 0] += displayedInput + r.output
            hourly[hour] = h
            events.append(TokenUsageEvent(id: r.key, timestamp: ts, service: .claude, inputTokens: displayedInput, outputTokens: r.output, costUSD: r.cost))
        }
        let sortedEvents = events.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        return TokenUsageSummary(
            daily: daily.values.sorted { $0.date < $1.date },
            hourly: hourly.values.sorted { $0.hourKey < $1.hourKey },
            events: sortedEvents,
            lastParsed: now
        )
    }

    private func findJSONLFiles(modifiedAfter cutoff: Date) -> [URL] {
        guard fileManager.fileExists(atPath: baseDir.path), let e = fileManager.enumerator(at: baseDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let file as URL in e where file.pathExtension.lowercased() == "jsonl" {
            let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if v?.isRegularFile == true, let m = v?.contentModificationDate, m >= cutoff { result.append(file) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func parseFile(_ url: URL) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }; defer { try? handle.close() }
        var records: [Record] = []
        var buffer = Data()
        var lineNumber = 0
        func consume(_ data: Data) {
            guard data.range(of: Self.assistantNeedle) != nil,
                  data.range(of: Self.usageNeedle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let ts = parseTimestamp(obj["timestamp"] as? String) else { return }
            let id = (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let key = id ?? "claude-file-\(url.path)-line-\(lineNumber)"
            let input = int64(usage["input_tokens"])
            let output = int64(usage["output_tokens"])
            let read = int64(usage["cache_read_input_tokens"])
            var w5 = int64(usage["cache_creation_input_tokens"])
            var w1: Int64 = 0
            if let cache = usage["cache_creation"] as? [String: Any] {
                let fiveMinute = int64(cache["ephemeral_5m_input_tokens"])
                let oneHour = int64(cache["ephemeral_1h_input_tokens"])
                if fiveMinute + oneHour > 0 {
                    w5 = fiveMinute
                    w1 = oneHour
                }
            }
            let model = message["model"] as? String
            let cost = ModelPricing.shared.claudeCost(
                model: model, input: input, output: output,
                cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: read
            )
            let total = input + output + read + w5 + w1
            records.append(Record(
                key: key, timestamp: ts, model: model,
                input: input, output: output, cacheRead: read,
                cacheWrite5m: w5, cacheWrite1h: w1, cost: cost,
                source: url.path, line: lineNumber,
                richness: (output > 0 ? 1 : 0, total, output, input + read + w5 + w1)
            ))
        }
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                lineNumber += 1
                if !line.isEmpty { consume(line) }
            }
        }
        if !buffer.isEmpty {
            lineNumber += 1
            consume(buffer)
        }
        return records
    }

    private func isPreferred(_ a: Record, over b: Record) -> Bool {
        if a.richness.0 != b.richness.0 { return a.richness.0 > b.richness.0 }
        if a.richness.1 != b.richness.1 { return a.richness.1 > b.richness.1 }
        if a.richness.2 != b.richness.2 { return a.richness.2 > b.richness.2 }
        if a.richness.3 != b.richness.3 { return a.richness.3 > b.richness.3 }
        return (a.source, a.line) < (b.source, b.line)
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    private func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
