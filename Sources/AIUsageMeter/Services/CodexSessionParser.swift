import Foundation

/// A single deduplicated Codex usage event (one turn's token delta).
struct CodexUsageEvent {
    let timestamp: Date
    let model: String?
    let inputTokens: Int64       // includes the cached portion
    let cachedInputTokens: Int64
    let outputTokens: Int64      // includes reasoning tokens
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
}

struct CodexRateLimitInfo {
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var primaryWindowMinutes: Int?
    var secondaryWindowMinutes: Int?
    var primaryResetTime: Date?
    var secondaryResetTime: Date?
    var planType: String?
}

/// Parses Codex CLI session rollout files (~/.codex/sessions and ~/.codex/archived_sessions)
/// into per-turn usage events, following ccusage's accounting model:
///
/// - Each `token_count` event contributes its `last_token_usage` delta (fallback:
///   `total_token_usage` minus the previous event's total), never the session-cumulative
///   total — so long-running sessions don't leak usage from outside the query window.
/// - Subagent sessions (`thread_spawn`) replay the parent's token history in a burst
///   sharing one timestamp second; that replayed block is skipped.
/// - Events identical across files (archived copies, forked/branched session history)
///   are deduplicated globally by (timestamp, model, token counts).
final class CodexSessionParser: @unchecked Sendable {
    static let shared = CodexSessionParser()

    struct Result {
        var events: [CodexUsageEvent] = []
        var rateLimits = CodexRateLimitInfo()
        var sessionCount: Int = 0
    }

    private let codexHome: String
    private let lock = NSLock()
    private var cache: (result: Result, since: Date, at: Date)?
    private let cacheTTL: TimeInterval = 60

    private init() {
        codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSHomeDirectory() + "/.codex"
    }

    // MARK: - Public

    func parse(since: Date) -> Result {
        lock.lock()
        if let cache,
           Date().timeIntervalSince(cache.at) < cacheTTL,
           abs(cache.since.timeIntervalSince(since)) < 300 {
            let result = cache.result
            lock.unlock()
            return result
        }
        lock.unlock()

        let result = doParse(since: since)

        lock.lock()
        cache = (result, since, Date())
        lock.unlock()
        return result
    }

    // MARK: - Parsing

    private func doParse(since: Date) -> Result {
        var result = Result()
        let files = sessionFiles(since: since)
        result.sessionCount = files.count

        var seenEventKeys = Set<String>()

        for file in files {
            parseFile(
                at: file,
                since: since,
                seenEventKeys: &seenEventKeys,
                events: &result.events,
                rateLimits: &result.rateLimits
            )
        }

        result.events.sort { $0.timestamp < $1.timestamp }
        return result
    }

    /// Collects rollout files from sessions/ and archived_sessions/, pruning the
    /// YYYY/MM/DD directory tree by date before touching files. Archived copies of a
    /// file already seen under sessions/ are skipped (same rollout filename).
    /// Returned sorted by modification date ascending so the newest file's
    /// rate_limits win.
    private func sessionFiles(since: Date) -> [URL] {
        let fm = FileManager.default
        let calendar = Calendar.current
        // Directory names use local dates; pad the cutoff to dodge timezone edges.
        let dayCutoff = calendar.startOfDay(for: since).addingTimeInterval(-48 * 3600)

        var collected: [(url: URL, modDate: Date)] = []
        var seenNames = Set<String>()

        for root in ["sessions", "archived_sessions"] {
            let rootURL = URL(fileURLWithPath: codexHome).appendingPathComponent(root)
            guard fm.fileExists(atPath: rootURL.path) else { continue }

            for yearURL in numericSubdirs(of: rootURL) {
                guard let year = Int(yearURL.lastPathComponent) else { continue }
                for monthURL in numericSubdirs(of: yearURL) {
                    guard let month = Int(monthURL.lastPathComponent) else { continue }
                    for dayURL in numericSubdirs(of: monthURL) {
                        guard let day = Int(dayURL.lastPathComponent),
                              let dayDate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                              dayDate >= dayCutoff else { continue }

                        let files = (try? fm.contentsOfDirectory(
                            at: dayURL,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: .skipsHiddenFiles
                        )) ?? []

                        for file in files where file.pathExtension == "jsonl" {
                            guard !seenNames.contains(file.lastPathComponent) else { continue }
                            guard let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                                  modDate >= since else { continue }
                            seenNames.insert(file.lastPathComponent)
                            collected.append((file, modDate))
                        }
                    }
                }
            }
        }

        return collected.sorted { $0.modDate < $1.modDate }.map(\.url)
    }

    private func numericSubdirs(of url: URL) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return dirs.filter { Int($0.lastPathComponent) != nil }
    }

    private func parseFile(
        at url: URL,
        since: Date,
        seenEventKeys: inout Set<String>,
        events: inout [CodexUsageEvent],
        rateLimits: inout CodexRateLimitInfo
    ) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let replaySecond = detectSubagentReplaySecond(data: data, lines: lines)

        var previousTotals: (input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64)?
        var currentModel: String?
        var skipReplay = replaySecond != nil

        for line in lines {
            // Cheap pre-filter before JSON decoding
            guard line.contains("\"token_count\"") || line.contains("\"turn_context\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }

            if obj["type"] as? String == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
                continue
            }

            guard payload["type"] as? String == "token_count" else { continue }
            guard let tsString = obj["timestamp"] as? String else { continue }

            captureRateLimits(from: payload, into: &rateLimits)

            let info = payload["info"] as? [String: Any]
            let total = usageTuple(info?["total_token_usage"] as? [String: Any])

            // Replayed parent history in a thread_spawn subagent file: skip the
            // events, but keep the running total so later deltas stay correct.
            if skipReplay, let replaySecond {
                if tsString.hasPrefix(replaySecond) {
                    if let total { previousTotals = total }
                    continue
                }
                skipReplay = false
            }

            let delta: (input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64)?
            if let last = usageTuple(info?["last_token_usage"] as? [String: Any]) {
                delta = last
            } else if let total {
                let prev = previousTotals
                delta = (
                    max(0, total.input - (prev?.input ?? 0)),
                    max(0, total.cached - (prev?.cached ?? 0)),
                    max(0, total.output - (prev?.output ?? 0)),
                    max(0, total.reasoning - (prev?.reasoning ?? 0)),
                    max(0, total.total - (prev?.total ?? 0))
                )
            } else {
                delta = nil
            }
            if let total { previousTotals = total }

            guard let delta,
                  delta.input != 0 || delta.cached != 0 || delta.output != 0 || delta.reasoning != 0 else {
                continue
            }

            guard let timestamp = parseISO8601(tsString), timestamp >= since else { continue }

            // Global dedup: archived copies and forked sessions replicate the exact
            // same (timestamp, usage) lines across files.
            let key = "\(tsString)|\(currentModel ?? "")|\(delta.input)|\(delta.cached)|\(delta.output)|\(delta.reasoning)|\(delta.total)"
            guard seenEventKeys.insert(key).inserted else { continue }

            events.append(CodexUsageEvent(
                timestamp: timestamp,
                model: currentModel,
                inputTokens: delta.input,
                cachedInputTokens: min(delta.cached, delta.input),
                outputTokens: delta.output,
                reasoningOutputTokens: delta.reasoning,
                totalTokens: delta.total
            ))
        }
    }

    /// Subagent (thread_spawn) files replay the parent's token history as a burst of
    /// token_count events sharing one timestamp second. Returns that second
    /// ("YYYY-MM-DDTHH:MM:SS") when the first two token_count events collide, else nil.
    private func detectSubagentReplaySecond(data: Data, lines: [Substring]) -> String? {
        guard data.prefix(16 * 1024).range(of: Data("thread_spawn".utf8)) != nil else { return nil }

        var firstSecond: String?
        for line in lines {
            guard line.contains("\"token_count\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  info["total_token_usage"] != nil || info["last_token_usage"] != nil,
                  let ts = obj["timestamp"] as? String, ts.count >= 19 else { continue }

            let second = String(ts.prefix(19))
            if let first = firstSecond {
                return first == second ? first : nil
            }
            firstSecond = second
        }
        return nil
    }

    private func usageTuple(_ dict: [String: Any]?) -> (input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64)? {
        guard let dict else { return nil }
        return (
            int64(dict["input_tokens"]),
            int64(dict["cached_input_tokens"]),
            int64(dict["output_tokens"]),
            int64(dict["reasoning_output_tokens"]),
            int64(dict["total_tokens"])
        )
    }

    private func captureRateLimits(from payload: [String: Any], into rateLimits: inout CodexRateLimitInfo) {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return }

        if let primary = limits["primary"] as? [String: Any] {
            if let percent = double(primary["used_percent"]) { rateLimits.primaryUsedPercent = percent }
            if let minutes = double(primary["window_minutes"]) { rateLimits.primaryWindowMinutes = Int(minutes) }
            if let resets = double(primary["resets_at"]) { rateLimits.primaryResetTime = Date(timeIntervalSince1970: resets) }
        }
        if let secondary = limits["secondary"] as? [String: Any] {
            if let percent = double(secondary["used_percent"]) { rateLimits.secondaryUsedPercent = percent }
            if let minutes = double(secondary["window_minutes"]) { rateLimits.secondaryWindowMinutes = Int(minutes) }
            if let resets = double(secondary["resets_at"]) { rateLimits.secondaryResetTime = Date(timeIntervalSince1970: resets) }
        }
        if let plan = limits["plan_type"] as? String { rateLimits.planType = plan }
    }

    private func int64(_ value: Any?) -> Int64 {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let d = value as? Double { return Int64(d) }
        return 0
    }

    private func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
