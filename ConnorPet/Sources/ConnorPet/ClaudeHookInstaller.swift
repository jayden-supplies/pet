import Foundation

/// Installs/removes the connor-pet Claude Code hooks from `~/.claude/settings.json`
/// straight from the app — the in-app equivalent of running
/// `scripts/install_claude_hooks.py`. This exists because a DMG-installed
/// `ConnorPet.app` has no repo checkout to run that script from: the menu action
/// (see AppDelegate `toggleClaudeHooks`) copies the bundled hook handler to a
/// stable path and wires the same six hook events that the script does.
///
/// Without these hooks the Claude Code source only distinguishes busy/idle; the
/// hooks are the *only* signal for 얼음(blocked)/헤롱헤롱(done) — see
/// `ClaudeCodeStatusWatcher` and README "Claude Code 훅으로 얼음/헤롱헤롱까지 보기".
///
/// This touches a **global** file affecting every Claude Code session on the
/// machine, so the menu action asks for explicit confirmation before calling in.
enum ClaudeHookInstaller {
    /// The Claude Code hook events we register, each mapped to the state argument
    /// passed to `claude_hook_status.py`. Kept in the same order and mapping as
    /// `scripts/install_claude_hooks.py`'s HOOK_EVENTS.
    private static let hookEvents: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PermissionRequest", "blocked"),
        ("Notification", "blocked"),
        ("Stop", "done"),
        ("SessionEnd", "remove"),
    ]

    enum InstallError: LocalizedError {
        case bundledScriptMissing
        case settingsUnreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledScriptMissing:
                return "앱 번들에서 훅 스크립트를 찾지 못했습니다."
            case .settingsUnreadable(let path):
                return "설정 파일을 읽지 못했습니다: \(path)"
            case .writeFailed(let detail):
                return "설정 파일 쓰기에 실패했습니다: \(detail)"
            }
        }
    }

    private static var homeDir: URL {
        // Test hook: point the installer at a throwaway home so the headless
        // self-test (CONNORPET_SELFTEST=hooks) never touches the real
        // ~/.claude/settings.json. Unset in normal runs.
        if let override = ProcessInfo.processInfo.environment["CONNORPET_HOOK_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var settingsURL: URL {
        homeDir.appendingPathComponent(".claude/settings.json")
    }

    /// Where the bundled hook handler is copied to. A stable, app-independent
    /// path so the hook keeps working even if the .app is moved or updated
    /// (install re-copies it, so a newer app refreshes the script in place).
    private static var installedScriptURL: URL {
        homeDir.appendingPathComponent(".claude/connor-pet/claude_hook_status.py")
    }

    /// The command string written into settings.json for a given state. The
    /// path is quoted in case the home directory contains spaces.
    private static func command(for state: String) -> String {
        "python3 \"\(installedScriptURL.path)\" \(state)"
    }

    /// We recognize our own hook entries purely by the script filename in the
    /// command — same test as the Python installer, so entries added by either
    /// path are detected (and cleanly removed) by the other.
    private static func isConnorPetEntry(_ hook: [String: Any]) -> Bool {
        (hook["type"] as? String) == "command"
            && ((hook["command"] as? String)?.contains("claude_hook_status.py") ?? false)
    }

    /// True when at least one of our hook entries is present in settings.json.
    /// Drives the menu item's checkmark.
    static func isInstalled() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (event, _) in hookEvents {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            for block in blocks {
                let entries = block["hooks"] as? [[String: Any]] ?? []
                if entries.contains(where: isConnorPetEntry) { return true }
            }
        }
        return false
    }

    // MARK: - Install / uninstall

    /// Copies the bundled hook handler to a stable path and merges our six hook
    /// blocks into settings.json. Never touches existing (non-ours) hook blocks,
    /// and is safe to re-run — a block already carrying our entry is left as-is.
    @discardableResult
    static func install() throws -> [String] {
        try installBundledScript()

        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []

        for (event, state) in hookEvents {
            var blocks = hooks[event] as? [[String: Any]] ?? []

            // Never merge into an existing block: a block scoped by a matcher
            // (e.g. {"matcher": "Bash", ...}) only fires for that matcher, so
            // appending there would silently narrow our hook. Always add our own
            // dedicated block instead. (Mirrors install_claude_hooks.py.)
            let alreadyInstalled = blocks.contains { block in
                (block["hooks"] as? [[String: Any]] ?? []).contains(where: isConnorPetEntry)
            }
            if alreadyInstalled { continue }

            var newBlock: [String: Any] = [
                "hooks": [["type": "command", "command": command(for: state)]]
            ]
            if event == "PreToolUse" || event == "PostToolUse" {
                newBlock["matcher"] = "*" // explicit "all tools", matching Orca's convention
            }
            blocks.append(newBlock)
            hooks[event] = blocks
            added.append(event)
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
        return added
    }

    /// Removes only the entries we added, dropping any block that becomes empty
    /// as a result (i.e. blocks we created solely for our hook). Leaves the
    /// copied script file in place — harmless, and a re-install reuses it.
    @discardableResult
    static func uninstall() throws -> [String] {
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return [] }
        var removed: [String] = []

        for event in Array(hooks.keys) {
            guard let blocks = hooks[event] as? [[String: Any]] else { continue }
            var remainingBlocks: [[String: Any]] = []
            for var block in blocks {
                let blockHooks = block["hooks"] as? [[String: Any]] ?? []
                let kept = blockHooks.filter { !isConnorPetEntry($0) }
                if kept.count != blockHooks.count {
                    removed.append(event)
                    if kept.isEmpty {
                        continue // a block we created solely for our hook — drop it entirely
                    }
                    block["hooks"] = kept
                }
                remainingBlocks.append(block)
            }
            if remainingBlocks.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remainingBlocks
            }
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
        return Array(Set(removed))
    }

    // MARK: - Bundled script

    private static func installBundledScript() throws {
        guard let bundledURL = AppDelegate.resourceBundle.url(
            forResource: "claude_hook_status", withExtension: "py", subdirectory: "hooks"
        ) else {
            throw InstallError.bundledScriptMissing
        }
        let fm = FileManager.default
        let dest = installedScriptURL
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: bundledURL, to: dest)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - settings.json read/write

    /// Reads settings.json as a loose JSON object, preserving every key we don't
    /// touch. An empty/missing file is treated as `{}` — same as the Python
    /// installer — so a first-time user with no settings.json still installs.
    private static func loadSettings() throws -> [String: Any] {
        let path = settingsURL.path
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL) else {
            throw InstallError.settingsUnreadable(path)
        }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw InstallError.settingsUnreadable(path)
        }
        return dict
    }

    /// Backs up the existing file (timestamped), then writes atomically via a
    /// temp file + replace — mirroring save_settings() in the Python installer.
    private static func saveSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            if fm.fileExists(atPath: settingsURL.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = settingsURL.appendingPathExtension("connor-pet-backup.\(stamp)")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: settingsURL, to: backup)
            }

            var data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            data.append(0x0A) // trailing newline, like the Python writer

            let tmp = settingsURL.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: settingsURL.path) {
                _ = try fm.replaceItemAt(settingsURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: settingsURL)
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
