import Foundation

/// Reads real token usage out of a Claude Code transcript JSONL and turns it
/// into the pet's XP bar + evolution. Both status sources feed this the same way:
///
///  - Claude Code: each live session's transcript at
///    `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` (resolved by globbing
///    on sessionId, so we don't have to reproduce Claude Code's cwd→slug rule).
///  - Orca: each entry in `last-status.json` already carries the exact path in
///    `providerSession.transcriptPath`.
///
/// The pet's XP% is the session's **context-window usage** — the current
/// prompt size vs. the model's context window — which is exactly the "N% 사용"
/// number the agent tools show in their corner. That means XP naturally sits in
/// a 0–100% band (a fresh session is low, a long one is high) instead of the
/// cumulative-token count, which would pin every real session at 100%.

/// Reads context-window usage from transcript JSONL files, caching per-file
/// results by modification time so the hot polling path only re-reads a
/// transcript that actually grew. Not thread-safe on its own — each watcher
/// owns one instance and only touches it from its own poll (main run loop).
final class TranscriptTokenReader {
    private var cache: [String: (mtime: Date, context: Double)] = [:]

    /// Current context size for one transcript (0 on read miss / no usage yet).
    func contextTokens(atPath path: String) -> Double {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let mtime, let cached = cache[path], cached.mtime == mtime {
            return cached.context
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return cache[path]?.context ?? 0 // transient read miss — keep last known
        }
        let context = Self.latestContextTokens(in: data)
        cache[path] = (mtime ?? Date(), context)
        return context
    }

    /// The representative context size across a set of entries: the **max** over
    /// their transcripts (the fullest live session drives the pet), deduped by
    /// path. Mirrors how the agent tools show one session's "% 사용" at a time.
    func maxContextTokens(for entries: [AgentStatusEntry]) -> Double {
        let paths = Set(entries.compactMap { $0.transcriptPath })
        return paths.reduce(0) { max($0, contextTokens(atPath: $1)) }
    }

    /// Parses each JSONL line and returns the **last** assistant message's
    /// context size (`input + cache_read + cache_creation` — the whole prompt
    /// that turn), i.e. usage "right now", not a sum across the session. Loose
    /// per-line parsing so one malformed line can't zero the file (same
    /// defensive stance as `parseAgentStatusEntries`).
    static func latestContextTokens(in data: Data) -> Double {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var latest: Double = 0
        text.enumerateLines { line, _ in
            guard
                let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { return }
            let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            latest = input + cacheRead + cacheCreation
        }
        return latest
    }
}

/// Maps context-window usage to the pet's XP bar fill and evolution stage.
/// Tuned low on purpose — this is a proof of concept, so the pet should visibly
/// evolve within a real working session.
enum XPModel {
    /// Model context window the usage % is measured against. 1M matches the
    /// long-context sessions in use (Orca's "8% 사용" ≈ ~80k context / 1M).
    static let contextWindow: Double = 1_000_000

    /// Default evolution thresholds (fractions of the bar). The live values are
    /// user-configurable from the menu bar (AppDelegate.evolutionThresholds).
    /// Intentionally early (PoC): stage 1 at 10%, stage 2 at 30%.
    static let stageThresholds: [Double] = [0.10, 0.30]

    /// XP% (0...1) = current context tokens / context window.
    static func percent(contextTokens: Double) -> Double {
        guard contextWindow > 0 else { return 0 }
        return min(1, max(0, contextTokens / contextWindow))
    }

    /// 0 = base form, 1 = first evolution, 2 = second evolution.
    static func stage(percent: Double, thresholds: [Double] = stageThresholds) -> Int {
        thresholds.reduce(0) { $0 + (percent >= $1 ? 1 : 0) }
    }

    /// How full the bar is *within the current stage* — progress from the stage's
    /// lower bound toward the next threshold, not absolute percent. e.g. at 8%
    /// with a 30% stage-1 threshold the bar is 8/30 ≈ 26.7% full. Once the final
    /// stage is reached the bar stays full.
    static func barFill(percent: Double, thresholds: [Double] = stageThresholds) -> Double {
        let s = stage(percent: percent, thresholds: thresholds)
        guard s < thresholds.count else { return 1.0 } // final stage → full bar
        let lower = s == 0 ? 0.0 : thresholds[s - 1]
        let upper = thresholds[s]
        guard upper > lower else { return 1.0 }
        return min(1, max(0, (percent - lower) / (upper - lower)))
    }
}
