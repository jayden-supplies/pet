import AppKit

/// Helpers for the one macOS permission this app can benefit from: **Full Disk
/// Access**. Only the Claude Desktop source uses it — reading macOS's
/// Notification Center DB is how it detects "Claude finished a turn" from the
/// desktop app's completion banner and shows 헤롱헤롱 (see
/// `ClaudeDesktopStatusWatcher` / `NotificationCenterDB`). Without the grant the
/// desktop source still works, just falling back to CPU-only done detection.
///
/// The app can't grant this itself — macOS requires the user to flip it in
/// System Settings and relaunch — so all we can do is detect the state and open
/// the right settings pane. The menu action in `AppDelegate` drives both.
enum FullDiskAccess {
    /// Whether the app can read the Notification Center DB — our proxy for "Full
    /// Disk Access is granted". Cheap enough to call while rebuilding the menu.
    static func isGranted() -> Bool {
        NotificationCenterDB()?.isReadable ?? false
    }

    /// Opens System Settings straight to Privacy & Security ▸ Full Disk Access.
    /// The URL scheme is stable across the old System Preferences and the newer
    /// System Settings, so it lands on the right pane on both.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
