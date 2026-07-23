import Foundation

/// A single deduplicated Codex usage event (one turn's token delta).
public struct CodexUsageEvent {
    public let timestamp: Date
    public let model: String?
    public let inputTokens: Int64       // includes the cached portion
    public let cachedInputTokens: Int64
    public let outputTokens: Int64      // includes reasoning tokens
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64

    public init(
        timestamp: Date,
        model: String?,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = min(max(0, cachedInputTokens), max(0, inputTokens))
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    /// Input tokens that were not served from the prompt cache. OpenAI reports
    /// cached input as a subset of input, unlike Anthropic's separate fields.
    public var nonCachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens)
    }

    /// Cross-service display total. Cache traffic is tracked separately so the
    /// Claude and Codex numbers shown side-by-side use the same accounting basis.
    public var displayTotalTokens: Int64 {
        nonCachedInputTokens + outputTokens
    }
}

public struct CodexRateLimitInfo {
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryWindowMinutes: Int?
    public var secondaryWindowMinutes: Int?
    public var primaryResetTime: Date?
    public var secondaryResetTime: Date?
    public var planType: String?
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
///
/// Performance: Codex rollout files can be **hundreds of MB each** (tool output is logged
/// inline). The parser therefore NEVER loads a file into memory whole — it streams 1 MB
/// chunks **exactly once per file** (a cheap 16 KB header probe aside), byte-scans each
/// line for the sparse `token_count`/`turn_context` markers before any JSON/String work,
/// and reuses a single date formatter. One canonical ~8-day parse is cached and shared by
/// every caller/window, and overlapping parses are coalesced, so a 5-minute refresh can't
/// pile multi-GB scans on top of each other.
public final class CodexSessionParser: @unchecked Sendable {
    public static let shared = CodexSessionParser()

    public struct Result {
        public var events: [CodexUsageEvent] = []
        public var rateLimits = CodexRateLimitInfo()
        public var sessionCount: Int = 0
    }

    private struct FileCacheEntry {
        let size: Int
        let mtime: TimeInterval
        let events: [CodexUsageEvent]
        let rateLimits: CodexRateLimitInfo?
    }

    private let codexHome: String
    private let canonicalWindowStartOverride: Date?
    private let lock = NSLock()
    private var cache: (result: Result, at: Date)?
    private var parsing = false
    /// Per-file parsed results, keyed by path, reused while size+mtime are unchanged so
    /// only files Codex actually appended to get re-read (static older files are skipped).
    /// Only touched inside the serialized doParse, so no extra locking needed.
    private var fileCache: [String: FileCacheEntry] = [:]
    private let cacheTTL: TimeInterval = 300
    /// Widest window any caller needs (7-day) plus slack for timezone/mtime edges.
    private let windowDays = 8
    /// token_count / turn_context lines are tiny; anything larger is inline tool output we
    /// skip without buffering, so one giant line can't balloon memory.
    private let maxLineBytes = 2 << 20

    // Reused across the whole (serialized) parse — creating an ISO8601DateFormatter per
    // timestamp was the single biggest CPU cost (repeated ICU symbol initialization).
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private static let turnContextNeedle = Data("\"turn_context\"".utf8)
    private static let threadSpawnNeedle = Data("thread_spawn".utf8)

    private init() {
        codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSHomeDirectory() + "/.codex"
        canonicalWindowStartOverride = nil
    }

    /// Testing initializer — injects a custom codexHome path instead of ~/.codex.
    /// Not intended for production use.
    init(codexHomeForTesting: String) {
        codexHome = codexHomeForTesting
        // Test fixtures use stable historical dates. Keep the production eight-day
        // scan window while making those fixtures independent of the wall clock.
        canonicalWindowStartOverride = Date(timeIntervalSince1970: 0)
    }

    // MARK: - Public

    /// Returns events at or after `since`, sourced from one cached canonical parse of the
    /// last ~8 days so the 24h and 7d callers don't each trigger a full scan.
    public func parse(since: Date) -> Result {
        let full = cachedFullParse()
        let events = full.events.filter { $0.timestamp >= since }
        return Result(events: events, rateLimits: full.rateLimits, sessionCount: full.sessionCount)
    }

    private func cachedFullParse() -> Result {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.at) < cacheTTL {
            defer { lock.unlock() }
            return cache.result
        }
        // A parse is already running (they can take seconds on multi-GB histories) —
        // serve the last good result rather than starting a second concurrent scan.
        if parsing {
            let stale = cache?.result ?? Result()
            lock.unlock()
            return stale
        }
        parsing = true
        lock.unlock()

        let windowStart = canonicalWindowStartOverride
            ?? Date().addingTimeInterval(-Double(windowDays) * 86400)
        let result = doParse(since: windowStart)

        lock.lock()
        cache = (result, Date())
        parsing = false
        lock.unlock()
        return result
    }

    // MARK: - Parsing

    private func doParse(since: Date) -> Result {
        var result = Result()
        let files = sessionFiles(since: since)
        result.sessionCount = files.count

        var seenEventKeys = Set<String>()
        var freshCache: [String: FileCacheEntry] = [:]

        for file in files {
            let path = file.path
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? -1
            let mtime = attrs?.contentModificationDate?.timeIntervalSince1970 ?? -1

            let entry: FileCacheEntry
            if let cached = fileCache[path], cached.size == size, cached.mtime == mtime {
                entry = cached  // file untouched since last parse — reuse
            } else {
                let (events, rl) = parseFile(at: file, since: since)
                entry = FileCacheEntry(size: size, mtime: mtime, events: events, rateLimits: rl)
            }
            freshCache[path] = entry

            if let rl = entry.rateLimits { result.rateLimits = rl }  // newest file wins (mtime order)
            for event in entry.events {
                // Global dedup: archived copies and forked sessions replicate the exact
                // same (timestamp, usage) lines across files.
                let key = "\(event.timestamp.timeIntervalSince1970)|\(event.model ?? "")|\(event.inputTokens)|\(event.cachedInputTokens)|\(event.outputTokens)|\(event.reasoningOutputTokens)|\(event.totalTokens)"
                if seenEventKeys.insert(key).inserted {
                    result.events.append(event)
                }
            }
        }

        fileCache = freshCache  // drop entries for files that aged out of the window
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

    /// Streams one rollout file, returning its in-window usage deltas and the most recent
    /// rate_limits block it contained (nil if none). Never holds more than a 1 MB chunk
    /// plus the current line in memory.
    ///
    /// Subagent (thread_spawn) replay detection is folded into this single pass: files
    /// carrying the `thread_spawn` marker in their header defer the first token_count
    /// line until the second one arrives, then compare their timestamp seconds. Matching
    /// seconds mark a parent-history replay burst (skipped, running totals kept); a
    /// mismatch flushes both lines through the normal event path. Non-subagent files
    /// stream straight through with no deferral overhead.
    private func parseFile(at url: URL, since: Date) -> (events: [CodexUsageEvent], rateLimits: CodexRateLimitInfo?) {
        // Cheap header probe so non-subagent files don't pay the deferral cost.
        let mayReplay = fileHeaderContainsThreadSpawn(at: url)

        var events: [CodexUsageEvent] = []
        var rateLimits: CodexRateLimitInfo?
        var previousTotals: (input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64)?
        var currentModel: String?

        // Replay-detection state. `pendingFirstLine` holds the raw first token_count line
        // (kept as Data so we can re-parse it once we know its fate) plus the model that
        // was current when we saw it, so a turn_context arriving between the first and
        // second token_count doesn't rewrite the deferred event's model. `replaySecond`
        // is set only after we confirm the first two token_count timestamps share a
        // second. `skipReplay` mirrors the old parseFile flag: true inside the burst.
        var awaitingSecondTokenLine = mayReplay
        var pendingFirstLine: Data?
        var pendingFirstSecond: String?
        var pendingFirstModel: String?
        var replaySecond: String?
        var skipReplay = false

        // Handles one token_count line's payload. When `modelOverride` is provided it
        // wins over the live `currentModel` — used to freeze the deferred first line's
        // model at the moment it was seen, matching the original two-pass semantics.
        func processTokenCount(line: Data, modelOverride: String? = nil) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let tsString = obj["timestamp"] as? String else { return }

            var rl = rateLimits ?? CodexRateLimitInfo()
            if captureRateLimits(from: payload, into: &rl) { rateLimits = rl }

            let info = payload["info"] as? [String: Any]
            let total = self.usageTuple(info?["total_token_usage"] as? [String: Any])

            // Replayed parent history in a thread_spawn subagent file: skip the
            // events, but keep the running total so later deltas stay correct.
            if skipReplay, let replaySecond {
                if tsString.hasPrefix(replaySecond) {
                    if let total { previousTotals = total }
                    return
                }
                skipReplay = false
            }

            let delta: (input: Int64, cached: Int64, output: Int64, reasoning: Int64, total: Int64)?
            if let last = self.usageTuple(info?["last_token_usage"] as? [String: Any]) {
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
                return
            }

            guard let timestamp = self.parseISO8601(tsString), timestamp >= since else { return }

            events.append(CodexUsageEvent(
                timestamp: timestamp,
                model: modelOverride ?? currentModel,
                inputTokens: delta.input,
                cachedInputTokens: min(delta.cached, delta.input),
                outputTokens: delta.output,
                reasoningOutputTokens: delta.reasoning,
                totalTokens: delta.total
            ))
        }

        // Returns the timestamp-second prefix ("YYYY-MM-DDTHH:MM:SS") only for token_count
        // lines that also carry a usage block — mirrors the old detector's qualifier so
        // header/heartbeat-shaped lines don't accidentally trigger replay skipping.
        func replayCandidateSecond(from line: Data) -> String? {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  info["total_token_usage"] != nil || info["last_token_usage"] != nil,
                  let ts = obj["timestamp"] as? String, ts.count >= 19 else { return nil }
            return String(ts.prefix(19))
        }

        forEachLine(at: url) { line in
            let isTokenCount = line.range(of: Self.tokenCountNeedle) != nil
            let isTurnContext = !isTokenCount && line.range(of: Self.turnContextNeedle) != nil
            guard isTokenCount || isTurnContext else { return true }

            if isTurnContext {
                // turn_context lines are always processed live — they only update the
                // current model and never contribute usage, so replay deferral is moot.
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   obj["type"] as? String == "turn_context",
                   let payload = obj["payload"] as? [String: Any],
                   let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
                return true
            }

            // token_count line: run replay detection in-band on the first two qualifying
            // lines. Non-qualifying lines (no usage block, bad JSON) are handled by
            // processTokenCount's own guards and don't consume the deferral slot.
            if awaitingSecondTokenLine {
                guard let candidateSecond = replayCandidateSecond(from: line) else {
                    // Not a qualifying token_count line — process normally without
                    // spending the deferral slot on it.
                    processTokenCount(line: line)
                    return true
                }

                if pendingFirstLine == nil {
                    // First qualifying token_count line: hold it (and freeze the current
                    // model) until we see the next one.
                    pendingFirstLine = line
                    pendingFirstSecond = candidateSecond
                    pendingFirstModel = currentModel
                    return true
                }

                // Second qualifying token_count line: decide replay vs. real usage.
                if let firstSecond = pendingFirstSecond, firstSecond == candidateSecond {
                    // Replay burst confirmed. Both lines feed processTokenCount under
                    // skipReplay=true so they bump previousTotals but emit no events;
                    // model doesn't matter because no event is produced.
                    replaySecond = firstSecond
                    skipReplay = true
                    if let first = pendingFirstLine { processTokenCount(line: first) }
                    processTokenCount(line: line)
                } else {
                    // Not a replay: flush the deferred first line with the model that
                    // was current when we saw it (so an intervening turn_context can't
                    // retroactively rewrite this event's model), then process the
                    // current line with the live currentModel.
                    if let first = pendingFirstLine {
                        processTokenCount(line: first, modelOverride: pendingFirstModel)
                    }
                    processTokenCount(line: line)
                }
                pendingFirstLine = nil
                pendingFirstSecond = nil
                pendingFirstModel = nil
                awaitingSecondTokenLine = false
                return true
            }

            processTokenCount(line: line)
            return true
        }

        // File ended before a second qualifying token_count line arrived: the deferred
        // first line is a real event (no replay possible with only one), so flush it
        // with the model that was frozen at deferral time.
        if let first = pendingFirstLine {
            processTokenCount(line: first, modelOverride: pendingFirstModel)
        }

        return (events, rateLimits)
    }

    /// Reads only the first 16 KB of a file to check whether the `thread_spawn` marker
    /// (present in every subagent rollout) appears in the header. Files without it are
    /// guaranteed not to need replay-burst deferral, so `parseFile` can stream straight
    /// through instead of buffering the first token_count line.
    private func fileHeaderContainsThreadSpawn(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        return head.range(of: Self.threadSpawnNeedle) != nil
    }

    /// Streams a file line by line. `body` returns false to stop early. Holds at most a
    /// 1 MB chunk plus the current partial line; lines longer than `maxLineBytes` (inline
    /// tool output, never a usage event) are discarded without buffering.
    private func forEachLine(at url: URL, _ body: (Data) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let newline: UInt8 = 0x0A
        var carry = Data()
        var skipping = false  // discarding an over-long line until its newline
        while let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil, !chunk.isEmpty {
            var data: Data
            if carry.isEmpty {
                data = chunk
            } else {
                data = carry
                data.append(chunk)
                carry = Data()
            }

            var start = data.startIndex
            while let nl = data[start...].firstIndex(of: newline) {
                if skipping {
                    skipping = false  // this newline ends the discarded line
                } else if !body(data.subdata(in: start..<nl)) {
                    return
                }
                start = data.index(after: nl)
            }

            if skipping {
                continue  // still inside an over-long line
            }
            if data.distance(from: start, to: data.endIndex) > maxLineBytes {
                skipping = true  // current line is too long to be a usage event — drop it
            } else {
                carry = data.subdata(in: start..<data.endIndex)
            }
        }
        if !skipping, !carry.isEmpty { _ = body(carry) }
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

    /// Returns true if any rate-limit field was present (so the caller only overwrites
    /// when the line actually carried rate_limits).
    private func captureRateLimits(from payload: [String: Any], into rateLimits: inout CodexRateLimitInfo) -> Bool {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return false }

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
        return true
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
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
