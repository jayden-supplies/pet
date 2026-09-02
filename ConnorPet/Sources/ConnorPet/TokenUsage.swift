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

    // MARK: - Cumulative-usage text label

    /// Compact token count: 800000 → "800k", 6_500_000 → "6.5M", 1e9 → "1B".
    static func formatTokens(_ n: Double) -> String {
        func trim(_ v: Double) -> String {
            if v >= 100 { return "\(Int(v.rounded()))" }
            let s = String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        let a = abs(n)
        if a >= 1e9 { return trim(n / 1e9) + "B" }
        if a >= 1e6 { return trim(n / 1e6) + "M" }
        if a >= 1e3 { return trim(n / 1e3) + "k" }
        return "\(Int(n.rounded()))"
    }

    /// Small label drawn on the XP bar: cumulative token usage over the budget,
    /// e.g. "850M / 100M (850%)". Percent is one-decimal below 10% (so a small
    /// weekly fraction stays legible) and integer above.
    static func usageLabel(cumulative: Double, max maxBudget: Double) -> String {
        let pct = maxBudget > 0 ? cumulative / maxBudget * 100 : 0
        let pctStr: String
        if pct <= 0 { pctStr = "0%" }
        else if pct >= 10 { pctStr = "\(Int(pct.rounded()))%" }
        else { pctStr = String(format: "%.1f%%", pct) }
        return "\(formatTokens(cumulative)) / \(formatTokens(maxBudget)) (\(pctStr))"
    }
}

/// Sums **cumulative** token usage across every Claude Code transcript touched
/// within a rolling window (default 7 days) — the number behind the XP bar's
/// "누적 / 최대" label. This is a different aggregation from
/// `TranscriptTokenReader` (which reads one session's *current* context): here
/// we scan all of `~/.claude/projects`, sum every message's tokens **including
/// cache_read**, and cache per-file by mtime so only changed transcripts
/// re-parse. There is no on-disk signal for the account's real quota/reset, so
/// the window is a plain rolling 7 days and the budget (denominator) is a
/// user-set menu value, not auto-detected.
final class WeeklyUsageReader {
    private let projectsDir: URL
    private let windowSeconds: TimeInterval
    private var cache: [String: (mtime: Date, tokens: Double)] = [:]

    init(projectsDir: URL, windowSeconds: TimeInterval = 7 * 24 * 60 * 60) {
        self.projectsDir = projectsDir
        self.windowSeconds = windowSeconds
    }

    /// Total tokens across transcripts modified within the window. Potentially
    /// heavy (scans/parses many files on first call) — call off the main thread.
    func total(now: Date = Date()) -> Double {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: keys
        ) else { return 0 }

        var sum: Double = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let mtime = values?.contentModificationDate,
                  now.timeIntervalSince(mtime) <= windowSeconds else { continue }
            if let cached = cache[url.path], cached.mtime == mtime {
                sum += cached.tokens
                continue
            }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let tokens = Self.sumAllTokens(in: data)
            cache[url.path] = (mtime, tokens)
            sum += tokens
        }
        return sum
    }

    /// Sum of every message's `input + output + cache_creation + cache_read`
    /// (everything, per the user's choice). Loose per-line parsing.
    static func sumAllTokens(in data: Data) -> Double {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        var total: Double = 0
        text.enumerateLines { line, _ in
            guard
                let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { return }
            for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                total += (usage[key] as? NSNumber)?.doubleValue ?? 0
            }
        }
        return total
    }
}
