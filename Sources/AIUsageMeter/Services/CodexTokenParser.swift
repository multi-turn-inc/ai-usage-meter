import Foundation

/// Merges Codex token usage into the shared daily/hourly chart buckets.
/// Data comes from CodexSessionParser (session rollout files with per-turn
/// deltas and dedup) — the same source ccusage uses — rather than the legacy
/// logs_2.sqlite scan, so chart numbers match the service card.
final class CodexTokenParser {
    static let shared = CodexTokenParser()

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

    private init() {}

    /// Merges Codex token data into existing daily/hourly buckets.
    func merge(into daily: inout [String: DailyTokenUsage],
               hourly: inout [String: HourlyTokenUsage],
               days: Int = 7) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let result = CodexSessionParser.shared.parse(since: cutoff)

        for event in result.events {
            let total = event.totalTokens > 0 ? event.totalTokens : event.inputTokens + event.outputTokens
            let cost = ModelPricing.shared.codexCost(
                model: event.model,
                input: event.inputTokens,
                cachedInput: event.cachedInputTokens,
                output: event.outputTokens
            )
            guard total > 0 || cost > 0 else { continue }

            // Daily
            let dayKey = dayFormatter.string(from: event.timestamp)
            var d = daily[dayKey] ?? DailyTokenUsage(date: dayKey)
            d.inputTokens += event.inputTokens
            d.outputTokens += event.outputTokens
            d.messageCount += 1
            d.costUSD += cost
            d.byService[.codex, default: 0] += total
            daily[dayKey] = d

            // Hourly
            let hKey = hourFormatter.string(from: event.timestamp)
            let hourStart = Calendar.current.dateInterval(of: .hour, for: event.timestamp)?.start ?? event.timestamp
            var h = hourly[hKey] ?? HourlyTokenUsage(hourKey: hKey, timestamp: hourStart)
            h.totalTokens += total
            h.messageCount += 1
            h.costUSD += cost
            h.byService[.codex, default: 0] += total
            hourly[hKey] = h
        }
    }
}
