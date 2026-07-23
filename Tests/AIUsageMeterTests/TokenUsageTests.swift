import XCTest
@testable import AIUsageMeterCore

final class TokenUsageTests: XCTestCase {
    func test_codexDisplayTotalExcludesCachedInputSubset() {
        let event = CodexUsageEvent(
            timestamp: Date(),
            model: "gpt-5",
            inputTokens: 200,
            cachedInputTokens: 20,
            outputTokens: 80,
            reasoningOutputTokens: 10,
            totalTokens: 280
        )

        XCTAssertEqual(event.nonCachedInputTokens, 180)
        XCTAssertEqual(event.displayTotalTokens, 260)
        XCTAssertEqual(event.cachedInputTokens, 20)
    }

    func test_codexEventClampsMalformedCachedInputToInputTotal() {
        let event = CodexUsageEvent(
            timestamp: Date(),
            model: nil,
            inputTokens: 100,
            cachedInputTokens: 150,
            outputTokens: 40,
            reasoningOutputTokens: 0,
            totalTokens: 140
        )

        XCTAssertEqual(event.cachedInputTokens, 100)
        XCTAssertEqual(event.nonCachedInputTokens, 0)
        XCTAssertEqual(event.displayTotalTokens, 40)
    }

    func test_summaryKeepsCachedInputSeparateFromComparableTotal() {
        let now = Date()
        let dayKey = TokenUsageSummary.dayKey(for: now)
        let hourFormatter = DateFormatter()
        hourFormatter.dateFormat = "yyyy-MM-dd HH"
        hourFormatter.timeZone = .current

        var daily = DailyTokenUsage(date: dayKey)
        daily.inputTokens = 180
        daily.cachedInputTokens = 20
        daily.outputTokens = 80
        daily.byService[.codex] = 260

        var hourly = HourlyTokenUsage(
            hourKey: hourFormatter.string(from: now),
            timestamp: now
        )
        hourly.totalTokens = 260
        hourly.cachedInputTokens = 20
        hourly.byService[.codex] = 260

        let summary = TokenUsageSummary(
            daily: [daily],
            hourly: [hourly],
            lastParsed: now
        )

        XCTAssertEqual(daily.totalTokens, 260)
        XCTAssertEqual(summary.todayTokens, 260)
        XCTAssertEqual(summary.weekTokens, 260)
        XCTAssertEqual(summary.tokens(inLastHours: 1), 260)
        XCTAssertEqual(summary.todayCachedTokens, 20)
        XCTAssertEqual(summary.weekCachedTokens, 20)
        XCTAssertEqual(summary.cachedTokens(inLastHours: 1), 20)
    }
}
