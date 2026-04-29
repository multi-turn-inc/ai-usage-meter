import Foundation
import SQLite3

/// Parses Codex CLI token usage from ~/.codex/logs_2.sqlite.
final class CodexTokenParser {
    static let shared = CodexTokenParser()

    private let dbPath: String
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
        dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite").path
    }

    /// Merges Codex token data into existing daily/hourly buckets.
    func merge(into daily: inout [String: DailyTokenUsage],
               hourly: inout [String: HourlyTokenUsage],
               days: Int = 7) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        // Open read-only + URI mode to avoid locking issues with Codex
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let cutoffTs = Int(Date().timeIntervalSince1970) - days * 86400

        let query = """
            SELECT ts, feedback_log_body FROM logs
            WHERE ts >= ?
            AND feedback_log_body LIKE '%"usage":{"input_tokens"%'
            ORDER BY ts
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(cutoffTs))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            guard let bodyPtr = sqlite3_column_text(stmt, 1) else { continue }
            let body = String(cString: bodyPtr)

            let (input, output) = extractTokens(from: body)
            let total = input + output
            guard total > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(ts))

            // Daily
            let dayKey = dayFormatter.string(from: date)
            var d = daily[dayKey] ?? DailyTokenUsage(date: dayKey)
            d.inputTokens += input
            d.outputTokens += output
            d.messageCount += 1
            d.byService[.codex, default: 0] += total
            daily[dayKey] = d

            // Hourly
            let hKey = hourFormatter.string(from: date)
            let hourStart = Calendar.current.date(bySetting: .minute, value: 0, of: date) ?? date
            var h = hourly[hKey] ?? HourlyTokenUsage(hourKey: hKey, timestamp: hourStart)
            h.totalTokens += total
            h.messageCount += 1
            h.byService[.codex, default: 0] += total
            hourly[hKey] = h
        }
    }

    /// Extracts input_tokens and output_tokens from the "usage":{} block.
    /// Codex logs contain multiple token fields; we need the one inside
    /// `"usage":{"input_tokens":N,...,"output_tokens":N}`.
    private func extractTokens(from body: String) -> (Int64, Int64) {
        var input: Int64 = 0
        var output: Int64 = 0

        // Match the usage block: "usage":{"input_tokens":N,...,"output_tokens":N
        if let range = body.range(of: #""usage":\{"input_tokens":(\d+).*?"output_tokens":(\d+)"#,
                                   options: .regularExpression) {
            let match = String(body[range])
            if let inputRange = match.range(of: #"(?<="input_tokens":)\d+"#, options: .regularExpression) {
                input = Int64(match[inputRange]) ?? 0
            }
            if let outputRange = match.range(of: #"(?<="output_tokens":)\d+"#, options: .regularExpression) {
                output = Int64(match[outputRange]) ?? 0
            }
        }

        return (input, output)
    }
}
