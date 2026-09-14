import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("claude-regression-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
let nested = root.appendingPathComponent("project/nested", isDirectory: true)
try! fm.createDirectory(at: nested, withIntermediateDirectories: true)
let partial = """
{"type":"assistant","message":{"id":"cross-midnight","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":0}},"requestId":"old","timestamp":"2026-07-01T23:59:59.000Z"}
"""
let final = """
{"type":"assistant","message":{"id":"cross-midnight","model":"claude-sonnet-4-6","usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":5}}},"requestId":"new","timestamp":"2026-07-02T00:00:01.000Z"}
"""
let first = root.appendingPathComponent("project/z.jsonl")
let second = nested.appendingPathComponent("a.jsonl")
try! partial.write(to: first, atomically: true, encoding: .utf8)
try! final.write(to: second, atomically: true, encoding: .utf8)
let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
let fixedNow = ISO8601DateFormatter()
fixedNow.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let now = fixedNow.date(from: "2026-07-02T02:00:00.000Z")!
var summary = parser.parse(days: 1, now: now)
check(summary.events.count == 1, "partial/final duplicate resolves to one event")
let expectedTimestamp = ISO8601DateFormatter()
expectedTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
check(summary.events[0].timestamp == expectedTimestamp.date(from: "2026-07-01T23:59:59.000Z")!, "earliest timestamp is preserved")
check(summary.events[0].inputTokens == 245 && summary.events[0].outputTokens == 80, "cache lanes included exactly once in displayed input")
check(summary.daily.reduce(0) { $0 + $1.inputTokens } == 245, "daily total matches event total")
check(summary.daily.reduce(0) { $0 + $1.outputTokens } == 80, "daily output matches event total")
check(summary.hourly.reduce(0) { $0 + $1.totalTokens } == 325, "hourly total matches event total")
check(summary.daily.reduce(0) { $0 + ($1.byService[.claude] ?? 0) } == 325, "daily service total matches event total")
check(summary.hourly.reduce(0) { $0 + ($1.byService[.claude] ?? 0) } == 325, "hourly service total matches event total")
let cost = summary.events[0].costUSD
check(abs(cost - ((200.0 * 3 + 80 * 15 + 10 * 3.75 + 5 * 6 + 30 * 0.3) / 1_000_000)) < 1e-12, "cache pricing uses separate lanes")

// Unchanged parses reuse cached records; appending invalidates only this file.
let before = summary.events.count
try! "\n{\"type\":\"assistant\",\"message\":{\"id\":\"appended\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}},\"timestamp\":\"2026-07-02T01:00:00Z\"}\n".append(to: first)
summary = parser.parse(days: 1, now: now)
check(before == 1 && summary.events.count == 2, "appending a file invalidates its cache")
let repeated = parser.parse(days: 1, now: now)
check(repeated.events.count == summary.events.count && repeated.events.map(\.id) == summary.events.map(\.id), "unchanged repeated parse is stable")
print("Claude parser regression assertions passed")

extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(utf8))
    }
}
