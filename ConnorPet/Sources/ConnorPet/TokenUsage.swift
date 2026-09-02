import Foundation

/// Reads real cumulative token usage out of a Claude Code transcript JSONL and
/// converts it into an "experience"/level curve for the pet's XP bar and
/// evolution. Both status sources feed this the same way:
///
///  - Claude Code: each live session's transcript at
///    `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` (resolved by globbing
///    on sessionId, so we don't have to reproduce Claude Code's cwd→slug rule).
///  - Orca: each entry in `last-status.json` already carries the exact path in
///    `providerSession.transcriptPath`.
///
/// The transcript is the *only* on-disk place Claude Code records per-turn
/// `usage` (input/output/cache tokens); the session file and Orca's status file
/// never contain token counts themselves.

/// Sums token usage from transcript JSONL files, caching per-file results by
/// modification time so the hot polling path only re-reads a transcript that
/// actually grew. Not thread-safe on its own — each watcher owns one instance
/// and only touches it from its own poll (main run loop).
final class TranscriptTokenReader {
    private var cache: [String: (mtime: Date, tokens: Double)] = [:]

    /// Cumulative "tokens used" for one transcript. We sum, across every
    /// assistant message, `input + output + cache_creation` — the non-cached
    /// (roughly "billed new work") tokens. cache_read is deliberately excluded:
    /// it re-counts the whole prompt context every turn and would balloon the
    /// number an order of magnitude without reflecting extra work done.
    func tokens(atPath path: String) -> Double {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if let mtime, let cached = cache[path], cached.mtime == mtime {
            return cached.tokens
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return cache[path]?.tokens ?? 0 // transient read miss — keep last known
        }
        let total = Self.sumTokens(in: data)
        cache[path] = (mtime ?? Date(), total)
        return total
    }

    /// Total tokens across a set of entries, deduping by transcript path so two
    /// panes pointed at the same session aren't counted twice.
    func total(for entries: [AgentStatusEntry]) -> Double {
        let paths = Set(entries.compactMap { $0.transcriptPath })
        return paths.reduce(0) { $0 + tokens(atPath: $1) }
    }

    /// Parses each JSONL line and adds up `message.usage`. Loose parsing per
    /// line so one malformed line can't zero the whole file (same defensive
    /// stance as `parseAgentStatusEntries`).
    static func sumTokens(in data: Data) -> Double {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var total: Double = 0
        text.enumerateLines { line, _ in
            guard
                let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { return }
            let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            total += input + output + cacheCreation
        }
        return total
    }
}

/// Maps a raw cumulative-token count to the pet's XP bar fill (0...1) and its
/// evolution stage. Tuned low on purpose — this is a proof of concept, so the
/// pet should visibly evolve within a single real working session rather than
/// after hours of use.
enum XPModel {
    /// Tokens that fill the bar to 100%. Sized so a real working session spans
    /// a visible range of the bar rather than pinning it at full (observed live:
    /// heavy multi-session totals land around ~800k), while still being
    /// reachable.
    static let maxTokens: Double = 1_000_000

    /// Fraction cutoffs at which the pet advances to evolution stage 1, then 2.
    /// Intentionally early (PoC): stage 1 at 10% (~100k tokens), stage 2 at 30%
    /// (~300k) — the pet visibly evolves within normal use instead of needing a
    /// full bar.
    static let stageThresholds: [Double] = [0.10, 0.30]

    static func percent(tokens: Double) -> Double {
        guard maxTokens > 0 else { return 0 }
        return min(1, max(0, tokens / maxTokens))
    }

    /// 0 = base form, 1 = first evolution, 2 = second evolution.
    static func stage(percent: Double) -> Int {
        stageThresholds.reduce(0) { $0 + (percent >= $1 ? 1 : 0) }
    }
}
