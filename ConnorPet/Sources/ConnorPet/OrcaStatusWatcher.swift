import Foundation

/// Decodes the subset of Orca's persisted `last-status.json` entry shape
/// (`PersistedAgentHookEventPayload` in `server-types.ts`) that we need.
/// `JSONDecoder` ignores unknown keys by default, so extra fields Orca writes
/// (prompt, toolName, model, ...) are simply skipped.
private struct RawPersistedEntry: Codable {
    let state: String
    let workingMode: String?
    let worktreeId: String?
    let receivedAt: Double?
    let stateStartedAt: Double?
}

private struct RawLastStatusFile: Codable {
    let version: Int
    let entries: [String: RawPersistedEntry]
}

/// Polls Orca's on-disk agent-status file — the exact file Orca itself uses
/// to restore state across restarts (`src/main/agent-hooks/server/server-persistence.ts`)
/// — and republishes the aggregate pet animation whenever it changes.
///
/// Orca debounces writes to this file at 250ms, so a 1s poll is comfortably
/// within its real update cadence without needing FSEvents.
final class OrcaStatusWatcher {
    private let fileURL: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastModifiedAt: Date?

    /// Agent panes whose worktree/pane closed after finishing but haven't
    /// been reviewed yet (Orca's `retainedAgentsByPaneKey`). We can't observe
    /// that in-memory renderer state from outside the app, so this is exposed
    /// for callers that want to simulate/inject it; defaults to 0.
    var retainedCount: Int = 0

    var onUpdate: ((AgentStateAnimationResult) -> Void)?

    init(pollInterval: TimeInterval = 1.0) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = appSupport.appendingPathComponent("Orca/agent-hooks/last-status.json")
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
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedAt = attrs?[.modificationDate] as? Date

        // Why: skip the JSON parse entirely when the file hasn't changed since
        // the last poll — this runs every second for the app's whole lifetime.
        if let modifiedAt = modifiedAt, let lastModifiedAt = lastModifiedAt, modifiedAt <= lastModifiedAt {
            return
        }
        lastModifiedAt = modifiedAt

        guard let data = try? Data(contentsOf: fileURL) else {
            // Orca not installed, never launched, or no agent activity yet —
            // treat as "no entries" rather than crashing/hanging.
            publish(entries: [])
            return
        }
        guard let file = try? JSONDecoder().decode(RawLastStatusFile.self, from: data) else {
            publish(entries: [])
            return
        }

        let now = Date().timeIntervalSince1970 * 1000
        let entries: [AgentStatusEntry] = file.entries.map { paneKey, raw in
            AgentStatusEntry(
                paneKey: paneKey,
                state: raw.state,
                workingMode: raw.workingMode,
                worktreeId: raw.worktreeId,
                updatedAt: raw.receivedAt ?? now
            )
        }
        publish(entries: entries)
    }

    private func publish(entries: [AgentStatusEntry]) {
        let now = Date().timeIntervalSince1970 * 1000
        let result = agentStateAnimation(entries: entries, retainedCount: retainedCount, now: now)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
