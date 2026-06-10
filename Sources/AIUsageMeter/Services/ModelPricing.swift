import Foundation

/// Per-model USD rates (per 1M tokens). Used to estimate what local usage would
/// cost at API prices — subscription users see it as "API value", not a bill.
struct ModelRates {
    let input: Double
    let output: Double
    var cacheRead: Double = 0
    var cacheWrite5m: Double = 0
    var cacheWrite1h: Double = 0
}

final class ModelPricing: Sendable {
    static let shared = ModelPricing()

    /// Rate snapshot from LiteLLM's model_prices_and_context_window.json (2026-06-10).
    /// Compiled in rather than bundled as a resource: the SwiftPM resource bundle is
    /// not copied next to the standalone LaunchAgent binary, and Bundle.module would
    /// fatalError there.
    private static let snapshot: [String: ModelRates] = [
        "claude-fable-5":     ModelRates(input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite5m: 12.5, cacheWrite1h: 20.0),
        "claude-opus-4-8":    ModelRates(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10.0),
        "claude-opus-4-7":    ModelRates(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10.0),
        "claude-opus-4-6":    ModelRates(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10.0),
        "claude-opus-4-5":    ModelRates(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10.0),
        "claude-opus-4-1":    ModelRates(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite5m: 18.75, cacheWrite1h: 30.0),
        "claude-opus-4":      ModelRates(input: 15.0, output: 75.0, cacheRead: 1.5, cacheWrite5m: 18.75, cacheWrite1h: 30.0),
        "claude-sonnet-4-6":  ModelRates(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6.0),
        "claude-sonnet-4-5":  ModelRates(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6.0),
        "claude-sonnet-4":    ModelRates(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6.0),
        "claude-haiku-4-5":   ModelRates(input: 1.0, output: 5.0, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2.0),
        "claude-3-7-sonnet":  ModelRates(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6.0),
        "claude-3-5-haiku":   ModelRates(input: 0.8, output: 4.0, cacheRead: 0.08, cacheWrite5m: 1.0, cacheWrite1h: 1.6),

        "gpt-5.5-pro":        ModelRates(input: 30.0, output: 180.0, cacheRead: 3.0),
        "gpt-5.5":            ModelRates(input: 5.0, output: 30.0, cacheRead: 0.5),
        "gpt-5.4-pro":        ModelRates(input: 30.0, output: 180.0, cacheRead: 3.0),
        "gpt-5.4-mini":       ModelRates(input: 0.75, output: 4.5, cacheRead: 0.075),
        "gpt-5.4-nano":       ModelRates(input: 0.2, output: 1.25, cacheRead: 0.02),
        "gpt-5.4":            ModelRates(input: 2.5, output: 15.0, cacheRead: 0.25),
        "gpt-5.3-codex":      ModelRates(input: 1.75, output: 14.0, cacheRead: 0.175),
        "gpt-5.3":            ModelRates(input: 1.75, output: 14.0, cacheRead: 0.175),
        "gpt-5.2-pro":        ModelRates(input: 21.0, output: 168.0),
        "gpt-5.2":            ModelRates(input: 1.75, output: 14.0, cacheRead: 0.175),
        "gpt-5.1-codex-mini": ModelRates(input: 0.25, output: 2.0, cacheRead: 0.025),
        "gpt-5.1":            ModelRates(input: 1.25, output: 10.0, cacheRead: 0.125),
        "gpt-5-pro":          ModelRates(input: 15.0, output: 120.0),
        "gpt-5-mini":         ModelRates(input: 0.25, output: 2.0, cacheRead: 0.025),
        "gpt-5-nano":         ModelRates(input: 0.05, output: 0.4, cacheRead: 0.005),
        "gpt-5":              ModelRates(input: 1.25, output: 10.0, cacheRead: 0.125),
        "codex-mini-latest":  ModelRates(input: 1.5, output: 6.0, cacheRead: 0.375),

        "gemini-3.5-flash":   ModelRates(input: 1.5, output: 9.0, cacheRead: 0.15),
        "gemini-3.1-pro":     ModelRates(input: 2.0, output: 12.0, cacheRead: 0.2),
        "gemini-3.1-flash":   ModelRates(input: 0.5, output: 3.0, cacheRead: 0.05),
        "gemini-3-pro":       ModelRates(input: 2.0, output: 12.0, cacheRead: 0.2),
        "gemini-3-flash":     ModelRates(input: 0.5, output: 3.0, cacheRead: 0.05),
        "gemini-2.5-pro":     ModelRates(input: 1.25, output: 10.0, cacheRead: 0.125),
        "gemini-2.5-flash":   ModelRates(input: 0.3, output: 2.5, cacheRead: 0.03),
    ]

    private let models: [String: ModelRates]
    /// Keys sorted longest-first so prefix matching picks the most specific entry
    /// (e.g. "gpt-5.1-codex-mini" before "gpt-5.1" before "gpt-5").
    private let prefixKeys: [String]

    private init() {
        models = Self.snapshot
        prefixKeys = models.keys.sorted { $0.count > $1.count }
    }

    func rates(for model: String?) -> ModelRates? {
        guard var name = model?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        // Strip provider prefix ("anthropic/claude-..." → "claude-...")
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }

        if let exact = models[name] { return exact }

        // Strip date suffixes: "-20260205" (Anthropic) or "-2026-04-23" (OpenAI)
        let dateless = name.replacingOccurrences(
            of: #"-20\d{2}(-?\d{2}){2}$"#, with: "", options: .regularExpression
        )
        if dateless != name, let match = models[dateless] { return match }

        return prefixKeys.first { name.hasPrefix($0) }.flatMap { models[$0] }
    }

    /// Anthropic usage reports uncached input, cache writes, and cache reads separately.
    func claudeCost(
        model: String?,
        input: Int64, output: Int64,
        cacheWrite5m: Int64, cacheWrite1h: Int64, cacheRead: Int64
    ) -> Double {
        guard let r = rates(for: model) else { return 0 }
        let write1hRate = r.cacheWrite1h > 0 ? r.cacheWrite1h : r.cacheWrite5m
        let cost = Double(input) * r.input
            + Double(output) * r.output
            + Double(cacheWrite5m) * r.cacheWrite5m
            + Double(cacheWrite1h) * write1hRate
            + Double(cacheRead) * r.cacheRead
        return cost / 1_000_000
    }

    /// OpenAI usage reports input *including* the cached portion; cached tokens
    /// bill at the cache-read rate instead of the input rate.
    func codexCost(model: String?, input: Int64, cachedInput: Int64, output: Int64) -> Double {
        guard let r = rates(for: model) else { return 0 }
        let cached = min(max(cachedInput, 0), max(input, 0))
        let cost = Double(input - cached) * r.input
            + Double(cached) * r.cacheRead
            + Double(output) * r.output
        return cost / 1_000_000
    }
}
