import XCTest
@testable import AIUsageMeterCore

final class TokenUsageSummaryTests: XCTestCase {
    func testRollingWindowUsesEventTimestampAndExcludesFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            TokenUsageEvent(id: "old", timestamp: now.addingTimeInterval(-3_700), service: .claude, inputTokens: 10, outputTokens: 0),
            TokenUsageEvent(id: "inside", timestamp: now.addingTimeInterval(-1_800), service: .claude, inputTokens: 20, outputTokens: 5),
            TokenUsageEvent(id: "future", timestamp: now.addingTimeInterval(60), service: .claude, inputTokens: 100, outputTokens: 0)
        ]
        let summary = TokenUsageSummary(daily: [], hourly: [], events: events, lastParsed: now)
        XCTAssertEqual(summary.tokens(inLastHours: 1, now: now), 25)
        XCTAssertEqual(summary.messages(inLastHours: 1, now: now), 1)
    }

    func testRollingWindowsExcludeFutureAndRejectNegativeHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            TokenUsageEvent(id: "edge", timestamp: now.addingTimeInterval(-3600), service: .claude, inputTokens: 2, outputTokens: 3, costUSD: 1),
            TokenUsageEvent(id: "future", timestamp: now.addingTimeInterval(1), service: .claude, inputTokens: 100, outputTokens: 0, costUSD: 10)
        ]
        let summary = TokenUsageSummary(daily: [], hourly: [], events: events, lastParsed: now)
        XCTAssertEqual(summary.tokens(inLastHours: 1, now: now), 5)
        XCTAssertEqual(summary.cost(inLastHours: 1, now: now), 1)
        XCTAssertEqual(summary.messages(inLastHours: 1, now: now), 1)
        XCTAssertEqual(summary.tokens(inLastHours: 0, now: now), 0)
        XCTAssertEqual(summary.cost(inLastHours: -1, now: now), 0)
        XCTAssertEqual(summary.messages(inLastHours: -1, now: now), 0)
    }

    func testBucketsAndNumericTotalsUseSameReferenceAndSum() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<12).map { i in
            TokenUsageEvent(id: "e\(i)", timestamp: now.addingTimeInterval(Double(-i * 300)), service: .codex, inputTokens: 10, outputTokens: 5)
        }
        let summary = TokenUsageSummary(daily: [], hourly: [], events: events, lastParsed: now)
        let bars = summary.buckets(inLastHours: 1, count: 12, now: now)
        XCTAssertEqual(bars.reduce(0, +), summary.tokens(inLastHours: 1, now: now))
        XCTAssertEqual(summary.buckets(inLastHours: 24, count: 24, now: now).reduce(0, +), summary.tokens(inLastHours: 24, now: now))
        XCTAssertEqual(summary.buckets(inLastHours: 24 * 7, count: 7, now: now).reduce(0, +), summary.tokens(inLastHours: 24 * 7, now: now))
    }
}
