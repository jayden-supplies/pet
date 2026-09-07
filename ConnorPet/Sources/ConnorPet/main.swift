import AppKit

// Headless LAN-battle handshake test: `CONNORPET_SELFTEST=battle swift run`.
// Runs two BattleServices in-process and verifies discovery → challenge →
// accept → agreed outcome, then exits. Never returns.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "battle" {
    runBattleSelfTest()
}

// 노려보기 알림에 뜨는 펫 얼굴: `CONNORPET_SELFTEST=portrait swift run`.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "portrait" {
    runPortraitSelfTest()
}

// 퀘스트 축하 말풍선이 겹치지 않고 하나씩 뜨는지: `CONNORPET_SELFTEST=celebrate swift run`.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "celebrate" {
    runCelebrationSelfTest()
}

// 퀘스트 지급 규칙과 실제 조회: `CONNORPET_SELFTEST=quest swift run`.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "quest" {
    runQuestSelfTest()
}

// 지시한 모션이 시간이 지나면 스스로 풀리는지: `CONNORPET_SELFTEST=pin swift run`.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "pin" {
    runPinReleaseSelfTest()
}

// Headless Claude Code hook-installer test: `CONNORPET_SELFTEST=hooks swift run`.
// Runs install/idempotent-install/uninstall against a throwaway home, asserting
// foreign hooks are preserved. Never returns.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "hooks" {
    runHookInstallSelfTest()
}

// Headless modal auto-dismiss test: `CONNORPET_SELFTEST=modal swift run`.
// Verifies the challenge modal's 10s-style timeout fires during the modal loop
// (see ModalTimeoutSelfTest). Never returns.
if ProcessInfo.processInfo.environment["CONNORPET_SELFTEST"] == "modal" {
    runModalTimeoutSelfTest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
