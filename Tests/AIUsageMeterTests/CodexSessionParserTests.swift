import XCTest
@testable import AIUsageMeterCore

// MARK: - Helpers

/// Builds a fake ~/.codex tree under a temp directory from a dictionary of
/// { relative-path-under-sessions/YYYY/MM/DD : content }.
func makeCodexHome(files: [String: String]) -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    for (relative, content) in files {
        let dest = tmp.appendingPathComponent("sessions").appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try! content.write(to: dest, atomically: true, encoding: .utf8)
    }
    return tmp
}

/// ISO-8601 timestamp string → Date.
func ts(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

/// Fixture timestamps MUST be relative to now. `CodexSessionParser` only scans a
/// recent window (`windowDays`), so hard-coded fixture dates silently rot: once
/// they age past the window every parse returns zero events and the suite fails
/// for a reason that has nothing to do with the parser. Two days back is safely
/// inside the window in every timezone.
private let fixtureDayDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!

/// "YYYY-MM-DD" used inside fixture JSON timestamps.
let fixtureDay: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: fixtureDayDate)
}()

/// "YYYY/MM/DD" used for the sessions/ directory layout (parsed with Calendar.current).
let fixtureDir: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/MM/dd"
    return f.string(from: fixtureDayDate)
}()

/// A `since` far enough back to include every fixture, itself relative to now.
let farPast = Date().addingTimeInterval(-30 * 86400)

// MARK: - CodexSessionParserTests

final class CodexSessionParserTests: XCTestCase {

    // MARK: Fixture (a): normal single session with two token_count events using last_token_usage
    //
    // Expected:
    //   event 1: timestamp=\(fixtureDay)T10:00:05Z  input=100  cachedInput=0  output=50  reasoning=0  total=150
    //   event 2: timestamp=\(fixtureDay)T10:01:00Z  input=200  cachedInput=20 output=80  reasoning=10 total=280
    //   both tagged model="gpt-5.3-codex"
    func test_simpleSession_emitsTwoEventsWithCorrectCounts() {
        // Fixture a — no thread_spawn; parser streams straight through.
        let content = """
        {"timestamp":"\(fixtureDay)T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"\(fixtureDay)T10:00:05.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":150}}}}
        {"timestamp":"\(fixtureDay)T10:01:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":20,"output_tokens":80,"reasoning_output_tokens":10,"total_tokens":280}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/a_simple.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 2)
        guard result.events.count == 2 else { return }

        let e1 = result.events[0]
        XCTAssertEqual(e1.inputTokens, 100)
        XCTAssertEqual(e1.cachedInputTokens, 0)
        XCTAssertEqual(e1.outputTokens, 50)
        XCTAssertEqual(e1.reasoningOutputTokens, 0)
        XCTAssertEqual(e1.totalTokens, 150)
        XCTAssertEqual(e1.model, "gpt-5.3-codex")

        let e2 = result.events[1]
        XCTAssertEqual(e2.inputTokens, 200)
        XCTAssertEqual(e2.cachedInputTokens, 20)
        XCTAssertEqual(e2.outputTokens, 80)
        XCTAssertEqual(e2.reasoningOutputTokens, 10)
        XCTAssertEqual(e2.totalTokens, 280)
        XCTAssertEqual(e2.model, "gpt-5.3-codex")
    }

    // MARK: Fixture (b): thread_spawn + replay burst (same second) + real event after
    //
    // File contains thread_spawn, then two token_count lines sharing the same
    // timestamp-second (11:00:05) — these are a parent-history replay burst and
    // must NOT emit events. The third token_count at 11:01:00 is real.
    //
    // Replay lines use total_token_usage=700; the real line uses last_token_usage=420.
    //
    // Expected: 1 event
    //   event 1: input=300  output=120  total=420
    func test_replaySameSecond_skipsReplayEmitsOneRealEvent() {
        let content = """
        {"timestamp":"\(fixtureDay)T11:00:00.000Z","type":"event","payload":{"type":"thread_spawn","info":{}}}
        {"timestamp":"\(fixtureDay)T11:00:05.000Z","type":"event","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":700}}}}
        {"timestamp":"\(fixtureDay)T11:00:05.500Z","type":"event","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":200,"reasoning_output_tokens":0,"total_tokens":700}}}}
        {"timestamp":"\(fixtureDay)T11:01:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"output_tokens":120,"reasoning_output_tokens":0,"total_tokens":420}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/b_replay.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 1,
            "Replay burst (same-second pair) must be skipped; only the real event after it counts")
        guard result.events.count == 1 else { return }

        let e = result.events[0]
        XCTAssertEqual(e.inputTokens, 300)
        XCTAssertEqual(e.outputTokens, 120)
        XCTAssertEqual(e.totalTokens, 420)
    }

    // MARK: Fixture (c): thread_spawn + two token_count lines at DIFFERENT seconds (no replay)
    //
    // thread_spawn is present but the first two qualifying lines differ by 2 seconds
    // (12:00:05 vs 12:00:07). Both must be emitted as real events.
    //
    // Expected: 2 events
    //   event 1: input=150  output=60  total=210  (at 12:00:05, using last_token_usage)
    //   event 2: input=250  output=90  total=340  (at 12:00:07, using last_token_usage)
    func test_threadSpawnDifferentSecond_bothEventsEmitted() {
        let content = """
        {"timestamp":"\(fixtureDay)T12:00:00.000Z","type":"event","payload":{"type":"thread_spawn","info":{}}}
        {"timestamp":"\(fixtureDay)T12:00:05.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":60,"reasoning_output_tokens":0,"total_tokens":210}}}}
        {"timestamp":"\(fixtureDay)T12:00:07.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":250,"cached_input_tokens":10,"output_tokens":90,"reasoning_output_tokens":5,"total_tokens":340}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/c_no_replay.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 2,
            "Different-second thread_spawn lines are real events, not replay")
        guard result.events.count == 2 else { return }

        let e1 = result.events[0]
        XCTAssertEqual(e1.inputTokens, 150)
        XCTAssertEqual(e1.outputTokens, 60)
        XCTAssertEqual(e1.totalTokens, 210)

        let e2 = result.events[1]
        XCTAssertEqual(e2.inputTokens, 250)
        XCTAssertEqual(e2.outputTokens, 90)
        XCTAssertEqual(e2.totalTokens, 340)
    }

    // MARK: Fixture (d): model changes mid-session via turn_context
    //
    // First token_count at 13:00:05 happens while model = "gpt-5.3-codex".
    // A turn_context at 13:01:00 changes model to "gpt-5.4".
    // Second token_count at 13:01:10 should be tagged "gpt-5.4".
    //
    // Expected: 2 events, first model="gpt-5.3-codex", second model="gpt-5.4"
    func test_modelChange_eachEventTaggedWithModelAtEmitTime() {
        let content = """
        {"timestamp":"\(fixtureDay)T13:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"\(fixtureDay)T13:00:05.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0,"total_tokens":140}}}}
        {"timestamp":"\(fixtureDay)T13:01:00.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(fixtureDay)T13:01:10.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":0,"total_tokens":280}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/d_model_change.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 2)
        guard result.events.count == 2 else { return }
        XCTAssertEqual(result.events[0].model, "gpt-5.3-codex")
        XCTAssertEqual(result.events[1].model, "gpt-5.4")
    }

    // MARK: Fixture (e): empty file produces no events
    func test_emptyFile_producesNoEvents() {
        let home = makeCodexHome(files: ["\(fixtureDir)/e_empty.jsonl": ""])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 0)
    }

    // MARK: Global dedup across files — identical (timestamp, tokens) events in two files
    //
    // Archived copies replicate the same lines verbatim. The global dedup key is
    // (timestamp | model | inputTokens | cachedInputTokens | outputTokens | reasoningOutputTokens | totalTokens).
    // Both files carry the same single event → only 1 event must appear in the result.
    func test_globalDedup_identicalEventsAcrossFilesCountedOnce() {
        let sharedLine = """
        {"timestamp":"\(fixtureDay)T15:00:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0,"total_tokens":140}}}}
        """
        let home = makeCodexHome(files: [
            "\(fixtureDir)/dup_a.jsonl": sharedLine,
            "\(fixtureDir)/dup_b.jsonl": sharedLine,
        ])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 1,
            "Identical events across multiple files must be deduplicated globally")
        guard result.events.count == 1 else { return }
    }

    // MARK: Delta fallback — when last_token_usage is absent, use total_token_usage diff
    //
    // First event: total = (400, 0, 150, 0, 550). No last_token_usage → delta = total - 0 = (400,0,150,0,550).
    // Second event: total = (600, 20, 250, 0, 850). delta = (200,20,100,0,300).
    //
    // Expected: 2 events with deltas above.
    func test_deltaFallback_totalMinusPreviousTotal() {
        let content = """
        {"timestamp":"\(fixtureDay)T16:00:00.000Z","type":"event","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":0,"total_tokens":550}}}}
        {"timestamp":"\(fixtureDay)T16:01:00.000Z","type":"event","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":20,"output_tokens":250,"reasoning_output_tokens":0,"total_tokens":850}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/delta_fallback.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 2)
        guard result.events.count == 2 else { return }
        XCTAssertEqual(result.events[0].inputTokens, 400)
        XCTAssertEqual(result.events[0].outputTokens, 150)
        XCTAssertEqual(result.events[0].totalTokens, 550)
        XCTAssertEqual(result.events[1].inputTokens, 200)
        XCTAssertEqual(result.events[1].outputTokens, 100)
        XCTAssertEqual(result.events[1].totalTokens, 300)
    }

    // MARK: since-filter — events before the cutoff are excluded
    //
    // File has two events: one at 10:00 and one at 20:00.
    // Querying since=15:00 must return only the 20:00 event.
    func test_sinceFilter_excludesEventsBelowCutoff() {
        let content = """
        {"timestamp":"\(fixtureDay)T10:00:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0,"total_tokens":140}}}}
        {"timestamp":"\(fixtureDay)T20:00:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":0,"total_tokens":280}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/since_filter.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let cutoff = ts("\(fixtureDay)T15:00:00Z")
        let result = parser.parse(since: cutoff)

        XCTAssertEqual(result.events.count, 1)
        guard result.events.count == 1 else { return }
        XCTAssertEqual(result.events[0].inputTokens, 200)
    }

    // MARK: Zero-delta events are suppressed
    //
    // A token_count line where last_token_usage is all zeros must not create an event.
    func test_zeroDelta_isNotEmitted() {
        let content = """
        {"timestamp":"\(fixtureDay)T17:00:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0}}}}
        {"timestamp":"\(fixtureDay)T17:01:00.000Z","type":"event","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0,"total_tokens":140}}}}
        """
        let home = makeCodexHome(files: ["\(fixtureDir)/zero_delta.jsonl": content])
        let parser = CodexSessionParser(codexHomeForTesting: home.path)
        let result = parser.parse(since: farPast)

        XCTAssertEqual(result.events.count, 1,
            "Zero-delta token_count lines must not produce events")
        guard result.events.count == 1 else { return }
        XCTAssertEqual(result.events[0].inputTokens, 100)
    }
}
