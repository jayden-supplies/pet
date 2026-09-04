import AppKit

// Headless LAN-battle handshake test: `CONNORPET_SELFTEST=battle swift run`.
// Runs two BattleServices in-process and verifies discovery → challenge →
// accept → agreed outcome, then exits. Never returns.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "battle" {
    runBattleSelfTest()
}

// Headless Claude Code hook-installer test: `CONNORPET_SELFTEST=hooks swift run`.
// Runs install/idempotent-install/uninstall against a throwaway home, asserting
// foreign hooks are preserved. Never returns.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "hooks" {
    runHookInstallSelfTest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
