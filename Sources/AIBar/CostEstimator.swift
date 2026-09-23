import Foundation

struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheWritePerMTok: Double
    let cacheReadPerMTok: Double

    func cost(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        (Double(input) * inputPerMTok +
         Double(output) * outputPerMTok +
         Double(cacheWrite) * cacheWritePerMTok +
         Double(cacheRead) * cacheReadPerMTok) / 1_000_000
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

    // Anthropic published API prices (per 1M tokens), prefix-matched
    private static let claudePricing: [(prefix: String, pricing: ModelPricing)] = [
        ("claude-opus", ModelPricing(inputPerMTok: 15, outputPerMTok: 75,
                                     cacheWritePerMTok: 18.75, cacheReadPerMTok: 1.50)),
        ("claude-sonnet", ModelPricing(inputPerMTok: 3, outputPerMTok: 15,
                                       cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30)),
        ("claude-haiku", ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4,
                                      cacheWritePerMTok: 1.00, cacheReadPerMTok: 0.08)),
        ("claude-fable", ModelPricing(inputPerMTok: 6, outputPerMTok: 30,
                                      cacheWritePerMTok: 7.50, cacheReadPerMTok: 0.60)),
    ]

    // OpenAI published API prices (per 1M tokens), prefix-matched
    private static let openAIPricing: [(prefix: String, pricing: ModelPricing)] = [
        ("o1", ModelPricing(inputPerMTok: 15, outputPerMTok: 60,
                            cacheWritePerMTok: 15, cacheReadPerMTok: 7.50)),
        ("o3", ModelPricing(inputPerMTok: 10, outputPerMTok: 40,
                            cacheWritePerMTok: 10, cacheReadPerMTok: 2.50)),
        ("gpt-4o-mini", ModelPricing(inputPerMTok: 0.15, outputPerMTok: 0.60,
                                     cacheWritePerMTok: 0.15, cacheReadPerMTok: 0.075)),
        ("gpt-4o", ModelPricing(inputPerMTok: 2.50, outputPerMTok: 10,
                                cacheWritePerMTok: 2.50, cacheReadPerMTok: 1.25)),
        ("gpt-5", ModelPricing(inputPerMTok: 10, outputPerMTok: 40,
                               cacheWritePerMTok: 10, cacheReadPerMTok: 2.50)),
        ("gpt-4", ModelPricing(inputPerMTok: 10, outputPerMTok: 30,
                               cacheWritePerMTok: 10, cacheReadPerMTok: 5)),
    ]

    private static let defaultOpenAI = ModelPricing(
        inputPerMTok: 10, outputPerMTok: 40, cacheWritePerMTok: 10, cacheReadPerMTok: 2.50)
    private static let defaultClaude = ModelPricing(
        inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30)

    private static func pricing(for model: String,
                                in table: [(prefix: String, pricing: ModelPricing)],
                                fallback: ModelPricing) -> ModelPricing {
        for entry in table where model.hasPrefix(entry.prefix) { return entry.pricing }
        return fallback
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

        return tallies.map { model, tally in
            let p = Self.pricing(for: model, in: Self.claudePricing, fallback: Self.defaultClaude)
            return ModelCostEntry(
                model: model,
                inputTokens: tally.input + tally.cacheWrite + tally.cacheRead,
                outputTokens: tally.output,
                cost: p.cost(input: tally.input, output: tally.output,
                             cacheWrite: tally.cacheWrite, cacheRead: tally.cacheRead))
        }.sorted { $0.cost > $1.cost }
    }

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
            guard !seenIds.contains(msgId) else { continue }
            seenIds.insert(msgId)

            var t = tallies[model, default: TokenTally()]
            t.input += usage["input_tokens"] as? Int ?? 0
            t.output += usage["output_tokens"] as? Int ?? 0
            t.cacheWrite += usage["cache_creation_input_tokens"] as? Int ?? 0
            t.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            tallies[model] = t
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
