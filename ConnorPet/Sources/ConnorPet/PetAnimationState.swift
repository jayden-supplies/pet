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
}

/// One entry read from `last-status.json`'s `entries` map — a single agent pane,
/// which may belong to any Orca project/worktree currently open.
struct AgentStatusEntry {
    let paneKey: String
    let state: String // "working" | "blocked" | "waiting" | "done"
    let workingMode: String?
    let worktreeId: String?
    let updatedAt: Double // ms epoch
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

/// Ported from `usePetPointerInteraction.ts` / `nextPetDragAnimation`.
func nextPetDragAnimation(current: PetDragDirection?, deltaX: CGFloat) -> (direction: PetDragDirection?, accepted: Bool) {
    if deltaX >= 4 { return (.right, true) }
    if deltaX <= -4 { return (.left, true) }
    return (current, false)
}
