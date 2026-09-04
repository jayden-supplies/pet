import Foundation

/// One recent Claude Code session, condensed to a single line the pet can say.
struct SessionBrief {
    let id: String            // sessionId — 요약 캐시가 같은 세션 묶음인지 판별하는 키
    let project: String       // cwd's last path component
    let branch: String?       // gitBranch at the time the session started
    let text: String          // already truncated to the caller's char budget
    /// 이 세션에서 **최근에** 요청한 것들. 첫 메시지가 세션의 목표라면 이쪽은
    /// 지금 무엇을 하고 있는지에 가깝다. 요약기가 이걸 재료로 쓴다.
    let recent: [String]
    /// 그 세션에서 **마지막으로 나온 응답**. 어디까지 진행됐는지는 사용자가 뭘
    /// 시켰는지만으로는 알 수 없고, 그래서 무엇이 됐는지가 있어야 판단된다.
    let lastReply: String?
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
    /// 최근 메시지는 파일 끝에서 읽는다. 헤드와 같은 이유로 통째로 읽지 않는다.
    private static let readTailBytes = 192 * 1024
    private static let recentMessageCount = 4
    private static let recentMessageChars = 220

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
            guard !isSelfGenerated(url) else { continue }
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

    /// 요약기가 돌린 `claude -p` 세션의 트랜스크립트인가.
    ///
    /// 그 호출도 Claude Code 세션이라 트랜스크립트를 남긴다. 걸러 내지 않으면
    /// 다음 브리핑에 "펫이 자기 요약을 요약한 내용"이 섞인다. 요약기는 전용
    /// 작업 디렉터리에서 돌고, Claude Code 는 cwd 를 슬러그화해 폴더 이름으로
    /// 쓰므로 폴더 이름만 봐도 구분된다.
    private static func isSelfGenerated(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.contains("ConnorPet")
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
        let (recent, lastReply) = recentExchange(in: file)
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        return (id, SessionBrief(
            id: id,
            project: project,
            branch: branch,
            text: truncate(text, to: perBriefChars),
            recent: recent,
            lastReply: lastReply,
            updatedAt: modifiedAt,
            isDesktop: isDesktop
        ))
    }

    /// 파일 끝에서 최근 요청들과 마지막 응답을 함께 뽑는다.
    /// 요청은 오래된 것부터 순서대로, 응답은 가장 마지막 것 하나.
    private static func recentExchange(in url: URL) -> (recent: [String], lastReply: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], nil) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], nil) }
        let start = size > UInt64(readTailBytes) ? size - UInt64(readTailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return ([], nil) }

        // 임의 위치에서 잘라 읽었으므로 첫 줄은 대개 반쪽짜리다. 그래서 1부터.
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var found: [String] = []
        var reply: String?
        for line in lines.reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let record = object as? [String: Any],
                (record["isSidechain"] as? Bool) != true
            else { continue }

            switch record["type"] as? String {
            case "assistant":
                // 도구 호출만 있는 응답은 건너뛴다. 텍스트가 있는 마지막 응답이
                // "무엇을 했는지"를 말해 준다.
                if reply == nil, let text = assistantText(in: record), text.count >= 12 {
                    reply = truncate(text, to: recentMessageChars)
                }
            case "user":
                if let raw = userText(in: record), let cleaned = clean(raw) {
                    found.append(truncate(cleaned, to: recentMessageChars))
                }
            default:
                break
            }
            if found.count >= recentMessageCount, reply != nil { break }
        }
        return (Array(found.prefix(recentMessageCount)).reversed(), reply)
    }

    /// assistant 레코드의 텍스트 블록만 이어 붙인다(도구 호출 블록은 뺀다).
    private static func assistantText(in record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
