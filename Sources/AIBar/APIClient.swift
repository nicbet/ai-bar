import Foundation
import Security

func logToFile(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ai-bar/debug.log")
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

struct UsageAPIResult {
    var utilization: Double
    var resetsAt: Date?
    var windowDuration: TimeInterval
    var weeklyUtilization: Double?
    var weeklyResetsAt: Date?
}

final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private var claudeToken: String?
    private var claudeTokenAttempted = false

    // MARK: - Claude

    func fetchClaudeUsage() async throws -> UsageAPIResult {
        let token = try getClaudeToken()
        logToFile("Claude: fetching usage")

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logToFile("Claude: HTTP \(code) — \(String(body.prefix(200)))")
            if code == 401 { claudeToken = nil; claudeTokenAttempted = false }
            throw APIError.httpError(code)
        }

        return try parseClaudeResponse(data)
    }

    private func getClaudeToken() throws -> String {
        if let t = claudeToken { return t }
        if claudeTokenAttempted { throw APIError.noToken("Keychain denied — click Allow next time") }

        claudeTokenAttempted = true
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            logToFile("Claude keychain: denied (exit \(proc.terminationStatus))")
            throw APIError.noToken("Keychain denied")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            throw APIError.noToken("Keychain data unreadable")
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonData = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            claudeToken = token
            logToFile("Claude keychain: token found")
            return token
        }

        if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
            claudeToken = trimmed
            logToFile("Claude keychain: raw token found")
            return trimmed
        }

        throw APIError.noToken("Token not in keychain data")
    }

    func retryClaudeToken() {
        claudeToken = nil
        claudeTokenAttempted = false
    }

    private func parseClaudeResponse(_ data: Data) throws -> UsageAPIResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseFailed
        }

        func parseDate(_ s: String) -> Date? {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: s) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.date(from: s)
        }

        func extractWindow(_ json: [String: Any], keys: [String]) -> (Double, Date?)? {
            for key in keys {
                if let window = json[key] as? [String: Any] {
                    let util = window["utilization"] as? Double ?? 0
                    let resetStr = (window["resets_at"] ?? window["resetsAt"]) as? String
                    return (util / 100.0, resetStr.flatMap(parseDate))
                }
            }
            return nil
        }

        if let (util, reset) = extractWindow(json, keys: ["five_hour", "fiveHour"]) {
            let weekly = extractWindow(json, keys: ["seven_day", "sevenDay"])
            return UsageAPIResult(
                utilization: util, resetsAt: reset, windowDuration: 18000,
                weeklyUtilization: weekly?.0, weeklyResetsAt: weekly?.1
            )
        }

        if let limits = json["limits"] as? [[String: Any]], let first = limits.first {
            let pct = first["percent"] as? Double ?? 0
            let resetStr = (first["resets_at"] ?? first["resetsAt"]) as? String
            return UsageAPIResult(
                utilization: pct / 100.0, resetsAt: resetStr.flatMap(parseDate),
                windowDuration: 18000
            )
        }

        throw APIError.parseFailed
    }

    // MARK: - Codex

    func fetchCodexUsage() async throws -> UsageAPIResult {
        guard let (token, accountId) = readCodexToken() else {
            throw APIError.noToken("No auth token")
        }
        logToFile("Codex: fetching usage")

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let acctId = accountId {
            request.setValue(acctId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logToFile("Codex: HTTP \(code) — \(String(body.prefix(200)))")
            throw APIError.httpError(code)
        }

        return try parseCodexResponse(data)
    }

    private func readCodexToken() -> (token: String, accountId: String?)? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }
        let accountId = tokens["account_id"] as? String
        return (accessToken, accountId)
    }

    private func parseCodexResponse(_ data: Data) throws -> UsageAPIResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseFailed
        }

        func numVal(_ dict: [String: Any], _ key: String) -> Double? {
            dict[key] as? Double ?? (dict[key] as? Int).map(Double.init)
        }

        guard let rateLimit = json["rate_limit"] as? [String: Any],
              let primary = rateLimit["primary_window"] as? [String: Any] else {
            throw APIError.parseFailed
        }

        let pct = numVal(primary, "used_percent") ?? 0
        let resetAt = numVal(primary, "reset_at")
        let windowDuration = numVal(primary, "limit_window_seconds") ?? 18000

        var weeklyUtil: Double?
        var weeklyReset: Date?
        if let secondary = rateLimit["secondary_window"] as? [String: Any] {
            weeklyUtil = numVal(secondary, "used_percent").map { $0 / 100.0 }
            weeklyReset = numVal(secondary, "reset_at").map { Date(timeIntervalSince1970: $0) }
        }

        return UsageAPIResult(
            utilization: pct / 100.0,
            resetsAt: resetAt.map { Date(timeIntervalSince1970: $0) },
            windowDuration: windowDuration,
            weeklyUtilization: weeklyUtil,
            weeklyResetsAt: weeklyReset
        )
    }

    enum APIError: Error, LocalizedError {
        case noToken(String)
        case httpError(Int)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .noToken(let msg): return msg
            case .httpError(let code): return "HTTP \(code)"
            case .parseFailed: return "Parse failed"
            }
        }
    }
}
