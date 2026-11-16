import Foundation

/// API-equivalent cost of each Claude Code message since a horizon (the weekly window's start),
/// kept up to date by reading only what was appended to transcripts since the last update.
/// Rescanning whole transcripts takes tens of seconds; an incremental update takes milliseconds.
final class UsageLedger: @unchecked Sendable {
    static let claude = UsageLedger()

    private let lock = NSLock()
    // Guarded by `lock`
    private var costs: [String: (date: Date, cost: Double)] = [:]
    private var updating = false
    private var loaded = false

    // Only touched by the update in progress
    private var offsets: [String: UInt64] = [:]
    private var horizon: Date = .distantFuture

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// True once the first full read has finished.
    var isLoaded: Bool { lock.withLock { loaded } }

    /// Reads transcript lines appended since the last update and drops messages older than `newHorizon`.
    /// Returns false without doing anything if another update is running.
    @discardableResult
    func update(horizon newHorizon: Date) -> Bool {
        let proceed = lock.withLock { () -> Bool in
            if updating { return false }
            updating = true
            return true
        }
        guard proceed else { return false }
        defer { lock.withLock { updating = false } }

        if newHorizon < horizon {
            // Asked to look further back than what was read: start over.
            offsets = [:]
            lock.withLock { costs = [:] }
        }
        horizon = newHorizon

        // Recursive: subagent transcripts live in <project>/<session>/subagents/*.jsonl
        var changed: [(url: URL, size: UInt64, offset: UInt64)] = []
        if let files = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let file as URL in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, modified >= newHorizon,
                      let size = values.fileSize.map(UInt64.init) else { continue }
                var offset = offsets[file.path] ?? 0
                if size < offset { offset = 0 }  // file was rewritten
                if size > offset { changed.append((file, size, offset)) }
            }
        }

        // Files are independent: decode them in parallel
        var results = [(newOffset: UInt64, messages: [CostEstimator.ClaudeMessage])?](repeating: nil, count: changed.count)
        results.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: changed.count) { i in
                out[i] = Self.readAppended(changed[i].url, from: changed[i].offset)
            }
        }
        var found: [CostEstimator.ClaudeMessage] = []
        for (file, result) in zip(changed, results) {
            guard let result else { continue }
            offsets[file.url.path] = result.newOffset
            found.append(contentsOf: result.messages)
        }

        lock.withLock {
            for m in found where m.date >= newHorizon && costs[m.id] == nil {
                costs[m.id] = (m.date, CostEstimator.claudeCost(m))
            }
            costs = costs.filter { $0.value.date >= newHorizon }
            loaded = true
        }
        return true
    }

    /// Total cost of messages sent at or after `since`.
    func cost(since: Date) -> Double {
        lock.withLock {
            costs.values.reduce(0) { $1.date >= since ? $0 + $1.cost : $0 }
        }
    }

    /// Messages in the complete lines after `offset`, and the offset to continue from next time.
    private static func readAppended(_ file: URL, from offset: UInt64)
        -> (newOffset: UInt64, messages: [CostEstimator.ClaudeMessage])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Only complete lines; a partly written last line is read next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        return (offset + UInt64(complete.count), CostEstimator.claudeMessages(in: complete))
    }
}
