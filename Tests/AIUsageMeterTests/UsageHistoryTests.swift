import XCTest
@testable import AIUsageMeterCore

final class UsageHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func test_compactionKeepsSevenDaysPerServiceAtHourlyResolution() {
        let now = ts("2026-07-23T12:00:00Z")
        let store = UsageHistoryStore(
            fileURL: temporaryFileURL(),
            calendar: calendar,
            now: { now }
        )
        var entries: [UsageHistoryEntry] = []

        for service in ServiceType.allCases {
            for fiveMinuteOffset in 0..<(7 * 24 * 12) {
                entries.append(UsageHistoryEntry(
                    serviceType: service,
                    timestamp: now.addingTimeInterval(-Double(fiveMinuteOffset * 5 * 60)),
                    fiveHourUsage: Double(fiveMinuteOffset % 100),
                    sevenDayUsage: nil
                ))
            }
        }
        entries.append(UsageHistoryEntry(
            serviceType: .claude,
            timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
            fiveHourUsage: 99,
            sevenDayUsage: 99
        ))

        let compacted = store.compact(entries, relativeTo: now)

        // A rolling seven-day interval can touch 169 calendar-hour buckets when
        // both boundary hours are partial.
        let expectedBucketsPerService = 7 * 24 + 1
        XCTAssertEqual(
            compacted.count,
            ServiceType.allCases.count * expectedBucketsPerService
        )
        for service in ServiceType.allCases {
            XCTAssertEqual(
                compacted.filter { $0.serviceType == service }.count,
                expectedBucketsPerService
            )
        }
        XCTAssertTrue(compacted.allSatisfy {
            $0.timestamp > now.addingTimeInterval(-7 * 24 * 60 * 60)
        })
    }

    func test_compactionKeepsLatestEntryWithinServiceHour() {
        let now = ts("2026-07-23T12:30:00Z")
        let store = UsageHistoryStore(
            fileURL: temporaryFileURL(),
            calendar: calendar,
            now: { now }
        )
        let earlier = UsageHistoryEntry(
            serviceType: .codex,
            timestamp: ts("2026-07-23T12:05:00Z"),
            fiveHourUsage: 10,
            sevenDayUsage: 20
        )
        let later = UsageHistoryEntry(
            serviceType: .codex,
            timestamp: ts("2026-07-23T12:25:00Z"),
            fiveHourUsage: 30,
            sevenDayUsage: 40
        )
        let otherService = UsageHistoryEntry(
            serviceType: .claude,
            timestamp: ts("2026-07-23T12:20:00Z"),
            fiveHourUsage: 50,
            sevenDayUsage: 60
        )

        let compacted = store.compact(
            [later, earlier, otherService],
            relativeTo: now
        )

        XCTAssertEqual(compacted.count, 2)
        XCTAssertEqual(
            compacted.first { $0.serviceType == .codex }?.fiveHourUsage,
            30
        )
        XCTAssertEqual(
            compacted.first { $0.serviceType == .claude }?.fiveHourUsage,
            50
        )
    }

    func test_saveEntryCompactsExistingCompatibleHistoryFile() throws {
        let now = ts("2026-07-23T12:30:00Z")
        let fileURL = temporaryFileURL()
        let oldEntry = UsageHistoryEntry(
            serviceType: .claude,
            timestamp: ts("2026-07-23T12:05:00Z"),
            fiveHourUsage: 10,
            sevenDayUsage: 20
        )
        let encoded = try JSONEncoder().encode([oldEntry])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: fileURL)

        let store = UsageHistoryStore(
            fileURL: fileURL,
            calendar: calendar,
            now: { now }
        )
        store.saveEntry(UsageHistoryEntry(
            serviceType: .claude,
            timestamp: ts("2026-07-23T12:25:00Z"),
            fiveHourUsage: 30,
            sevenDayUsage: 40
        ))

        let history = store.loadHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].fiveHourUsage, 30)
        XCTAssertEqual(history[0].sevenDayUsage, 40)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage_history.json")
    }
}
