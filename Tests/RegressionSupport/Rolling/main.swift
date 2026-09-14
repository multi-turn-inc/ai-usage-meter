import Foundation

let now = Date(timeIntervalSince1970: 1_700_000_000)
let events = (0..<12).map { i in TokenUsageEvent(id: "e\(i)", timestamp: now.addingTimeInterval(Double(-i * 300)), service: .codex, inputTokens: 10, outputTokens: 5, costUSD: 0.5) }
let summary = TokenUsageSummary(daily: [], hourly: [], events: events, lastParsed: now)
func check(_ value: Bool, _ message: String) { if !value { fatalError("FAIL: \(message)") } }
for (hours, count) in [(1, 12), (24, 24), (168, 7)] {
    check(summary.buckets(inLastHours: hours, count: count, now: now).reduce(0, +) == summary.tokens(inLastHours: hours, now: now), "bucket sum \(hours)h")
}
check(summary.tokens(inLastHours: 1, now: now) == 180, "rolling token total")
check(summary.cost(inLastHours: 1, now: now) == 6, "rolling cost")
check(summary.messages(inLastHours: 1, now: now) == 12, "rolling messages")
check(summary.tokens(inLastHours: -1, now: now) == 0, "negative token window")
check(summary.cost(inLastHours: 0, now: now) == 0, "zero cost window")
check(summary.messages(inLastHours: -1, now: now) == 0, "negative message window")
print("PASS rolling totals=\(summary.tokens(inLastHours: 1, now: now))/\(summary.tokens(inLastHours: 24, now: now))/\(summary.tokens(inLastHours: 168, now: now))")
