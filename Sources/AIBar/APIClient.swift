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
    /// Short (5-hour) window. Nil when the provider doesn't report one, e.g. plans without a 5-hour limit.
    var utilization: Double?
    var resetsAt: Date?
    var windowDuration: TimeInterval
    var weeklyUtilization: Double?
    var weeklyResetsAt: Date?
    var weeklyWindowDuration: TimeInterval = 604800
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
    private var loggedMissingSession = false

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
        // Read Claude Code's item with the Security framework, so the keychain prompt (and an
        // "Always Allow") applies to AI Bar itself rather than to /usr/bin/security.
        var query = claudeKeychainQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            logToFile("Claude keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error") (\(status))")
            switch status {
            case errSecItemNotFound: throw APIError.noToken("No Claude Code login in keychain")
            case errSecUserCanceled, errSecAuthFailed: throw APIError.noToken("Keychain denied")
            default: throw APIError.noToken("Keychain error \(status)")
            }
        }

        guard let data = item as? Data, let raw = String(data: data, encoding: .utf8) else {
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

    /// Claude Code's login item. Matching on attributes alone never shows a keychain prompt.
    private static let claudeKeychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    private var claudeKeychainQuery: [String: Any] { Self.claudeKeychainQuery }

    static func claudeCredentialsExist() -> Bool {
        SecItemCopyMatching(claudeKeychainQuery as CFDictionary, nil) == errSecSuccess
    }

    static func codexCredentialsExist() -> Bool {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            return false
        }
        return true
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

        func number(_ v: Any?) -> Double? {
            v as? Double ?? (v as? Int).map(Double.init)
        }

        func extractWindow(_ json: [String: Any], keys: [String]) -> (Double, Date?)? {
            for key in keys {
                if let window = json[key] as? [String: Any], let util = number(window["utilization"]) {
                    let resetStr = (window["resets_at"] ?? window["resetsAt"]) as? String
                    return (util / 100.0, resetStr.flatMap(parseDate))
                }
            }
            return nil
        }

        // Either window can be missing or null: plans without a 5-hour limit report only the weekly one.
        let session = extractWindow(json, keys: ["five_hour", "fiveHour"])
        var weekly = extractWindow(json, keys: ["seven_day", "sevenDay"])

        if session == nil && weekly == nil,
           let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            // Older/alternate shape. Only trust an entry as weekly if it says so or resets more than a day out;
            // never present it as the 5-hour window.
            for entry in limits {
                guard let pct = number(entry["percent"] ?? entry["utilization"]) else { continue }
                let reset = ((entry["resets_at"] ?? entry["resetsAt"]) as? String).flatMap(parseDate)
                let name = [entry["window"], entry["type"], entry["name"], entry["id"]]
                    .compactMap { $0 as? String }.joined(separator: " ").lowercased()
                let looksWeekly = name.contains("week") || name.contains("seven")
                    || (reset.map { $0.timeIntervalSinceNow > 86400 } ?? false)
                if looksWeekly { weekly = (pct / 100.0, reset); break }
            }
        }

        if session == nil && !loggedMissingSession {
            loggedMissingSession = true
            logToFile("Claude: no five_hour window; top-level keys: \(json.keys.sorted().joined(separator: ", "))")
        }

        guard session != nil || weekly != nil else { throw APIError.parseFailed }
        return UsageAPIResult(
            utilization: session?.0, resetsAt: session?.1, windowDuration: 18000,
            weeklyUtilization: weekly?.0, weeklyResetsAt: weekly?.1
        )
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

        guard let rateLimit = json["rate_limit"] as? [String: Any] else {
            throw APIError.parseFailed
        }

        typealias Window = (util: Double, reset: Date?, seconds: TimeInterval?)
        func window(_ key: String) -> Window? {
            guard let w = rateLimit[key] as? [String: Any], let pct = numVal(w, "used_percent") else { return nil }
            return (pct / 100.0, numVal(w, "reset_at").map { Date(timeIntervalSince1970: $0) },
                    numVal(w, "limit_window_seconds"))
        }

        var session = window("primary_window")
        var weekly = window("secondary_window")
        // If the only window reported is a long one, it's the weekly limit, not a session.
        if weekly == nil, let s = session, let secs = s.seconds, secs > 86400 {
            weekly = s
            session = nil
        }
        guard session != nil || weekly != nil else { throw APIError.parseFailed }

        return UsageAPIResult(
            utilization: session?.util,
            resetsAt: session?.reset,
            windowDuration: session?.seconds ?? 18000,
            weeklyUtilization: weekly?.util,
            weeklyResetsAt: weekly?.reset,
            weeklyWindowDuration: weekly?.seconds ?? 604800
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
