import Foundation
import SwiftUI

enum PaceLevel {
    case underPace, onPace, slightlyAhead, burningFast, unknown

    var color: Color {
        switch self {
        case .underPace:     return .green
        case .onPace:        return .cyan
        case .slightlyAhead: return .yellow
        case .burningFast:   return .red
        case .unknown:       return .clear
        }
    }
}

struct ServiceUsage: Codable {
    var utilization: Double?
    var resetsAt: Date?
    var windowDuration: TimeInterval?

    var weeklyUtilization: Double?
    var weeklyResetsAt: Date?

    var lastError: String?
    var lastUpdated: Date?

    var percentage: Double {
        if let u = utilization { return min(max(u, 0), 1.0) }
        return 0
    }

    var percentInt: Int { Int(percentage * 100) }
    var hasAPIData: Bool { utilization != nil }

    var formattedUsage: String {
        if let reset = resetsAt {
            let remaining = reset.timeIntervalSinceNow
            if remaining > 0 { return "resets in \(Self.formatDuration(remaining))" }
            return "resetting..."
        }
        return hasAPIData ? "reset inactive" : "not connected"
    }

    var weeklyPercentage: Double {
        if let u = weeklyUtilization { return min(max(u, 0), 1.0) }
        return 0
    }

    var weeklyPercentInt: Int { Int(weeklyPercentage * 100) }

    var formattedWeeklyReset: String {
        guard let reset = weeklyResetsAt else { return "" }
        let remaining = reset.timeIntervalSinceNow
        if remaining > 0 { return Self.formatDuration(remaining) }
        return ""
    }

    var formattedReset: String {
        if let reset = resetsAt {
            let remaining = reset.timeIntervalSinceNow
            if remaining > 0 { return Self.formatDuration(remaining) }
            return "resetting..."
        }
        return ""
    }

    var elapsedFraction: Double? {
        guard let resetsAt, let duration = windowDuration, duration > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(resetsAt.addingTimeInterval(-duration))
        return min(max(elapsed / duration, 0), 1.0)
    }

    var paceDelta: Double? {
        guard let elapsed = elapsedFraction else { return nil }
        return percentage - elapsed
    }

    var paceLevel: PaceLevel {
        guard let delta = paceDelta else { return .unknown }
        if delta < -0.05 { return .underPace }
        if delta < 0.05  { return .onPace }
        if delta < 0.20  { return .slightlyAhead }
        return .burningFast
    }

    mutating func applyAPI(_ result: UsageAPIResult) {
        utilization = result.utilization
        resetsAt = result.resetsAt
        windowDuration = result.windowDuration
        weeklyUtilization = result.weeklyUtilization
        weeklyResetsAt = result.weeklyResetsAt
        lastError = nil
        lastUpdated = Date()
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static let empty = ServiceUsage()
}

struct AppState: Codable {
    var claude: ServiceUsage
    var codex: ServiceUsage
    var pollInterval: TimeInterval
    var claudeEnabled: Bool
    var codexEnabled: Bool
    var showEstimatedCost: Bool

    static let defaults = AppState(
        claude: .empty, codex: .empty, pollInterval: 300,
        claudeEnabled: true, codexEnabled: true, showEstimatedCost: false
    )

    init(claude: ServiceUsage, codex: ServiceUsage, pollInterval: TimeInterval,
         claudeEnabled: Bool, codexEnabled: Bool, showEstimatedCost: Bool) {
        self.claude = claude; self.codex = codex; self.pollInterval = pollInterval
        self.claudeEnabled = claudeEnabled; self.codexEnabled = codexEnabled
        self.showEstimatedCost = showEstimatedCost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decode(ServiceUsage.self, forKey: .claude)) ?? .empty
        codex = (try? c.decode(ServiceUsage.self, forKey: .codex)) ?? .empty
        pollInterval = (try? c.decode(TimeInterval.self, forKey: .pollInterval)) ?? 300
        claudeEnabled = (try? c.decode(Bool.self, forKey: .claudeEnabled)) ?? true
        codexEnabled = (try? c.decode(Bool.self, forKey: .codexEnabled)) ?? true
        showEstimatedCost = (try? c.decode(Bool.self, forKey: .showEstimatedCost)) ?? false
    }
}

@MainActor
final class UsageManager: ObservableObject {
    @Published var claude: ServiceUsage
    @Published var codex: ServiceUsage
    @Published var pollInterval: TimeInterval
    @Published var claudeEnabled: Bool
    @Published var codexEnabled: Bool
    @Published var claudeAvailable: Bool = false
    @Published var codexAvailable: Bool = false
    @Published var showEstimatedCost: Bool
    @Published var dailyCost: DailyCostSummary = .empty
    /// Bumped whenever stored daily cost history changes, so history views can reload
    @Published var costHistoryRevision = 0

    private var timer: Timer?
    private var pollTask: Task<Void, Never>?
    private let stateURL: URL
    private let api = APIClient.shared
    private var claudeBackoff: TimeInterval = 0
    private var codexBackoff: TimeInterval = 0
    private var claudeNextPoll: Date = .distantPast
    private var codexNextPoll: Date = .distantPast

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ai-bar")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)
        stateURL = configDir.appendingPathComponent("state.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(AppState.self, from: data) {
            claude = state.claude; codex = state.codex; pollInterval = state.pollInterval
            claudeEnabled = state.claudeEnabled; codexEnabled = state.codexEnabled
            showEstimatedCost = state.showEstimatedCost
        } else {
            let d = AppState.defaults
            claude = d.claude; codex = d.codex; pollInterval = d.pollInterval
            claudeEnabled = d.claudeEnabled; codexEnabled = d.codexEnabled
            showEstimatedCost = d.showEstimatedCost
        }

        checkCredentials()
        HistoryStore.shared.pruneOldEntries()
        refreshCost()
        backfillCostHistory()
        startPolling()
    }

    /// A manager holding fixed data, for rendering README screenshots. Never polls or saves.
    init(preview claude: ServiceUsage, codex: ServiceUsage, dailyCost: DailyCostSummary) {
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai-bar-preview.json")
        self.claude = claude; self.codex = codex; pollInterval = 300
        claudeEnabled = true; codexEnabled = true
        claudeAvailable = true; codexAvailable = true
        showEstimatedCost = true
        self.dailyCost = dailyCost
    }

    func checkCredentials() {
        claudeAvailable = APIClient.claudeCredentialsExist()
        codexAvailable = APIClient.codexCredentialsExist()
    }

    func startPolling() {
        timer?.invalidate()
        pollTask?.cancel()
        pollNow()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
    }

    func pollNow(force: Bool = false) {
        pollTask?.cancel()
        checkCredentials()
        let shouldClaude = claudeEnabled && claudeAvailable && (force || Date() >= claudeNextPoll)
        let shouldCodex = codexEnabled && codexAvailable && (force || Date() >= codexNextPoll)

        pollTask = Task.detached { [weak self] in
            guard let self else { return }

            if shouldClaude {
                do {
                    let result = try await self.api.fetchClaudeUsage()
                    await MainActor.run {
                        self.claude.applyAPI(result)
                        self.claudeBackoff = 0
                        self.claudeNextPoll = .distantPast
                        self.save()
                    }
                    HistoryStore.shared.record(service: "claude", windowType: "five_hour", result: result)
                    if let wu = result.weeklyUtilization {
                        HistoryStore.shared.record(
                            service: "claude", windowType: "seven_day",
                            utilization: wu, resetsAt: result.weeklyResetsAt, windowDuration: 604800
                        )
                    }
                } catch let error as APIClient.APIError {
                    await MainActor.run {
                        self.claude.lastError = error.localizedDescription
                        if case .httpError(429) = error {
                            self.claudeBackoff = min(max(self.claudeBackoff * 2, 60), 1800)
                            self.claudeNextPoll = Date().addingTimeInterval(self.claudeBackoff)
                            self.claude.lastError = "Rate limited — retry in \(ServiceUsage.formatDuration(self.claudeBackoff))"
                            logToFile("Claude: 429, backing off \(self.claudeBackoff)s")
                        }
                    }
                } catch {
                    await MainActor.run { self.claude.lastError = error.localizedDescription }
                }
            }

            if shouldCodex {
                do {
                    let result = try await self.api.fetchCodexUsage()
                    await MainActor.run {
                        self.codex.applyAPI(result)
                        self.codexBackoff = 0
                        self.codexNextPoll = .distantPast
                        self.save()
                    }
                    HistoryStore.shared.record(service: "codex", windowType: "primary", result: result)
                    if let wu = result.weeklyUtilization {
                        HistoryStore.shared.record(
                            service: "codex", windowType: "secondary",
                            utilization: wu, resetsAt: result.weeklyResetsAt, windowDuration: 604800
                        )
                    }
                } catch let error as APIClient.APIError {
                    await MainActor.run {
                        self.codex.lastError = error.localizedDescription
                        if case .httpError(429) = error {
                            self.codexBackoff = min(max(self.codexBackoff * 2, 60), 1800)
                            self.codexNextPoll = Date().addingTimeInterval(self.codexBackoff)
                            self.codex.lastError = "Rate limited — retry in \(ServiceUsage.formatDuration(self.codexBackoff))"
                        }
                    }
                } catch {
                    await MainActor.run { self.codex.lastError = error.localizedDescription }
                }
            }

            if await self.showEstimatedCost {
                let cost = Self.scanAndStoreRecentCosts()
                await MainActor.run {
                    self.dailyCost = cost
                    self.costHistoryRevision += 1
                }
            }
        }
    }

    func retryAuth() {
        api.retryClaudeToken()
        claudeBackoff = 0
        claudeNextPoll = .distantPast
        pollNow(force: true)
    }

    func updatePollInterval(_ interval: TimeInterval) {
        pollInterval = interval
        save()
        startPolling()
    }

    func setProviderEnabled(_ provider: String, enabled: Bool) {
        switch provider {
        case "claude": claudeEnabled = enabled
        case "codex": codexEnabled = enabled
        default: break
        }
        save()
        if enabled { pollNow(force: true) }
    }

    func setShowEstimatedCost(_ show: Bool) {
        showEstimatedCost = show
        save()
        if show {
            refreshCost()
            backfillCostHistory()
        }
    }

    func refreshCost() {
        guard showEstimatedCost else { return }
        Task.detached {
            let cost = Self.scanAndStoreRecentCosts()
            await MainActor.run {
                self.dailyCost = cost
                self.costHistoryRevision += 1
            }
        }
    }

    /// Rescans yesterday and today (yesterday can still gain late entries), stores both,
    /// and returns today's summary.
    nonisolated private static func scanAndStoreRecentCosts() -> DailyCostSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let scanned = CostEstimator.shared.scan(since: yesterday)
        for day in [yesterday, today] {
            let key = CostEstimator.dayKey(day)
            HistoryStore.shared.storeCosts(day: key, summary: scanned[key] ?? .empty)
        }
        return scanned[CostEstimator.dayKey(today)] ?? .empty
    }

    /// Fills in days older than yesterday that have transcripts but no stored costs yet.
    /// Stored days are never overwritten, so history survives transcript cleanup.
    private func backfillCostHistory() {
        guard showEstimatedCost else { return }
        Task.detached(priority: .utility) {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            guard let windowStart = cal.date(byAdding: .day, value: -Self.costHistoryDays, to: today),
                  let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return }
            let yesterdayKey = CostEstimator.dayKey(yesterday)
            // After the first full backfill, only scan the gap since the last completed one
            var start = windowStart
            if let doneKey = UserDefaults.standard.string(forKey: Self.backfillDoneKey),
               let done = CostEstimator.date(fromDayKey: doneKey) {
                if doneKey >= yesterdayKey { return }
                start = max(start, done)
            }
            let stored = HistoryStore.shared.storedCostDays()
            let scanned = CostEstimator.shared.scan(since: start)
            var added = 0
            for (day, summary) in scanned where day < yesterdayKey && !stored.contains(day) {
                HistoryStore.shared.storeCosts(day: day, summary: summary)
                added += 1
            }
            UserDefaults.standard.set(yesterdayKey, forKey: Self.backfillDoneKey)
            if added > 0 {
                await MainActor.run { self.costHistoryRevision += 1 }
            }
        }
    }

    nonisolated static let costHistoryDays = 90
    nonisolated private static let backfillDoneKey = "costBackfillThrough"

    private func save() {
        let state = AppState(
            claude: claude, codex: codex, pollInterval: pollInterval,
            claudeEnabled: claudeEnabled, codexEnabled: codexEnabled,
            showEstimatedCost: showEstimatedCost
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
