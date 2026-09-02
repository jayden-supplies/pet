import Foundation

/// Mirrors Orca's `pet-agent-state.ts` PetAnimationName union.
enum PetAnimationName: String {
    case idle
    case running
    case waiting
    case review
    case jumping
    case runningRight = "running-right"
    case runningLeft = "running-left"
}

enum PetDragDirection {
    case right
    case left
}

/// Common interface for the two interchangeable status sources the menu-bar
/// picker can select between (Orca's last-status.json vs. Claude Code's own
/// session files) — AppDelegate holds exactly one active instance at a time.
protocol AgentStatusWatching: AnyObject {
    var onUpdate: ((AgentStateAnimationResult) -> Void)? { get set }
    func start()
    func stop()
    /// Called when the user notices the pet (currently: on hover) — suppresses
    /// any "done"/review state observed *before* this call until a newer one
    /// arrives, so review doesn't linger forever once you've actually seen it.
    func acknowledgeDone()
}

/// One entry read from `last-status.json`'s `entries` map — a single agent pane,
/// which may belong to any Orca project/worktree currently open.
struct AgentStatusEntry {
    let paneKey: String
    let state: String // "working" | "blocked" | "waiting" | "done"
    let workingMode: String?
    let worktreeId: String?
    let updatedAt: Double // ms epoch
    /// Path to this pane/session's Claude Code transcript JSONL, when known —
    /// the only on-disk source of token usage (see TranscriptTokenReader).
    /// Orca supplies it directly (`providerSession.transcriptPath`); the Claude
    /// Code source resolves it by globbing on sessionId. `var` with a default
    /// so existing call sites that don't set it keep compiling.
    var transcriptPath: String? = nil
}

/// Freshness gate, ported from `agent-status-types.ts` (`AGENT_STATUS_STALE_AFTER_MS`).
let agentStatusStaleAfterMs: Double = 30 * 60 * 1000

func isEntryFresh(_ entry: AgentStatusEntry, now: Double, staleAfterMs: Double = agentStatusStaleAfterMs) -> Bool {
    now - entry.updatedAt <= staleAfterMs
}

struct AgentStateAnimationTrace {
    let line: String
}

struct AgentStateAnimationResult {
    let animation: PetAnimationName
    let trace: [AgentStateAnimationTrace]
    /// Aggregate token usage across all live panes/sessions, filled in by each
    /// watcher's `publish` (0 when no transcript is readable). Drives the XP
    /// bar + evolution — see XPModel. Defaulted so `agentStateAnimation`'s
    /// return sites don't need to thread it through.
    var totalTokens: Double = 0
}

/// Ported verbatim (in spirit) from `pet-agent-state.ts`'s `agentStateAnimation()`.
/// Scans every open agent pane across every project; the single most-urgent
/// state wins, short-circuiting the instant a blocked/waiting pane is found.
func agentStateAnimation(
    entries: [AgentStatusEntry],
    retainedCount: Int,
    now: Double,
    staleAfterMs: Double = agentStatusStaleAfterMs
) -> AgentStateAnimationResult {
    var trace: [AgentStateAnimationTrace] = []
    var hasWorking = false
    var hasDone = false

    for entry in entries {
        guard isEntryFresh(entry, now: now, staleAfterMs: staleAfterMs) else {
            trace.append(.init(line: "\(entry.paneKey): stale → skipped"))
            continue
        }
        if entry.state == "blocked" || entry.state == "waiting" {
            trace.append(.init(line: "\(entry.paneKey): \(entry.state) → top-priority rule, short-circuit"))
            return AgentStateAnimationResult(animation: .waiting, trace: trace)
        }
        if entry.state == "working", entry.workingMode != "monitoring" {
            hasWorking = true
            trace.append(.init(line: "\(entry.paneKey): working → candidate"))
        } else if entry.state == "done" {
            hasDone = true
            trace.append(.init(line: "\(entry.paneKey): done → candidate"))
        }
    }

    if hasWorking {
        return AgentStateAnimationResult(animation: .running, trace: trace)
    }
    if hasDone || retainedCount > 0 {
        return AgentStateAnimationResult(animation: .review, trace: trace)
    }
    return AgentStateAnimationResult(animation: .idle, trace: trace)
}

/// Downgrades "done" entries the user has already acknowledged (see
/// `AgentStatusWatching.acknowledgeDone()`) to "idle" so review doesn't
/// reappear on the next poll purely because the underlying source (Orca's
/// file, or our own hook-authored one) hasn't moved past "done" yet — it only
/// comes back once a *newer* done event lands (updatedAt > acknowledgedAtMs).
func suppressAcknowledgedDone(_ entries: [AgentStatusEntry], acknowledgedAtMs: Double) -> [AgentStatusEntry] {
    entries.map { entry in
        guard entry.state == "done", entry.updatedAt <= acknowledgedAtMs else { return entry }
        return AgentStatusEntry(
            paneKey: entry.paneKey,
            state: "idle",
            workingMode: entry.workingMode,
            worktreeId: entry.worktreeId,
            updatedAt: entry.updatedAt
        )
    }
}

/// Ported from `usePetPointerInteraction.ts` / `nextPetDragAnimation`.
func nextPetDragAnimation(current: PetDragDirection?, deltaX: CGFloat) -> (direction: PetDragDirection?, accepted: Bool) {
    if deltaX >= 4 { return (.right, true) }
    if deltaX <= -4 { return (.left, true) }
    return (current, false)
}
