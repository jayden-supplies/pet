import AppKit
import Foundation

/// Inputs to the Claude *desktop app* animation decision — deliberately a plain
/// value type so the mapping is unit-testable without any process/DB/AX access.
struct ClaudeDesktopInput: Equatable {
    /// The Claude.app process is running at all.
    let running: Bool
    /// Claude.app is the frontmost (Dock-selected) app right now.
    let frontmost: Bool
    /// A response is actively streaming (renderer CPU above threshold).
    let generating: Bool
    /// A completion notification arrived that the user hasn't acknowledged
    /// (by hovering the pet) yet.
    let donePending: Bool
}

/// Maps the Claude desktop app's observable state to a pet animation. Priority,
/// highest first — this is the whole behavioral contract, kept pure on purpose:
///
/// 1. not running            → 잠듬 (idle)          — nothing to react to
/// 2. generating             → 달리기 (running)      — response streaming now
/// 3. done, unacknowledged   → 헤롱헤롱 (review)      — "go look, it finished"
/// 4. running, backgrounded  → 얼음 (waiting)        — left on ice, not looking
/// 5. running, frontmost/idle→ 잠듬 (idle)           — you're here, nothing doing
///
/// `generating` outranks `donePending` so a *new* turn you just kicked off reads
/// as 달리기 even if the previous turn's done-notification hasn't been dismissed;
/// `donePending` outranks `waiting` so a finished background turn nudges you
/// (헤롱헤롱) instead of silently freezing (얼음).
func claudeDesktopAnimation(_ input: ClaudeDesktopInput) -> PetAnimationName {
    guard input.running else { return .idle }
    if input.generating { return .running }
    if input.donePending { return .review }
    if !input.frontmost { return .waiting }
    return .idle
}

/// Drives the pet from the Claude *desktop app* (not the CLI). Combines the two
/// signals the desktop app actually exposes — see the field docs below — and
/// republishes an aggregate animation on change, mirroring the other watchers'
/// shape so the menu-bar source picker can swap it in transparently.
///
/// - Signal 1 — "is it working": Claude's renderer CPU activity
///   (`ClaudeProcessActivity`). The Accessibility API can't see Electron web
///   content here, so CPU is the practical busy/idle proxy. The *falling edge*
///   of a sustained-busy stretch (streaming stopped) also doubles as our most
///   reliable "a turn just finished" signal → 헤롱헤롱.
/// - Signal 2 — "did it finish": a new Claude notification in macOS's
///   Notification Center DB (`NotificationCenterDB`), which needs Full Disk
///   Access. In practice the desktop app only posts these for longer/agentic
///   work, not quick chat replies, so this is a *confirming* done signal layered
///   on top of the CPU edge — either one raises 헤롱헤롱, and if the grant is
///   missing we simply fall back to the CPU edge alone.
///
/// "Done" (from either signal) latches until the user acknowledges it by
/// hovering the pet (`acknowledgeDone()`), or a safety timeout elapses, or a new
/// turn starts — mirroring the Claude Code watcher's review behavior.
final class ClaudeDesktopStatusWatcher: AgentStatusWatching {
    static let bundleID = "com.anthropic.claudefordesktop"

    private let pollInterval: TimeInterval
    private let notifCheckInterval: TimeInterval
    /// CPU fraction (of one core) above which we call it "generating".
    private let busyThreshold: Double
    /// Keep 달리기 latched for this many polls after the last busy sample, so
    /// the per-token gaps in streaming don't flicker the pet back to idle.
    private let busyStickyPolls: Int
    /// A busy stretch must last at least this many polls before its end counts
    /// as a finished turn — filters out brief CPU blips (scroll, layout) that
    /// would otherwise flash a spurious 헤롱헤롱.
    private let minGeneratingPollsForDone: Int
    /// How long a CPU-detected "done" stays latched if the user never hovers.
    private let reviewTimeout: TimeInterval

    private let activity = ClaudeProcessActivity()
    private let notifDB = NotificationCenterDB()

    private var timer: Timer?
    private var busyLatch = 0
    private var wasGenerating = false
    private var generatingRun = 0
    private var pendingDoneFromCPU = false
    private var pendingDoneDeadline: Date?

    // Notification bookkeeping (Cocoa-epoch seconds). `latest` is the newest
    // notification we've seen; `acknowledged` is the newest the user has
    // dismissed via hover. donePending == latest > acknowledged.
    private var latestNotifDate: Double = 0
    private var acknowledgedNotifDate: Double = 0
    private var notifBaselineSet = false
    private var notifCheckDeadline: Date = .distantPast
    private var loggedNotifUnavailable = false

    private var lastPublished: PetAnimationName?

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(
        pollInterval: TimeInterval = 0.5,
        notifCheckInterval: TimeInterval = 1.0,
        busyThreshold: Double = 0.15,
        busyStickyPolls: Int = 3,
        minGeneratingPollsForDone: Int = 4,
        reviewTimeout: TimeInterval = 300
    ) {
        self.pollInterval = pollInterval
        self.notifCheckInterval = notifCheckInterval
        self.busyThreshold = busyThreshold
        self.busyStickyPolls = busyStickyPolls
        self.minGeneratingPollsForDone = minGeneratingPollsForDone
        self.reviewTimeout = reviewTimeout
    }

    func start() {
        activity.reset()
        lastPublished = nil
        busyLatch = 0
        wasGenerating = false
        generatingRun = 0
        pendingDoneFromCPU = false
        pendingDoneDeadline = nil
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

    func acknowledgeDone() {
        // Everything seen so far is now "seen" — donePending clears until a
        // strictly newer notification lands or a new turn finishes.
        acknowledgedNotifDate = max(acknowledgedNotifDate, latestNotifDate)
        pendingDoneFromCPU = false
        pendingDoneDeadline = nil
    }

    private func poll() {
        let now = Date()

        let running = Self.isClaudeRunning()
        let frontmost = Self.isClaudeFrontmost()

        refreshNotificationsIfNeeded(now: now)

        // Only bother sampling CPU while Claude is alive.
        let fraction = running ? activity.sampleCPUFraction(now: now) : 0
        if fraction >= busyThreshold {
            busyLatch = busyStickyPolls
        } else if busyLatch > 0 {
            busyLatch -= 1
        }
        let generating = busyLatch > 0

        // Signal 1's falling edge = a turn just finished. Only count it if the
        // busy stretch was sustained (filters brief blips), and let a fresh turn
        // supersede a stale pending-done.
        if generating {
            generatingRun += 1
            pendingDoneFromCPU = false
            pendingDoneDeadline = nil
        } else {
            if wasGenerating, generatingRun >= minGeneratingPollsForDone {
                pendingDoneFromCPU = true
                pendingDoneDeadline = now.addingTimeInterval(reviewTimeout)
            }
            generatingRun = 0
        }
        wasGenerating = generating
        if let deadline = pendingDoneDeadline, now >= deadline {
            pendingDoneFromCPU = false
            pendingDoneDeadline = nil
        }

        // Done = either signal, cleared once acknowledged/expired above.
        let donePending = pendingDoneFromCPU || (latestNotifDate > acknowledgedNotifDate)

        let input = ClaudeDesktopInput(
            running: running,
            frontmost: frontmost,
            generating: generating,
            donePending: donePending
        )
        publish(claudeDesktopAnimation(input), input: input, cpuFraction: fraction)
    }

    private func refreshNotificationsIfNeeded(now: Date) {
        guard now >= notifCheckDeadline else { return }
        notifCheckDeadline = now.addingTimeInterval(notifCheckInterval)

        guard let db = notifDB, let latest = db.latestNotificationDate(bundleID: Self.bundleID) else {
            // DB unavailable (no Full Disk Access, or no Claude notifications
            // ever). Mark baseline so we never retroactively fire a stale done.
            if !notifBaselineSet {
                notifBaselineSet = true
                if notifDB?.isReadable != true { logNotifUnavailableOnce() }
            }
            return
        }

        if !notifBaselineSet {
            // First read: treat whatever's already there as already-seen, so a
            // days-old notification doesn't trigger 헤롱헤롱 the moment we launch.
            notifBaselineSet = true
            acknowledgedNotifDate = latest
        }
        latestNotifDate = latest
    }

    private func logNotifUnavailableOnce() {
        guard !loggedNotifUnavailable else { return }
        loggedNotifUnavailable = true
        FileHandle.standardError.write(
            "[connor-pet] claude-desktop: Notification Center DB not readable — done/헤롱헤롱 disabled. Grant Full Disk Access to enable it.\n"
                .data(using: .utf8)!
        )
    }

    private func publish(_ animation: PetAnimationName, input: ClaudeDesktopInput, cpuFraction: Double) {
        let debug = ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil
        if debug {
            let line = String(
                format: "[connor-pet] claude-desktop: run=%@ front=%@ gen=%@(cpu=%.2f) done=%@ -> %@\n",
                d(input.running), d(input.frontmost), d(input.generating), cpuFraction,
                d(input.donePending), animation.rawValue
            )
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }

        guard animation != lastPublished else { return }
        lastPublished = animation

        let result = AgentStateAnimationResult(
            animation: animation,
            trace: [AgentStateAnimationTrace(line: "claude-desktop -> \(animation.rawValue)")]
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }

    private func d(_ b: Bool) -> String { b ? "Y" : "N" }

    // MARK: - Frontmost / running (no special permission needed)

    private static func isClaudeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private static func isClaudeFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }
}
