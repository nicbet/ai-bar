import Foundation

struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheWritePerMTok: Double
    let cacheReadPerMTok: Double
    /// 1-hour TTL cache writes (Anthropic); equals the 5-minute rate where there is no distinction
    let cacheWrite1hPerMTok: Double
    /// Multiplier applied to every token category for fast-mode requests
    let fastMultiplier: Double

    init(inputPerMTok: Double, outputPerMTok: Double,
         cacheWritePerMTok: Double, cacheReadPerMTok: Double,
         cacheWrite1hPerMTok: Double? = nil, fastMultiplier: Double = 1) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok ?? cacheWritePerMTok
        self.fastMultiplier = fastMultiplier
    }

    /// Anthropic pricing: cache writes are 1.25x (5m) / 2x (1h) input; cache reads vary by model
    static func anthropic(input: Double, output: Double, cacheRead: Double,
                          fastMultiplier: Double = 1) -> ModelPricing {
        ModelPricing(inputPerMTok: input, outputPerMTok: output,
                     cacheWritePerMTok: input * 1.25, cacheReadPerMTok: cacheRead,
                     cacheWrite1hPerMTok: input * 2, fastMultiplier: fastMultiplier)
    }

    /// OpenAI pricing: cache writes bill at the input rate unless a separate price is published
    static func openAI(input: Double, cachedInput: Double?, output: Double,
                       cacheWrite: Double? = nil) -> ModelPricing {
        ModelPricing(inputPerMTok: input, outputPerMTok: output,
                     cacheWritePerMTok: cacheWrite ?? input, cacheReadPerMTok: cachedInput ?? input)
    }

    func cost(input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
              cacheWrite1h: Int = 0, fast: Bool = false) -> Double {
        let base = (Double(input) * inputPerMTok +
                    Double(output) * outputPerMTok +
                    Double(cacheWrite) * cacheWritePerMTok +
                    Double(cacheWrite1h) * cacheWrite1hPerMTok +
                    Double(cacheRead) * cacheReadPerMTok) / 1_000_000
        return fast ? base * fastMultiplier : base
    }
}

struct ModelCostEntry: Identifiable {
    let id = UUID()
    let model: String
    /// Uncached input tokens
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let cost: Double

    var totalInputTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }
    var totalTokens: Int { totalInputTokens + outputTokens }
}

struct DailyCostSummary {
    var claudeModels: [ModelCostEntry] = []
    var codexModels: [ModelCostEntry] = []

    var claudeCost: Double { claudeModels.reduce(0) { $0 + $1.cost } }
    var codexCost: Double { codexModels.reduce(0) { $0 + $1.cost } }
    var totalCost: Double { claudeCost + codexCost }

    static let empty = DailyCostSummary()
}

final class CostEstimator: @unchecked Sendable {
    static let shared = CostEstimator()

    // Anthropic published API prices (per 1M tokens), longest prefix wins.
    // Source: platform.claude.com/docs/en/about-claude/pricing (checked 2026-09-24)
    private static let claudePricing: [(prefix: String, pricing: ModelPricing)] = [
        ("claude-fable-5-1", .anthropic(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .anthropic(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", .anthropic(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", .anthropic(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", .anthropic(input: 4, output: 20, cacheRead: 0.20, fastMultiplier: 2)),
        ("claude-opus-5", .anthropic(input: 5, output: 25, cacheRead: 0.50, fastMultiplier: 2)),
        ("claude-opus-4-8", .anthropic(input: 5, output: 25, cacheRead: 0.50, fastMultiplier: 2)),
        ("claude-opus-4-7", .anthropic(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", .anthropic(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-5", .anthropic(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-1", .anthropic(input: 15, output: 75, cacheRead: 1.50)),
        ("claude-opus-4", .anthropic(input: 15, output: 75, cacheRead: 1.50)),
        ("claude-sonnet-5", .anthropic(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", .anthropic(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-sonnet-4-5", .anthropic(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-sonnet-4", .anthropic(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-3-7-sonnet", .anthropic(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-4-5", .anthropic(input: 1, output: 5, cacheRead: 0.10)),
        ("claude-3-5-haiku", .anthropic(input: 0.80, output: 4, cacheRead: 0.08)),
        // Family catch-alls for versions newer than this table: latest known price in the family
        ("claude-fable", .anthropic(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos", .anthropic(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-opus", .anthropic(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-sonnet", .anthropic(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-haiku", .anthropic(input: 1, output: 5, cacheRead: 0.10)),
    ]

    // OpenAI published API prices (per 1M tokens, standard tier, short context), longest prefix wins.
    // Source: developers.openai.com/api/docs/pricing (checked 2026-09-24)
    private static let openAIPricing: [(prefix: String, pricing: ModelPricing)] = [
        ("gpt-6-astra", .openAI(input: 10, cachedInput: 1, output: 50, cacheWrite: 12.50)),
        ("gpt-6-sol", .openAI(input: 2, cachedInput: 0.20, output: 10, cacheWrite: 2.50)),
        ("gpt-6-luna", .openAI(input: 0.10, cachedInput: 0.01, output: 0.50, cacheWrite: 0.125)),
        ("gpt-5.6-sol", .openAI(input: 4, cachedInput: 0.40, output: 20, cacheWrite: 5)),
        ("gpt-5.6-terra", .openAI(input: 2, cachedInput: 0.20, output: 12, cacheWrite: 2.50)),
        ("gpt-5.6-luna", .openAI(input: 0.20, cachedInput: 0.02, output: 1.20, cacheWrite: 0.25)),
        ("gpt-5.5-pro", .openAI(input: 30, cachedInput: nil, output: 180)),
        ("gpt-5.5", .openAI(input: 5, cachedInput: 0.50, output: 30)),
        ("gpt-5.4-pro", .openAI(input: 30, cachedInput: nil, output: 180)),
        ("gpt-5.4-mini", .openAI(input: 0.75, cachedInput: 0.075, output: 4.50)),
        ("gpt-5.4-nano", .openAI(input: 0.20, cachedInput: 0.02, output: 1.25)),
        ("gpt-5.4", .openAI(input: 2.50, cachedInput: 0.25, output: 15)),
        ("gpt-5.3-codex", .openAI(input: 1.75, cachedInput: 0.175, output: 14)),
        ("gpt-5.2-pro", .openAI(input: 21, cachedInput: nil, output: 168)),
        ("gpt-5.2", .openAI(input: 1.75, cachedInput: 0.175, output: 14)),
        ("gpt-5.1", .openAI(input: 1.25, cachedInput: 0.125, output: 10)),
        ("gpt-5-pro", .openAI(input: 15, cachedInput: nil, output: 120)),
        ("gpt-5-mini", .openAI(input: 0.25, cachedInput: 0.025, output: 2)),
        ("gpt-5-nano", .openAI(input: 0.05, cachedInput: 0.005, output: 0.40)),
        ("gpt-5", .openAI(input: 1.25, cachedInput: 0.125, output: 10)),
        ("gpt-4.1-mini", .openAI(input: 0.40, cachedInput: 0.10, output: 1.60)),
        ("gpt-4.1-nano", .openAI(input: 0.10, cachedInput: 0.025, output: 0.40)),
        ("gpt-4.1", .openAI(input: 2, cachedInput: 0.50, output: 8)),
        ("gpt-4o-mini", .openAI(input: 0.15, cachedInput: 0.075, output: 0.60)),
        ("gpt-4o-2024-05-13", .openAI(input: 5, cachedInput: nil, output: 15)),
        ("gpt-4o", .openAI(input: 2.50, cachedInput: 1.25, output: 10)),
        ("o1-pro", .openAI(input: 150, cachedInput: nil, output: 600)),
        ("o1", .openAI(input: 15, cachedInput: 7.50, output: 60)),
        ("o3-pro", .openAI(input: 20, cachedInput: nil, output: 80)),
        ("o3-mini", .openAI(input: 1.10, cachedInput: 0.55, output: 4.40)),
        ("o3", .openAI(input: 2, cachedInput: 0.50, output: 8)),
        ("o4-mini", .openAI(input: 1.10, cachedInput: 0.275, output: 4.40)),
    ]

    private static let defaultOpenAI = ModelPricing.openAI(input: 2, cachedInput: 0.20, output: 10)
    private static let defaultClaude = ModelPricing.anthropic(input: 2, output: 10, cacheRead: 0.20)

    private static func pricing(for model: String,
                                in table: [(prefix: String, pricing: ModelPricing)],
                                fallback: ModelPricing) -> ModelPricing {
        let id = normalizedModelId(model)
        return table
            .filter { id.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .pricing ?? fallback
    }

    /// Strips provider prefixes/suffixes so e.g. "us.anthropic.claude-opus-4-5@20251101"
    /// or "claude-opus-5-5[1m]" match their first-party IDs.
    private static func normalizedModelId(_ model: String) -> String {
        var id = model.lowercased()
        if let r = id.range(of: "claude-") { id = String(id[r.lowerBound...]) }
        if let r = id.firstIndex(of: "[") { id = String(id[..<r]) }
        return id.replacingOccurrences(of: "@", with: "-")
    }

    // MARK: - Public

    func scanToday() -> DailyCostSummary {
        let today = Calendar.current.startOfDay(for: Date())
        return scan(since: today)[Self.dayKey(today)] ?? .empty
    }

    /// Scans transcripts and returns per-day summaries keyed by local "yyyy-MM-dd",
    /// covering every day from `start` (inclusive) to now that has usage.
    func scan(since start: Date) -> [String: DailyCostSummary] {
        let claude = scanClaude(since: start)
        let codex = scanCodex(since: start)
        var result: [String: DailyCostSummary] = [:]
        for day in Set(claude.keys).union(codex.keys) {
            var summary = DailyCostSummary()
            summary.claudeModels = Self.entries(claude[day] ?? [:], table: Self.claudePricing,
                                                fallback: Self.defaultClaude)
            summary.codexModels = Self.entries(codex[day] ?? [:], table: Self.openAIPricing,
                                               fallback: Self.defaultOpenAI)
            result[day] = summary
        }
        return result
    }

    static func dayKey(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    static func date(fromDayKey key: String) -> Date? {
        dayFormatter().date(from: key)
    }

    private static func dayFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt
    }

    private static func parseTimestamp(_ ts: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: ts) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: ts)
    }

    // MARK: - Tallies

    private struct TokenTally {
        var input: Int = 0
        var output: Int = 0
        var cacheWrite: Int = 0
        var cacheRead: Int = 0
        var cacheWrite1h: Int = 0
    }

    /// day -> model key -> tally
    private typealias DayTallies = [String: [String: TokenTally]]

    private static let fastSuffix = " (fast)"

    private static func entries(_ tallies: [String: TokenTally],
                                table: [(prefix: String, pricing: ModelPricing)],
                                fallback: ModelPricing) -> [ModelCostEntry] {
        tallies.map { key, tally in
            let fast = key.hasSuffix(fastSuffix)
            let model = fast ? String(key.dropLast(fastSuffix.count)) : key
            let p = pricing(for: model, in: table, fallback: fallback)
            return ModelCostEntry(
                model: key,
                inputTokens: tally.input,
                outputTokens: tally.output,
                cacheWriteTokens: tally.cacheWrite + tally.cacheWrite1h,
                cacheReadTokens: tally.cacheRead,
                cost: p.cost(input: tally.input, output: tally.output,
                             cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead,
                             cacheWrite1h: tally.cacheWrite1h, fast: fast))
        }.sorted { $0.cost > $1.cost }
    }

    // MARK: - Claude transcript scanning

    private func scanClaude(since start: Date) -> DayTallies {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        // Recursive: subagent transcripts live in <project>/<session>/subagents/*.jsonl
        guard let files = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }

        var tallies: DayTallies = [:]
        var seenIds: Set<String> = []

        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  modDate >= start else { continue }
            scanClaudeFile(file, since: start, tallies: &tallies, seenIds: &seenIds)
        }
        return tallies
    }

    private func scanClaudeFile(_ url: URL, since start: Date,
                                tallies: inout DayTallies,
                                seenIds: inout Set<String>) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\""), line.contains("\"message\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            guard let ts = json["timestamp"] as? String,
                  let date = Self.parseTimestamp(ts), date >= start else { continue }
            guard let msg = json["message"] as? [String: Any],
                  let msgId = msg["id"] as? String,
                  let model = msg["model"] as? String,
                  let usage = msg["usage"] as? [String: Any] else { continue }
            guard model != "<synthetic>" else { continue }
            guard !seenIds.contains(msgId) else { continue }
            seenIds.insert(msgId)

            let day = Self.dayKey(date)
            let key = (usage["speed"] as? String) == "fast" ? model + Self.fastSuffix : model
            var t = tallies[day, default: [:]][key, default: TokenTally()]
            t.input += usage["input_tokens"] as? Int ?? 0
            t.output += usage["output_tokens"] as? Int ?? 0
            t.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWriteTotal = usage["cache_creation_input_tokens"] as? Int ?? 0
            if let breakdown = usage["cache_creation"] as? [String: Any] {
                let oneHour = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
                t.cacheWrite1h += oneHour
                t.cacheWrite += max(cacheWriteTotal - oneHour, 0)
            } else {
                t.cacheWrite += cacheWriteTotal
            }
            tallies[day, default: [:]][key] = t
        }
    }

    // MARK: - Codex transcript scanning

    private func scanCodex(since start: Date) -> DayTallies {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy/MM/dd"

        var tallies: DayTallies = [:]
        var seenIds: Set<String> = []

        // Sessions are filed by start date; begin a day early to catch sessions that ran past midnight
        guard var day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: start)) else { return [:] }
        while day <= Date() {
            let dayDir = sessionsDir.appendingPathComponent(fmt.string(from: day))
            if let files = try? FileManager.default.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "jsonl" {
                    scanCodexFile(file, since: start, tallies: &tallies, seenIds: &seenIds)
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return tallies
    }

    private func scanCodexFile(_ url: URL, since start: Date,
                               tallies: inout DayTallies,
                               seenIds: inout Set<String>) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        var currentModel = "unknown"

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            if type == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
                continue
            }

            guard type == "token_usage_record" else { continue }
            guard let ts = json["timestamp"] as? String,
                  let date = Self.parseTimestamp(ts), date >= start else { continue }
            guard let payload = json["payload"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let responseId = payload["response_id"] as? String else { continue }
            guard !seenIds.contains(responseId) else { continue }
            seenIds.insert(responseId)

            let totalInput = usage["input_tokens"] as? Int ?? 0
            let cachedRead = usage["cached_input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0

            let day = Self.dayKey(date)
            var t = tallies[day, default: [:]][currentModel, default: TokenTally()]
            t.input += max(totalInput - cachedRead - cacheWrite, 0)
            t.output += outputTokens
            t.cacheWrite += cacheWrite
            t.cacheRead += cachedRead
            tallies[day, default: [:]][currentModel] = t
        }
    }
}

// MARK: - Formatting helpers

func formatCost(_ cost: Double) -> String {
    if cost < 0.005 { return "$0.00" }
    return String(format: "$%.2f", cost)
}

func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}
