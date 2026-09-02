import Foundation

/// Mirrors Orca's `pet-agent-state.ts` PetAnimationName union.
enum PetAnimationName: String, CaseIterable {
    case idle
    case running
    case waiting
    case review
    case jumping
    case waving
    case failed
    case runningRight = "running-right"
    case runningLeft = "running-left"

    /// Korean label for the right-click motion menu.
    var koreanLabel: String {
        switch self {
        case .idle:         return "잠듦 (Zzz)"
        case .running:      return "달리기"
        case .waiting:      return "얼음"
        case .review:       return "하트"
        case .jumping:      return "점프"
        case .waving:       return "말하기"
        case .failed:       return "실패"
        case .runningRight: return "오른쪽으로 달리기"
        case .runningLeft:  return "왼쪽으로 달리기"
        }
    }
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
    let state: String // "working" | "blocked" | "waiting" | "done" | "failed"
    let workingMode: String?
    let worktreeId: String?
    let updatedAt: Double // ms epoch
}

/// Freshness gate, ported from `agent-status-types.ts` (`AGENT_STATUS_STALE_AFTER_MS`).
let agentStatusStaleAfterMs: Double = 30 * 60 * 1000

/// How long each transient state stays meaningful before it decays (see
/// `decayStaleStates`). These live here, not in the hook script, because a
/// hook only fires while a session is alive — once the last one exits nothing
/// writes the file again, so anything time-based has to be judged by the
/// reader. The watchers already poll, so they get this for free.
enum AgentStatusDecay {
    /// A failed tool is worth a glance, not a permanent mood.
    static let failedMs: Double = 30 * 1000
    /// "작업 끝" 이후 이만큼 지나면 잠든다 — 유휴 5분.
    static let doneMs: Double = 5 * 60 * 1000
    /// Normal work keeps firing hooks every few seconds; this much silence
    /// means the session is wedged or died without a SessionEnd, so stop
    /// showing it as busy.
    static let workingMs: Double = 15 * 60 * 1000
}

/// Ages transient states down a step, so the pet settles by itself instead of
/// holding whatever the last hook wrote forever.
///
///   failed  → done   (after 30s)
///   done    → idle   (after 5m)
///   working → idle   (after 15m)
///
/// Written as a pure transform over entries — same shape as
/// `suppressAcknowledgedDone` — so both status sources share it and it can be
/// reasoned about without a live file or a running session.
func decayStaleStates(_ entries: [AgentStatusEntry], now: Double) -> [AgentStatusEntry] {
    entries.map { entry in
        let age = now - entry.updatedAt
        let decayed: String
        switch entry.state {
        case "failed"  where age > AgentStatusDecay.failedMs + AgentStatusDecay.doneMs: decayed = "idle"
        case "failed"  where age > AgentStatusDecay.failedMs:                           decayed = "done"
        case "done"    where age > AgentStatusDecay.doneMs:                             decayed = "idle"
        case "working" where age > AgentStatusDecay.workingMs:                          decayed = "idle"
        default: return entry
        }
        return AgentStatusEntry(
            paneKey: entry.paneKey,
            state: decayed,
            workingMode: entry.workingMode,
            worktreeId: entry.worktreeId,
            updatedAt: entry.updatedAt
        )
    }
}

func isEntryFresh(_ entry: AgentStatusEntry, now: Double, staleAfterMs: Double = agentStatusStaleAfterMs) -> Bool {
    now - entry.updatedAt <= staleAfterMs
}

struct AgentStateAnimationTrace {
    let line: String
}

struct AgentStateAnimationResult {
    let animation: PetAnimationName
    let trace: [AgentStateAnimationTrace]
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
    var hasFailed = false

    for entry in entries {
        guard isEntryFresh(entry, now: now, staleAfterMs: staleAfterMs) else {
            trace.append(.init(line: "\(entry.paneKey): stale → skipped"))
            continue
        }
        if entry.state == "blocked" || entry.state == "waiting" {
            trace.append(.init(line: "\(entry.paneKey): \(entry.state) → top-priority rule, short-circuit"))
            return AgentStateAnimationResult(animation: .waiting, trace: trace)
        }
        // "failed" is not one of Orca's own states — it is an extension for the
        // Claude Code bridge, which reports a tool that came back with an error.
        // It ranks below waiting (which needs the user to act right now) but
        // above working, so a failure is not hidden by other panes still running.
        if entry.state == "failed" {
            hasFailed = true
            trace.append(.init(line: "\(entry.paneKey): failed → candidate"))
        } else if entry.state == "working", entry.workingMode != "monitoring" {
            hasWorking = true
            trace.append(.init(line: "\(entry.paneKey): working → candidate"))
        } else if entry.state == "done" {
            hasDone = true
            trace.append(.init(line: "\(entry.paneKey): done → candidate"))
        }
    }

    if hasFailed {
        return AgentStateAnimationResult(animation: .failed, trace: trace)
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
