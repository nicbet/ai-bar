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
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double
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
        let today = Self.todayPrefix()
        var summary = DailyCostSummary()
        summary.claudeModels = scanClaude(today: today)
        summary.codexModels = scanCodex(today: today)
        return summary
    }

    private static func todayPrefix() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }

    // MARK: - Claude transcript scanning

    private struct TokenTally {
        var input: Int = 0
        var output: Int = 0
        var cacheWrite: Int = 0
        var cacheRead: Int = 0
        var cacheWrite1h: Int = 0
    }

    private func scanClaude(today: String) -> [ModelCostEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        var tallies: [String: TokenTally] = [:]
        var seenIds: Set<String> = []
        let todayFmt = DateFormatter()
        todayFmt.dateFormat = "yyyy-MM-dd"
        todayFmt.timeZone = .current

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let modDate = attrs[.modificationDate] as? Date,
                      todayFmt.string(from: modDate) == today else { continue }

                scanClaudeFile(file, today: today, tallies: &tallies, seenIds: &seenIds)
            }
        }

        return tallies.map { key, tally in
            let fast = key.hasSuffix(Self.fastSuffix)
            let model = fast ? String(key.dropLast(Self.fastSuffix.count)) : key
            let p = Self.pricing(for: model, in: Self.claudePricing, fallback: Self.defaultClaude)
            return ModelCostEntry(
                model: key,
                inputTokens: tally.input + tally.cacheWrite + tally.cacheWrite1h + tally.cacheRead,
                outputTokens: tally.output,
                cost: p.cost(input: tally.input, output: tally.output,
                             cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead,
                             cacheWrite1h: tally.cacheWrite1h, fast: fast))
        }.sorted { $0.cost > $1.cost }
    }

    private static let fastSuffix = " (fast)"

    private func scanClaudeFile(_ url: URL, today: String,
                                tallies: inout [String: TokenTally],
                                seenIds: inout Set<String>) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\""), line.contains("\"message\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            guard let ts = json["timestamp"] as? String, ts.hasPrefix(today) else { continue }
            guard let msg = json["message"] as? [String: Any],
                  let msgId = msg["id"] as? String,
                  let model = msg["model"] as? String,
                  let usage = msg["usage"] as? [String: Any] else { continue }
            guard model != "<synthetic>" else { continue }
            guard !seenIds.contains(msgId) else { continue }
            seenIds.insert(msgId)

            let key = (usage["speed"] as? String) == "fast" ? model + Self.fastSuffix : model
            var t = tallies[key, default: TokenTally()]
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
            tallies[key] = t
        }
    }

    // MARK: - Codex transcript scanning

    private func scanCodex(today: String) -> [ModelCostEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parts = today.split(separator: "-")
        guard parts.count == 3 else { return [] }
        let dayDir = home.appendingPathComponent(".codex/sessions/\(parts[0])/\(parts[1])/\(parts[2])")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil) else { return [] }

        var tallies: [String: TokenTally] = [:]
        var seenIds: Set<String> = []

        for file in files where file.pathExtension == "jsonl" {
            scanCodexFile(file, today: today, tallies: &tallies, seenIds: &seenIds)
        }

        return tallies.map { model, tally in
            let p = Self.pricing(for: model, in: Self.openAIPricing, fallback: Self.defaultOpenAI)
            return ModelCostEntry(
                model: model,
                inputTokens: tally.input + tally.cacheRead,
                outputTokens: tally.output,
                cost: p.cost(input: tally.input, output: tally.output,
                             cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead))
        }.sorted { $0.cost > $1.cost }
    }

    private func scanCodexFile(_ url: URL, today: String,
                               tallies: inout [String: TokenTally],
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
            guard let ts = json["timestamp"] as? String, ts.hasPrefix(today) else { continue }
            guard let payload = json["payload"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let responseId = payload["response_id"] as? String else { continue }
            guard !seenIds.contains(responseId) else { continue }
            seenIds.insert(responseId)

            let totalInput = usage["input_tokens"] as? Int ?? 0
            let cachedRead = usage["cached_input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0

            var t = tallies[currentModel, default: TokenTally()]
            t.input += max(totalInput - cachedRead - cacheWrite, 0)
            t.output += outputTokens
            t.cacheWrite += cacheWrite
            t.cacheRead += cachedRead
            tallies[currentModel] = t
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
