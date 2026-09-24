import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct UsageSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let utilization: Double
}

final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ai-bar")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)
        let dbPath = configDir.appendingPathComponent("history.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            logToFile("HistoryStore: failed to open database")
            return
        }

        createTables()
    }

    deinit { sqlite3_close(db) }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            service TEXT NOT NULL,
            window_type TEXT NOT NULL,
            utilization REAL NOT NULL,
            resets_at TEXT,
            window_duration REAL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_service_time
            ON usage_snapshots(service, timestamp);
        CREATE TABLE IF NOT EXISTS daily_costs (
            day TEXT NOT NULL,
            service TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cost REAL NOT NULL,
            PRIMARY KEY (day, service, model)
        );
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            logToFile("HistoryStore: create table error: \(msg)")
            sqlite3_free(errmsg)
        }
    }

    func record(service: String, windowType: String,
                utilization: Double, resetsAt: Date?, windowDuration: TimeInterval?) {
        guard let db else { return }

        let sql = "INSERT INTO usage_snapshots (timestamp, service, window_type, utilization, resets_at, window_duration) VALUES (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, service, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, windowType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, utilization)

        if let reset = resetsAt {
            let resetStr = ISO8601DateFormatter().string(from: reset)
            sqlite3_bind_text(stmt, 5, resetStr, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if let dur = windowDuration {
            sqlite3_bind_double(stmt, 6, dur)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            logToFile("HistoryStore: insert failed")
        }
    }

    func record(service: String, windowType: String, result: UsageAPIResult) {
        record(service: service, windowType: windowType,
               utilization: result.utilization, resetsAt: result.resetsAt,
               windowDuration: result.windowDuration)
    }

    func snapshots(service: String, windowType: String, since: Date) -> [UsageSnapshot] {
        guard let db else { return [] }

        let sql = "SELECT timestamp, utilization FROM usage_snapshots WHERE service = ? AND window_type = ? AND timestamp >= ? ORDER BY timestamp ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let sinceStr = ISO8601DateFormatter().string(from: since)
        sqlite3_bind_text(stmt, 1, service, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, windowType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, sinceStr, -1, SQLITE_TRANSIENT)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        var results: [UsageSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let tsRaw = sqlite3_column_text(stmt, 0) else { continue }
            let tsStr = String(cString: tsRaw)
            guard let date = fmt.date(from: tsStr) else { continue }
            let util = sqlite3_column_double(stmt, 1)
            results.append(UsageSnapshot(timestamp: date, utilization: util))
        }
        return results
    }

    // MARK: - Daily costs

    /// Replaces all stored cost rows for `day` ("yyyy-MM-dd") with `summary`.
    func storeCosts(day: String, summary: DailyCostSummary) {
        guard let db else { return }
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)

        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM daily_costs WHERE day = ?;", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, day, -1, SQLITE_TRANSIENT)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)

        let sql = "INSERT INTO daily_costs (day, service, model, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        let rows = summary.claudeModels.map { ("claude", $0) } + summary.codexModels.map { ("codex", $0) }
        for (service, entry) in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, service, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, entry.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(entry.inputTokens))
            sqlite3_bind_int64(stmt, 5, Int64(entry.outputTokens))
            sqlite3_bind_int64(stmt, 6, Int64(entry.cacheWriteTokens))
            sqlite3_bind_int64(stmt, 7, Int64(entry.cacheReadTokens))
            sqlite3_bind_double(stmt, 8, entry.cost)
            if sqlite3_step(stmt) != SQLITE_DONE {
                logToFile("HistoryStore: cost insert failed")
            }
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Days ("yyyy-MM-dd") that already have stored cost rows.
    func storedCostDays() -> Set<String> {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT day FROM daily_costs;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var days: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 0) { days.insert(String(cString: raw)) }
        }
        return days
    }

    /// Stored per-day summaries from `day` ("yyyy-MM-dd") onward.
    func costHistory(since day: String) -> [String: DailyCostSummary] {
        guard let db else { return [:] }
        let sql = "SELECT day, service, model, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, cost FROM daily_costs WHERE day >= ? ORDER BY day ASC, cost DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)

        var result: [String: DailyCostSummary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayRaw = sqlite3_column_text(stmt, 0),
                  let serviceRaw = sqlite3_column_text(stmt, 1),
                  let modelRaw = sqlite3_column_text(stmt, 2) else { continue }
            let entry = ModelCostEntry(
                model: String(cString: modelRaw),
                inputTokens: Int(sqlite3_column_int64(stmt, 3)),
                outputTokens: Int(sqlite3_column_int64(stmt, 4)),
                cacheWriteTokens: Int(sqlite3_column_int64(stmt, 5)),
                cacheReadTokens: Int(sqlite3_column_int64(stmt, 6)),
                cost: sqlite3_column_double(stmt, 7))
            let d = String(cString: dayRaw)
            if String(cString: serviceRaw) == "claude" {
                result[d, default: DailyCostSummary()].claudeModels.append(entry)
            } else {
                result[d, default: DailyCostSummary()].codexModels.append(entry)
            }
        }
        return result
    }

    func pruneOldEntries(olderThanDays days: Int = 90) {
        guard let db else { return }
        let sql = "DELETE FROM usage_snapshots WHERE timestamp < datetime('now', '-\(days) days');"
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM daily_costs WHERE day < date('now', '-400 days');", nil, nil, nil)
    }
}
