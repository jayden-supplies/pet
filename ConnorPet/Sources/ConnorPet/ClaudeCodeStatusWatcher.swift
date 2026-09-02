import Darwin
import Foundation

/// Polls Claude Code's own per-session status files — the same files backing
/// `claude agents`/`claude agents --json` — and republishes the aggregate pet
/// animation whenever they change. Mirrors `OrcaStatusWatcher`'s shape so the
/// menu-bar source picker can swap between the two transparently.
///
/// Claude Code writes one file per running CLI process at
/// `~/.claude/sessions/<pid>.json`. Confirmed live fields (v2.1.197): `status`
/// ("busy" while a turn is in flight, "idle" once control returns to the
/// user), `updatedAt`/`statusUpdatedAt`, `cwd`, `name`. The parser also reads
/// (but we never observed populated in practice) a richer `tempo` field
/// ("active" | "idle" | "blocked") plus `waitingFor`/`needs` strings — if a
/// future Claude Code version starts populating `tempo: "blocked"` (e.g. for
/// a pending permission prompt), this watcher already maps it to the pet's
/// waiting/freeze state for free. Until then, "busy" is the only working
/// signal available, so there's no Claude Code equivalent of Orca's "done"
/// (retained-for-review) state — the review/heart-eyes animation simply never
/// triggers from this source.
final class ClaudeCodeStatusWatcher: AgentStatusWatching {
    private let sessionsDir: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastDirectoryFingerprint: [String: Date] = [:]

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(pollInterval: TimeInterval = 0.25) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDir = home.appendingPathComponent(".claude/sessions")
        self.pollInterval = pollInterval
    }

    func start() {
        poll()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        // Why: skip re-parsing entirely when nothing on disk changed since the
        // last poll — this runs 4x/sec for the app's whole lifetime.
        var fingerprint: [String: Date] = [:]
        for file in jsonFiles {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            fingerprint[file.lastPathComponent] = mtime ?? .distantPast
        }
        if fingerprint == lastDirectoryFingerprint {
            return
        }
        lastDirectoryFingerprint = fingerprint

        var entries: [AgentStatusEntry] = []
        for file in jsonFiles {
            guard let entry = parseSessionEntry(at: file) else { continue }
            entries.append(entry)
        }
        publish(entries: entries)
    }

    private func parseSessionEntry(at fileURL: URL) -> AgentStatusEntry? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let root = rawObject as? [String: Any],
            let pid = (root["pid"] as? NSNumber)?.int32Value
        else { return nil }

        // Skip sessions whose process has already exited — Claude Code itself
        // lazily garbage-collects these files, so a stale one can briefly
        // linger after the CLI quits without cleaning up.
        guard kill(pid_t(pid), 0) == 0 else { return nil }

        let status = root["status"] as? String
        let tempo = root["tempo"] as? String
        let state: String
        if tempo == "blocked" {
            state = "blocked"
        } else if status == "busy" || tempo == "active" {
            state = "working"
        } else {
            state = "idle"
        }

        let name = root["name"] as? String
        let cwd = root["cwd"] as? String
        let updatedAt = (root["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (root["updatedAt"] as? NSNumber)?.doubleValue
            ?? (Date().timeIntervalSince1970 * 1000)

        return AgentStatusEntry(
            paneKey: "claude-code:\(name ?? String(pid))",
            state: state,
            workingMode: nil,
            worktreeId: cwd,
            updatedAt: updatedAt
        )
    }

    private func publish(entries: [AgentStatusEntry]) {
        let now = Date().timeIntervalSince1970 * 1000
        let result = agentStateAnimation(entries: entries, retainedCount: 0, now: now)
        if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
            FileHandle.standardError.write("[connor-pet] claude-code: \(entries.count) session(s) -> \(result.animation)\n".data(using: .utf8)!)
            for line in result.trace { FileHandle.standardError.write("  \(line.line)\n".data(using: .utf8)!) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
