import XCTest
@testable import AIUsageMeterCore

// MARK: - Helpers (shared with CodexSessionParserTests via same module)

/// Builds a fake ~/.claude/projects directory and writes JSONL files under a
/// project subdirectory. Returns the root directory (equivalent to ~/.claude/projects).
func makeClaudeProjectsDir(files: [String: String]) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let projectDir = root.appendingPathComponent("test-project")
    try! FileManager.default.createDirectory(at: projectDir,
                                              withIntermediateDirectories: true)
    for (name, content) in files {
        let dest = projectDir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try! content.write(to: dest, atomically: true, encoding: .utf8)
    }
    return root
}

// MARK: - ClaudeCodeTokenParserTests

final class ClaudeCodeTokenParserTests: XCTestCase {

    // MARK: Fixture (f): duplicate message (same messageId + requestId)
    //
    // The JSONL contains msg_001/req_001 twice and msg_002/req_002 once.
    // Dedup must count the duplicate only once.
    //
    // Expected:
    //   2 unique messages
    //   total input  = 100 + 200 = 300
    //   total output =  50 +  80 = 130
    func test_duplicateMessage_countedOnlyOnce() {
        // Fixture f — two identical lines for msg_001, then one for msg_002.
        let content = """
        {"type":"assistant","message":{"id":"msg_001","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"requestId":"req_001","timestamp":"2026-07-01T10:00:00.000Z"}
        {"type":"assistant","message":{"id":"msg_001","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"requestId":"req_001","timestamp":"2026-07-01T10:00:00.000Z"}
        {"type":"assistant","message":{"id":"msg_002","model":"claude-sonnet-4-6","usage":{"input_tokens":200,"output_tokens":80}},"requestId":"req_002","timestamp":"2026-07-01T10:05:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["f_dup.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        // Sum over all daily buckets
        let totalInput  = summary.daily.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = summary.daily.reduce(0) { $0 + $1.outputTokens }
        let totalMsgs   = summary.daily.reduce(0) { $0 + $1.messageCount }

        // 300 input, 130 output, 2 unique messages
        XCTAssertEqual(totalInput,  300, "Duplicate message must not double-count input tokens")
        XCTAssertEqual(totalOutput, 130, "Duplicate message must not double-count output tokens")
        XCTAssertEqual(totalMsgs,   2,   "Duplicate message must count as 1 unique message")
    }

    // Claude Code stores subagent/workflow transcripts below the session
    // directory. They must be included in the same aggregate as top-level
    // project transcripts.
    func test_nestedTranscript_isIncluded() {
        let content = """
        {"type":"assistant","message":{"id":"nested_msg","model":"claude-sonnet-4-6","usage":{"input_tokens":120,"output_tokens":30}},"requestId":"nested_req","timestamp":"2026-07-01T10:00:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["session/subagents/agent-1.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        XCTAssertEqual(summary.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(summary.daily.reduce(0) { $0 + $1.messageCount }, 1)
    }

    // MARK: Same messageId but different requestId → two separate messages
    //
    // Retried requests carry the same messageId but a new requestId.
    // Both must be counted independently.
    //
    // Expected: 2 messages, total input = 300, total output = 130
    func test_sameMessageIdDifferentRequestId_countedSeparately() {
        let content = """
        {"type":"assistant","message":{"id":"msg_003","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"requestId":"req_A","timestamp":"2026-07-01T11:00:00.000Z"}
        {"type":"assistant","message":{"id":"msg_003","model":"claude-sonnet-4-6","usage":{"input_tokens":200,"output_tokens":80}},"requestId":"req_B","timestamp":"2026-07-01T11:01:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["retry.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        let totalInput  = summary.daily.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = summary.daily.reduce(0) { $0 + $1.outputTokens }
        let totalMsgs   = summary.daily.reduce(0) { $0 + $1.messageCount }

        XCTAssertEqual(totalInput,  300)
        XCTAssertEqual(totalOutput, 130)
        XCTAssertEqual(totalMsgs,   2)
    }

    // MARK: Fixture (g): cache tokens — cost calculation includes cache traffic
    //
    // msg_010 (claude-opus-4-5): input=1000, output=200, cacheWrite5m=500, cacheRead=0
    //   cost = (1000 * 5.0 + 200 * 25.0 + 500 * 6.25 + 0) / 1_000_000
    //        = (5000 + 5000 + 3125) / 1_000_000 = 13125 / 1_000_000 = 0.013125
    //
    // msg_011 (claude-opus-4-5): input=800, output=150, cacheWrite5m=0, cacheRead=600
    //   cost = (800 * 5.0 + 150 * 25.0 + 0 + 600 * 0.5) / 1_000_000
    //        = (4000 + 3750 + 300) / 1_000_000 = 8050 / 1_000_000 = 0.00805
    //
    // msg_012 (claude-opus-4-5): input=300, output=100, no cache
    //   cost = (300 * 5.0 + 100 * 25.0) / 1_000_000 = 4000 / 1_000_000 = 0.004
    //
    // total cost ≈ 0.013125 + 0.00805 + 0.004 = 0.025175
    //
    // Note: Token counts for "total" in the summary are input+output only (no cache),
    // matching Claude Code /stats behaviour.
    func test_cacheTokens_costIncludesCacheTraffic() {
        let content = """
        {"type":"assistant","message":{"id":"msg_010","model":"claude-opus-4-5","usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":500,"cache_read_input_tokens":0}},"requestId":"req_010","timestamp":"2026-07-01T14:00:00.000Z"}
        {"type":"assistant","message":{"id":"msg_011","model":"claude-opus-4-5","usage":{"input_tokens":800,"output_tokens":150,"cache_creation_input_tokens":0,"cache_read_input_tokens":600}},"requestId":"req_011","timestamp":"2026-07-01T14:05:00.000Z"}
        {"type":"assistant","message":{"id":"msg_012","model":"claude-opus-4-5","usage":{"input_tokens":300,"output_tokens":100}},"requestId":"req_012","timestamp":"2026-07-01T14:10:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["g_cache.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        let totalInput  = summary.daily.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = summary.daily.reduce(0) { $0 + $1.outputTokens }
        let totalCost   = summary.daily.reduce(0.0) { $0 + $1.costUSD }

        // Token counts: input+output only (cache tokens excluded from count)
        XCTAssertEqual(totalInput,  1000 + 800 + 300)  // = 2100
        XCTAssertEqual(totalOutput, 200 + 150 + 100)   // = 450

        // Cost must be > zero and close to the hand-computed 0.025175
        XCTAssertGreaterThan(totalCost, 0.0)
        XCTAssertEqual(totalCost, 0.025175, accuracy: 1e-8)
    }

    // MARK: No-cache messages produce zero cost when model is unknown
    //
    // When the model string is nil or unknown, ModelPricing returns nil rates → cost = 0.
    func test_unknownModel_producesZeroCost() {
        let content = """
        {"type":"assistant","message":{"id":"msg_unk","model":"model-does-not-exist","usage":{"input_tokens":500,"output_tokens":200}},"requestId":"req_unk","timestamp":"2026-07-01T15:00:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["unk_model.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        let totalCost = summary.daily.reduce(0.0) { $0 + $1.costUSD }
        XCTAssertEqual(totalCost, 0.0,
            "Unknown model must produce zero cost, not a crash")

        // Tokens are still counted
        let totalInput = summary.daily.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(totalInput, 500)
    }

    // MARK: Messages without a message id pass through dedup without a key
    //
    // When "id" is absent from the message object, the dedup guard is skipped
    // and the message is always counted.
    func test_missingMessageId_alwaysCountedRegardlessOfRequestId() {
        let content = """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":50,"output_tokens":20}},"requestId":"req_noid_1","timestamp":"2026-07-01T16:00:00.000Z"}
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":60,"output_tokens":25}},"requestId":"req_noid_2","timestamp":"2026-07-01T16:01:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["no_id.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        let totalMsgs = summary.daily.reduce(0) { $0 + $1.messageCount }
        XCTAssertEqual(totalMsgs, 2,
            "Messages without an id field must still be counted")
    }

    // MARK: Non-assistant type lines are ignored
    //
    // Lines with type != "assistant" (e.g. "user", "summary") must not affect counts.
    func test_nonAssistantLines_areIgnored() {
        let content = """
        {"type":"user","message":{"usage":{"input_tokens":999,"output_tokens":999}},"timestamp":"2026-07-01T17:00:00.000Z"}
        {"type":"summary","message":{"usage":{"input_tokens":999,"output_tokens":999}},"timestamp":"2026-07-01T17:01:00.000Z"}
        {"type":"assistant","message":{"id":"msg_real","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}},"requestId":"req_real","timestamp":"2026-07-01T17:02:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["non_assistant.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        let totalInput = summary.daily.reduce(0) { $0 + $1.inputTokens }
        let totalMsgs  = summary.daily.reduce(0) { $0 + $1.messageCount }
        XCTAssertEqual(totalInput, 100,
            "Non-assistant type lines must not be counted")
        XCTAssertEqual(totalMsgs, 1)
    }

    // MARK: Hourly bucketing — messages in different hours land in separate hourly buckets
    //
    // Two messages at 10:30 and 14:15 must produce two distinct hourly entries.
    func test_hourlyBucketing_separateHoursProduceSeparateBuckets() {
        let content = """
        {"type":"assistant","message":{"id":"msg_h1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":40}},"requestId":"req_h1","timestamp":"2026-07-01T10:30:00.000Z"}
        {"type":"assistant","message":{"id":"msg_h2","model":"claude-sonnet-4-6","usage":{"input_tokens":200,"output_tokens":80}},"requestId":"req_h2","timestamp":"2026-07-01T14:15:00.000Z"}
        """
        let root = makeClaudeProjectsDir(files: ["hourly.jsonl": content])
        let parser = ClaudeCodeTokenParser(baseDirForTesting: root)
        let summary = parser.parse(days: 1000)

        XCTAssertEqual(summary.hourly.count, 2,
            "Messages at different hours must land in separate hourly buckets")
        let tokens = summary.hourly.map(\.totalTokens).sorted()
        XCTAssertEqual(tokens[0], 140)  // 100+40
        XCTAssertEqual(tokens[1], 280)  // 200+80
    }
}
