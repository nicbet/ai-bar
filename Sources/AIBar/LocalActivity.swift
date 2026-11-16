import Foundation

/// When Claude Code or Codex last wrote to a transcript: a precise, local signal of usage,
/// unlike the weekly percentage, which the APIs report in whole percents.
enum LocalActivity {
    static func lastClaudeActivity() -> Date? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        // Recursive: subagent transcripts live in <project>/<session>/subagents/*.jsonl
        guard let files = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return latest(files.compactMap { $0 as? URL })
    }

    static func lastCodexActivity() -> Date? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy/MM/dd"
        // Sessions are filed by start date; a session from yesterday can still be running
        let today = Date()
        let days = [today, today.addingTimeInterval(-86400)]
        let files = days.flatMap { day in
            (try? FileManager.default.contentsOfDirectory(
                at: sessionsDir.appendingPathComponent(fmt.string(from: day)),
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        return latest(files)
    }

    private static func latest(_ files: [URL]) -> Date? {
        files.lazy
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
