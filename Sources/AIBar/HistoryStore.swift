import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    func pruneOldEntries(olderThanDays days: Int = 90) {
        guard let db else { return }
        let sql = "DELETE FROM usage_snapshots WHERE timestamp < datetime('now', '-\(days) days');"
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
