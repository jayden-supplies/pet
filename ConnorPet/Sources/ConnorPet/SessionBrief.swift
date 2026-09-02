import Foundation

/// One recent Claude Code session, condensed to a single line the pet can say.
struct SessionBrief {
    let project: String       // cwd's last path component
    let branch: String?       // gitBranch at the time the session started
    let text: String          // already truncated to the caller's char budget
    let updatedAt: Date
    let isDesktop: Bool       // claude-desktop vs cli, for the "어디서" hint
}

/// Reads recent session activity straight out of Claude Code's own transcript
/// directory, `~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl`.
///
/// Why this directory: **both** Claude Code entrypoints write here — the `claude`
/// CLI and the desktop app — and each assistant record carries an `entrypoint`
/// field ("cli" / "claude-desktop") that tells them apart. So one reader covers
/// both without shelling out to either.
///
/// Why only the head of each file: transcripts get big (a 31MB session was
/// observed live) and this runs on a click, so reading them whole would stall
/// the UI. Everything needed is near the top — the session's opening user
/// message is what states the task, and it landed within the first 8KB in every
/// recent transcript checked. `readHeadBytes` caps the read well above that.
enum SessionBriefReader {
    private static let readHeadBytes = 128 * 1024

    static var transcriptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Most-recently-active sessions first.
    ///
    /// - Parameters:
    ///   - withinHours: only sessions touched this recently are considered.
    ///   - limit: how many briefs to return.
    ///   - perBriefChars: hard cap on each brief's own text.
    static func recent(
        withinHours: Double = 6,
        limit: Int = 5,
        perBriefChars: Int = 100,
        now: Date = Date()
    ) -> [SessionBrief] {
        let cutoff = now.addingTimeInterval(-withinHours * 3600)
        let files = recentTranscripts(since: cutoff)

        var bySession: [String: SessionBrief] = [:]
        var order: [String] = []

        for file in files {
            // Scanning stops once enough sessions survive filtering. Files are
            // already newest-first, so the ones dropped here are always older
            // than everything kept.
            if bySession.count >= limit { break }
            guard let (sessionId, brief) = parse(file: file.url, modifiedAt: file.modifiedAt,
                                                 perBriefChars: perBriefChars) else { continue }
            // The same session id can appear under two project folders (observed
            // when a session's cwd changed). Keep the more recently written copy.
            if let existing = bySession[sessionId], existing.updatedAt >= brief.updatedAt { continue }
            if bySession[sessionId] == nil { order.append(sessionId) }
            bySession[sessionId] = brief
        }

        return order.compactMap { bySession[$0] }
    }

    // MARK: - File discovery

    private struct Transcript {
        let url: URL
        let modifiedAt: Date
    }

    private static func recentTranscripts(since cutoff: Date) -> [Transcript] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: transcriptsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [Transcript] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let modified = values.contentModificationDate,
                modified >= cutoff
            else { continue }
            found.append(Transcript(url: url, modifiedAt: modified))
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Parsing

    private static func parse(file: URL, modifiedAt: Date, perBriefChars: Int) -> (String, SessionBrief)? {
        guard let head = readHead(of: file) else { return nil }

        var sessionId: String?
        var cwd: String?
        var branch: String?
        var isDesktop = false
        var opening: String?

        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any]
            else { continue }

            sessionId = sessionId ?? record["sessionId"] as? String
            cwd = cwd ?? record["cwd"] as? String
            branch = branch ?? (record["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let entrypoint = record["entrypoint"] as? String, entrypoint.contains("desktop") {
                isDesktop = true
            }

            if opening == nil,
               record["type"] as? String == "user",
               (record["isSidechain"] as? Bool) != true,
               let text = userText(in: record),
               let cleaned = clean(text) {
                opening = cleaned
            }

            // The opening message is the goal statement; metadata is on the same
            // or an earlier record, so there is nothing left to learn after it.
            if opening != nil, sessionId != nil, cwd != nil { break }
        }

        guard let id = sessionId, let text = opening else { return nil }
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        return (id, SessionBrief(
            project: project,
            branch: branch,
            text: truncate(text, to: perBriefChars),
            updatedAt: modifiedAt,
            isDesktop: isDesktop
        ))
    }

    private static func readHead(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: readHeadBytes)
    }

    /// A user record's content is either a plain string or an array of typed
    /// blocks; only the `text` blocks are the human's own words.
    private static func userText(in record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Drops the records that are technically "user" messages but are not the
    /// human describing a task: slash-command envelopes, the expanded body of a
    /// skill or command, injected reminders, and one-word throwaways like the
    /// "repeat hi" smoke-test sessions found in the live transcripts.
    private static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let rejectedPrefixes = [
            "<command-name>", "<command-message>", "<local-command",
            "<system-reminder>", "<user-prompt-submit-hook>",
            "Caveat:", "#",
        ]
        for prefix in rejectedPrefixes where text.hasPrefix(prefix) { return nil }

        // Collapse newlines/tabs so the bubble lays out as one flowing line.
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        return text.count >= 12 ? text : nil
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
