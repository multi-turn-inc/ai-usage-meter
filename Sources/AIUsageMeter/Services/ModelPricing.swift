import Foundation

/// Per-model USD rates (per 1M tokens), loaded from the bundled ModelPricing.json
/// snapshot (sourced from LiteLLM). Used to estimate what local usage would cost
/// at API prices — subscription users see it as "API value", not a bill.
struct ModelRates: Decodable {
    let input: Double
    let output: Double
    var cacheRead: Double = 0
    var cacheWrite5m: Double = 0
    var cacheWrite1h: Double = 0

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite5m, cacheWrite1h
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Double.self, forKey: .input)
        output = try c.decode(Double.self, forKey: .output)
        cacheRead = try c.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0
        cacheWrite5m = try c.decodeIfPresent(Double.self, forKey: .cacheWrite5m) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Double.self, forKey: .cacheWrite1h) ?? 0
    }
}

final class ModelPricing: Sendable {
    static let shared = ModelPricing()

    private let models: [String: ModelRates]
    /// Keys sorted longest-first so prefix matching picks the most specific entry
    /// (e.g. "gpt-5.1-codex-mini" before "gpt-5.1" before "gpt-5").
    private let prefixKeys: [String]

    private struct PricingFile: Decodable {
        let models: [String: ModelRates]
    }

    private init() {
        var loaded: [String: ModelRates] = [:]
        if let url = Bundle.module.url(forResource: "ModelPricing", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(PricingFile.self, from: data) {
            loaded = Dictionary(uniqueKeysWithValues: file.models.map { ($0.key.lowercased(), $0.value) })
        }
        models = loaded
        prefixKeys = loaded.keys.sorted { $0.count > $1.count }
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
