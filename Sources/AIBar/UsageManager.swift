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

    var label: String {
        switch self {
        case .underPace:     return "Under pace"
        case .onPace:        return "On pace"
        case .slightlyAhead: return "Ahead"
        case .burningFast:   return "Burning fast"
        case .unknown:       return ""
        }
    }

    init(usage: Double, elapsed: Double?) {
        guard let elapsed else { self = .unknown; return }
        let delta = usage - elapsed
        if delta < -0.05 { self = .underPace }
        else if delta < 0.05 { self = .onPace }
        else if delta < 0.20 { self = .slightlyAhead }
        else { self = .burningFast }
    }
}

/// Which window the ring (and the menu bar) shows.
enum PrimaryIndicator: String, Codable, CaseIterable {
    /// The 5-hour window when the provider reports a real one, otherwise weekly.
    case auto
    case session
    case weekly
}

/// A 5-hour window AI Bar keeps itself when the provider has none. It opens on the first
/// usage after the previous one closed and measures weekly usage against a per-window budget.
struct SimulatedWindow: Codable, Equatable {
    static let duration: TimeInterval = 5 * 3600

    var start: Date
    /// Weekly utilization when the window opened.
    var baseline: Double
    /// Share of the weekly limit this window may use, fixed when it opens.
    var budget: Double

    var end: Date { start.addingTimeInterval(Self.duration) }
    func isActive(at now: Date = Date()) -> Bool { now >= start && now < end }

    /// Weekly headroom left, spread over the active windows left before the weekly reset.
    static func budget(remaining: Double, timeLeft: TimeInterval, windowsPerDay: Double) -> Double {
        let windows = max(max(timeLeft, 0) / 86400 * windowsPerDay, 1)
        return max(remaining / windows, 0.01)
    }
}

/// One window's reading, as the ring or the bar shows it.
struct UsageGauge {
    enum Kind { case session, weekly }

    let kind: Kind
    /// Fraction of the window's limit (or, when simulated, of its budget) used. Can exceed 1 when simulated.
    let utilization: Double
    let resetsAt: Date?
    let duration: TimeInterval
    var simulated = false
    /// Simulated window waiting for the next usage to open.
    var idle = false
    /// Simulated progress interpolated from local token usage between whole weekly percents.
    var estimated = false

    var percentInt: Int { Int(max(utilization, 0) * 100) }

    /// "42%"; estimated values under 10% get a decimal ("0.7%") so early progress is visible.
    var percentText: String {
        let pct = max(utilization, 0) * 100
        if estimated && pct < 10 { return String(format: "%.1f%%", (pct * 10).rounded(.down) / 10) }
        return "\(Int(pct))%"
    }

    var elapsedFraction: Double? {
        guard !idle, let resetsAt, duration > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(resetsAt.addingTimeInterval(-duration))
        return min(max(elapsed / duration, 0), 1.0)
    }

    var paceLevel: PaceLevel { PaceLevel(usage: utilization, elapsed: elapsedFraction) }

    var shortLabel: String {
        switch kind {
        case .session: return simulated ? "5h sim" : "5h"
        case .weekly:  return "Weekly"
        }
    }

    /// Time left, e.g. "2h 10m"; empty when unknown.
    var remainingText: String {
        guard let resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSinceNow
        return remaining > 0 ? ServiceUsage.formatDuration(remaining) : ""
    }

    /// Caption under the ring.
    var statusText: String {
        if idle { return "(5h window simulated)" }
        guard let resetsAt else { return kind == .weekly ? "weekly limit" : "reset inactive" }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "resetting..." }
        let time = ServiceUsage.formatDuration(remaining)
        switch kind {
        case .session: return simulated ? "simulated · resets in \(time)" : "resets in \(time)"
        case .weekly:  return "weekly · resets in \(time)"
        }
    }
}

struct ServiceUsage: Codable {
    /// Real 5-hour window from the provider; nil when it doesn't report one.
    var utilization: Double?
    var resetsAt: Date?
    var windowDuration: TimeInterval?

    var weeklyUtilization: Double?
    var weeklyResetsAt: Date?

    var lastError: String?
    var lastUpdated: Date?

    var weeklyWindowDuration: TimeInterval?
    /// True while AI Bar simulates the 5-hour window for this provider.
    var simulating: Bool?
    var simulated: SimulatedWindow?
    /// Local (transcript) API-equivalent cost since `windowCostStart`, the open simulated window's start.
    var windowCost: Double?
    var windowCostStart: Date?
    /// Local cost per whole weekly limit (1.0), learned from this week's cost and weekly utilization.
    var dollarsPerWeeklyUnit: Double?

    var hasAPIData: Bool { utilization != nil || weeklyUtilization != nil }
    var isSimulatingSession: Bool { utilization == nil && simulating == true }

    var sessionGauge: UsageGauge? {
        if let u = utilization {
            return UsageGauge(kind: .session, utilization: u, resetsAt: resetsAt,
                              duration: windowDuration ?? SimulatedWindow.duration)
        }
        guard simulating == true else { return nil }
        if let sim = simulated, sim.isActive(), let w = weeklyUtilization {
            let (used, estimated) = Self.windowUsage(sim: sim, weekly: w, windowCost: windowCost,
                                                     windowCostStart: windowCostStart,
                                                     dollarsPerWeeklyUnit: dollarsPerWeeklyUnit)
            return UsageGauge(kind: .session, utilization: used / sim.budget,
                              resetsAt: sim.end, duration: SimulatedWindow.duration,
                              simulated: true, estimated: estimated)
        }
        return UsageGauge(kind: .session, utilization: 0, resetsAt: nil,
                          duration: SimulatedWindow.duration, simulated: true, idle: true)
    }

    /// Weekly usage in the simulated window. The API reports whole percents only, so between steps
    /// it's estimated from local cost, kept within a point of what the whole-percent readings allow.
    static func windowUsage(sim: SimulatedWindow, weekly: Double, windowCost: Double?,
                            windowCostStart: Date?, dollarsPerWeeklyUnit: Double?) -> (Double, Bool) {
        let stepped = max(weekly - sim.baseline, 0)
        guard let cost = windowCost, windowCostStart == sim.start,
              let rate = dollarsPerWeeklyUnit, rate > 0 else { return (stepped, false) }
        // Baseline and current reading are each up to a point below the true value
        let low = max(stepped - 0.01, 0), high = stepped + 0.01
        return (min(max(cost / rate, low), high), true)
    }

    var weeklyGauge: UsageGauge? {
        guard let w = weeklyUtilization else { return nil }
        return UsageGauge(kind: .weekly, utilization: w, resetsAt: weeklyResetsAt,
                          duration: weeklyWindowDuration ?? 604800)
    }

    /// The ring's gauge and the bar's gauge for the chosen primary indicator.
    func gauges(primary: PrimaryIndicator) -> (main: UsageGauge?, secondary: UsageGauge?) {
        let session = sessionGauge, weekly = weeklyGauge
        let wantsSession: Bool
        switch primary {
        case .auto:    wantsSession = utilization != nil
        case .session: wantsSession = true
        case .weekly:  wantsSession = false
        }
        if wantsSession, let session { return (session, weekly) }
        if let weekly { return (weekly, session) }
        return (session, nil)
    }

    mutating func applyAPI(_ result: UsageAPIResult) {
        utilization = result.utilization
        resetsAt = result.resetsAt
        windowDuration = result.windowDuration
        weeklyUtilization = result.weeklyUtilization
        weeklyResetsAt = result.weeklyResetsAt
        weeklyWindowDuration = result.weeklyWindowDuration
        lastError = nil
        lastUpdated = Date()
    }

    /// Advances the simulated 5-hour window after a poll. `previous` is this usage as it was before the poll;
    /// `lastActivity` is when the provider's local transcripts last changed, if known.
    mutating func updateSimulation(previous: ServiceUsage, enabled: Bool, windowsPerDay: Double,
                                   lastActivity: Date? = nil, now: Date = Date()) {
        guard enabled, utilization == nil, let weekly = weeklyUtilization else {
            simulating = nil
            simulated = nil
            return
        }
        simulating = true

        if var sim = simulated, sim.isActive(at: now) {
            if weekly < sim.baseline {  // weekly limit reset mid-window
                sim.baseline = 0
                simulated = sim
            }
            return
        }

        // No open window: open one on usage since the last poll. Don't reach back further than
        // 15 minutes (the app may have been closed) or into the previous window.
        let lastEnd = simulated?.end ?? .distantPast
        var since = max(previous.lastUpdated ?? .distantPast, now.addingTimeInterval(-900), lastEnd)
        since = min(since, now)

        let weekRolledOver: Bool = {
            guard let old = previous.weeklyResetsAt, let new = weeklyResetsAt else { return false }
            return new.timeIntervalSince(old) > 3600
        }()
        let weeklyRose = previous.weeklyUtilization.map { weekRolledOver ? weekly > 0 : weekly > $0 } ?? false
        // Transcripts show usage the moment it happens, long before it adds up to a whole weekly percent
        let activeLocally = lastActivity.map { $0 > since } ?? false
        guard weeklyRose || activeLocally else { return }

        let start = since
        windowCost = nil
        windowCostStart = nil
        let baseline = weekRolledOver ? 0 : min(previous.weeklyUtilization ?? weekly, weekly)
        simulated = SimulatedWindow(
            start: start, baseline: baseline,
            budget: Self.simulatedBudget(start: start, baseline: baseline,
                                         weeklyResetsAt: weeklyResetsAt, windowsPerDay: windowsPerDay)
        )
    }

    /// Recomputes the open simulated window's budget for a new windows-per-day setting.
    mutating func rebudgetSimulation(windowsPerDay: Double) {
        guard var sim = simulated else { return }
        sim.budget = Self.simulatedBudget(start: sim.start, baseline: sim.baseline,
                                          weeklyResetsAt: weeklyResetsAt, windowsPerDay: windowsPerDay)
        simulated = sim
    }

    private static func simulatedBudget(start: Date, baseline: Double, weeklyResetsAt: Date?,
                                        windowsPerDay: Double) -> Double {
        let timeLeft = (weeklyResetsAt ?? start.addingTimeInterval(604800)).timeIntervalSince(start)
        return SimulatedWindow.budget(remaining: 1 - baseline, timeLeft: timeLeft, windowsPerDay: windowsPerDay)
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
    var primaryIndicator: PrimaryIndicator
    var simulateSessions: Bool
    var simulatedWindowsPerDay: Double

    static let defaults = AppState(
        claude: .empty, codex: .empty, pollInterval: 300,
        claudeEnabled: true, codexEnabled: true, showEstimatedCost: false,
        primaryIndicator: .auto, simulateSessions: true, simulatedWindowsPerDay: 2
    )

    init(claude: ServiceUsage, codex: ServiceUsage, pollInterval: TimeInterval,
         claudeEnabled: Bool, codexEnabled: Bool, showEstimatedCost: Bool,
         primaryIndicator: PrimaryIndicator, simulateSessions: Bool, simulatedWindowsPerDay: Double) {
        self.claude = claude; self.codex = codex; self.pollInterval = pollInterval
        self.claudeEnabled = claudeEnabled; self.codexEnabled = codexEnabled
        self.showEstimatedCost = showEstimatedCost
        self.primaryIndicator = primaryIndicator
        self.simulateSessions = simulateSessions
        self.simulatedWindowsPerDay = simulatedWindowsPerDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = (try? c.decode(ServiceUsage.self, forKey: .claude)) ?? .empty
        codex = (try? c.decode(ServiceUsage.self, forKey: .codex)) ?? .empty
        pollInterval = (try? c.decode(TimeInterval.self, forKey: .pollInterval)) ?? 300
        claudeEnabled = (try? c.decode(Bool.self, forKey: .claudeEnabled)) ?? true
        codexEnabled = (try? c.decode(Bool.self, forKey: .codexEnabled)) ?? true
        showEstimatedCost = (try? c.decode(Bool.self, forKey: .showEstimatedCost)) ?? false
        primaryIndicator = (try? c.decode(PrimaryIndicator.self, forKey: .primaryIndicator)) ?? .auto
        simulateSessions = (try? c.decode(Bool.self, forKey: .simulateSessions)) ?? true
        simulatedWindowsPerDay = (try? c.decode(Double.self, forKey: .simulatedWindowsPerDay)) ?? 2
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
    @Published var primaryIndicator: PrimaryIndicator
    @Published var simulateSessions: Bool
    @Published var simulatedWindowsPerDay: Double
    @Published var dailyCost: DailyCostSummary = .empty
    /// Bumped whenever stored daily cost history changes, so history views can reload
    @Published var costHistoryRevision = 0

    private var timer: Timer?
    private var estimateTimer: Timer?
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
            primaryIndicator = state.primaryIndicator
            simulateSessions = state.simulateSessions
            simulatedWindowsPerDay = state.simulatedWindowsPerDay
        } else {
            let d = AppState.defaults
            claude = d.claude; codex = d.codex; pollInterval = d.pollInterval
            claudeEnabled = d.claudeEnabled; codexEnabled = d.codexEnabled
            showEstimatedCost = d.showEstimatedCost
            primaryIndicator = d.primaryIndicator
            simulateSessions = d.simulateSessions
            simulatedWindowsPerDay = d.simulatedWindowsPerDay
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
        primaryIndicator = .auto; simulateSessions = true; simulatedWindowsPerDay = 2
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
        // Local usage moves the simulated window between polls
        estimateTimer?.invalidate()
        estimateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaudeEstimate() }
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
                    let activity = LocalActivity.lastClaudeActivity()
                    let simulated = await MainActor.run { () -> Double? in
                        let previous = self.claude
                        self.claude.applyAPI(result)
                        self.claude.updateSimulation(previous: previous, enabled: self.simulateSessions,
                                                     windowsPerDay: self.simulatedWindowsPerDay,
                                                     lastActivity: activity)
                        self.claudeBackoff = 0
                        self.claudeNextPoll = .distantPast
                        self.save()
                        return self.claude.isSimulatingSession ? self.claude.sessionGauge?.utilization : nil
                    }
                    await MainActor.run { self.refreshClaudeEstimate() }
                    HistoryStore.shared.record(service: "claude", windowType: "five_hour", result: result)
                    if let simulated {
                        HistoryStore.shared.record(service: "claude", windowType: Self.simulatedWindowType,
                                                   utilization: simulated, resetsAt: nil,
                                                   windowDuration: SimulatedWindow.duration)
                    }
                    if let wu = result.weeklyUtilization {
                        HistoryStore.shared.record(
                            service: "claude", windowType: "seven_day",
                            utilization: wu, resetsAt: result.weeklyResetsAt,
                            windowDuration: result.weeklyWindowDuration
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
                    let activity = LocalActivity.lastCodexActivity()
                    let simulated = await MainActor.run { () -> Double? in
                        let previous = self.codex
                        self.codex.applyAPI(result)
                        self.codex.updateSimulation(previous: previous, enabled: self.simulateSessions,
                                                    windowsPerDay: self.simulatedWindowsPerDay,
                                                    lastActivity: activity)
                        self.codexBackoff = 0
                        self.codexNextPoll = .distantPast
                        self.save()
                        return self.codex.isSimulatingSession ? self.codex.sessionGauge?.utilization : nil
                    }
                    HistoryStore.shared.record(service: "codex", windowType: "primary", result: result)
                    if let simulated {
                        HistoryStore.shared.record(service: "codex", windowType: Self.simulatedWindowType,
                                                   utilization: simulated, resetsAt: nil,
                                                   windowDuration: SimulatedWindow.duration)
                    }
                    if let wu = result.weeklyUtilization {
                        HistoryStore.shared.record(
                            service: "codex", windowType: "secondary",
                            utilization: wu, resetsAt: result.weeklyResetsAt,
                            windowDuration: result.weeklyWindowDuration
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

    func setPrimaryIndicator(_ indicator: PrimaryIndicator) {
        primaryIndicator = indicator
        save()
    }

    func setSimulateSessions(_ enabled: Bool) {
        simulateSessions = enabled
        // Apply now rather than on the next poll; a new window still waits for the next usage.
        claude.updateSimulation(previous: claude, enabled: enabled, windowsPerDay: simulatedWindowsPerDay)
        codex.updateSimulation(previous: codex, enabled: enabled, windowsPerDay: simulatedWindowsPerDay)
        save()
    }

    /// Also re-budgets the open simulated windows, as if they had opened with the new setting.
    func setSimulatedWindowsPerDay(_ windows: Double) {
        simulatedWindowsPerDay = windows
        claude.rebudgetSimulation(windowsPerDay: windows)
        codex.rebudgetSimulation(windowsPerDay: windows)
        save()
    }

    nonisolated static let simulatedWindowType = "five_hour_simulated"

    /// Updates Claude's local cost since the simulated window opened, and the learned cost per weekly
    /// limit, from transcripts. Only for simulated windows; the first update after launch reads a week of
    /// transcripts and takes a while, later ones only read what was appended.
    func refreshClaudeEstimate() {
        guard claude.isSimulatingSession, let weekly = claude.weeklyUtilization else { return }
        let weekStart = (claude.weeklyResetsAt ?? Date().addingTimeInterval(604800))
            .addingTimeInterval(-(claude.weeklyWindowDuration ?? 604800))
        let window = claude.simulated.flatMap { $0.isActive() ? $0.start : nil }
        Task.detached(priority: .utility) {
            let ledger = UsageLedger.claude
            guard ledger.update(horizon: weekStart), ledger.isLoaded else { return }
            let weekCost = ledger.cost(since: weekStart)
            let windowCost = window.map { ledger.cost(since: $0) }
            await MainActor.run {
                // Learn the rate once the weekly figure is big enough for whole percents to be accurate
                if weekly >= 0.03, weekCost > 0, self.claude.weeklyUtilization == weekly {
                    self.claude.dollarsPerWeeklyUnit = weekCost / weekly
                }
                if let window, self.claude.simulated?.start == window {
                    self.claude.windowCost = windowCost
                    self.claude.windowCostStart = window
                }
                self.save()
            }
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
            showEstimatedCost: showEstimatedCost,
            primaryIndicator: primaryIndicator, simulateSessions: simulateSessions,
            simulatedWindowsPerDay: simulatedWindowsPerDay
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
