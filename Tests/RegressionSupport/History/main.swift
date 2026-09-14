import Foundation
import AIUsageMeterCore

let now = Date(timeIntervalSince1970: 2_000_000_000), decoder = JSONDecoder()
func entry(_ s: ServiceType, _ d: Date) -> UsageHistoryEntry { let j = "{\"id\":\"\(UUID())\",\"serviceType\":\"\(s.rawValue)\",\"timestamp\":\(d.timeIntervalSinceReferenceDate),\"fiveHourUsage\":1,\"sevenDayUsage\":2}"; return try! decoder.decode(UsageHistoryEntry.self, from: Data(j.utf8)) }
let all = ServiceType.allCases.flatMap { s in (0..<7*24*60).map { entry(s, now.addingTimeInterval(Double(-$0*60))) } }
func ok(_ b: Bool, _ s: String) { if !b { fatalError("FAIL \(s)") } }
let kept = UsageHistoryStore.trim(all, now: now); ok(kept.count == all.count, "seven-day one-minute retention"); ok(kept.first!.timestamp > now.addingTimeInterval(-7*86400), "oldest retained")
let base = now.addingTimeInterval(-120), manual = UsageHistoryStore.trim([entry(.claude, base), entry(.claude, base.addingTimeInterval(20))], now: now); ok(manual.count == 1 && manual[0].timestamp > base, "latest same-minute")
ok(UsageHistoryStore.trim(all + [entry(.claude, now.addingTimeInterval(-8*86400))], now: now).count == all.count, "expiry")
print("PASS history entries=\(kept.count)")
