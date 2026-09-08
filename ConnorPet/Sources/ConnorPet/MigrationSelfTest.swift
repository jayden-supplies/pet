import Foundation

/// `CONNORPET_SELFTEST=migration swift run`. 실행 방식이 바뀌었을 때 경험치를 옮겨
/// 오는 규칙을 확인한다.
///
/// 실제로 났던 사고를 재현한다 — dmg 로 갈아타자 경험치가 통째로 사라진 것처럼
/// 보였다. 값은 예전 도메인에 남아 있었고, `UserDefaults` 가 어느 파일을 쓰는지는
/// 번들 식별자가 정하기 때문이었다.
///
/// **사용자의 실제 도메인은 건드리지 않는다** — 검증용 도메인을 만들어 돌리고 지운다.
///
/// Prints `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runMigrationSelfTest() -> Never {
    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    let oldName = "connor-pet.selftest.old"
    let newerName = "connor-pet.selftest.newer"
    let targetName = "connor-pet.selftest.target"
    let names = [oldName, newerName, targetName]

    func wipe() {
        for n in names { UserDefaults().removePersistentDomain(forName: n) }
    }
    func failClean(_ why: String) -> Never { wipe(); fail(why) }

    wipe()
    guard let old = UserDefaults(suiteName: oldName),
          let newer = UserDefaults(suiteName: newerName),
          let target = UserDefaults(suiteName: targetName) else { failClean("검증용 도메인을 못 만들었다") }

    // 예전 두 도메인에 서로 다른 기록이 남아 있는 상황.
    old.set(["charmander": 12_690_275.0], forKey: "petTokens")
    old.set(["gh:a#1", "linear:T-1"], forKey: "questCreditedIDs")
    newer.set(["charmander": 77_932_312.0, "squirtle": 2_892.0], forKey: "petTokens")
    newer.set(["gh:a#1", "gh:a#2"], forKey: "questCreditedIDs")

    guard let moved = XPMigration.runIfNeeded(into: target, from: [newerName, oldName]) else {
        failClean("가져오지 않았다")
    }
    print("[selftest] \(moved)")

    let tokens = target.dictionary(forKey: "petTokens") as? [String: Double] ?? [:]
    // 같은 펫이 양쪽에 있으면 많이 쌓인 쪽이 남아야 한다 — 적은 쪽으로 덮이면 손해다.
    guard tokens["charmander"] == 77_932_312 else {
        failClean("파이리 경험치가 큰 쪽이 아니다: \(tokens["charmander"] ?? -1)")
    }
    guard tokens["squirtle"] == 2_892 else { failClean("꼬부기 경험치를 놓쳤다") }
    print("[selftest] 펫마다 가장 많이 쌓인 값을 가져왔다")

    // 이미 지급한 퀘스트 기록도 합쳐야 한다. 안 그러면 예전 PR·티켓이 다시 새것으로
    // 잡혀 경험치가 두 번 들어간다.
    let ids = Set(target.stringArray(forKey: "questCreditedIDs") ?? [])
    guard ids == ["gh:a#1", "gh:a#2", "linear:T-1"] else {
        failClean("퀘스트 기록이 합쳐지지 않았다: \(ids.sorted())")
    }
    guard target.bool(forKey: "questBaselineTaken") else { failClean("기준선 표시가 안 됐다") }
    print("[selftest] 지급 기록 \(ids.count)건을 합쳤다 (중복 지급 방지)")

    // 두 번 돌아도 안 된다.
    target.set(["charmander": 1.0], forKey: "petTokens")
    guard XPMigration.runIfNeeded(into: target, from: [newerName, oldName]) == nil else {
        failClean("두 번째 실행에서 또 가져왔다")
    }
    guard (target.dictionary(forKey: "petTokens") as? [String: Double])?["charmander"] == 1 else {
        failClean("두 번째 실행이 값을 덮어썼다")
    }
    print("[selftest] 두 번째 실행은 아무것도 하지 않는다")

    // 이미 쓰고 있던 사람의 값은 절대 덮지 않는다.
    let fresh = "connor-pet.selftest.inuse"
    UserDefaults().removePersistentDomain(forName: fresh)
    guard let inUse = UserDefaults(suiteName: fresh) else { failClean("도메인 생성 실패") }
    inUse.set(["charmander": 500.0], forKey: "petTokens")
    guard XPMigration.runIfNeeded(into: inUse, from: [newerName, oldName]) == nil else {
        UserDefaults().removePersistentDomain(forName: fresh)
        failClean("쓰고 있던 값을 덮어썼다")
    }
    guard (inUse.dictionary(forKey: "petTokens") as? [String: Double])?["charmander"] == 500 else {
        UserDefaults().removePersistentDomain(forName: fresh)
        failClean("쓰고 있던 값이 바뀌었다")
    }
    UserDefaults().removePersistentDomain(forName: fresh)
    print("[selftest] 이미 쌓인 값이 있으면 손대지 않는다")

    // ── 손으로 가져오기(설정 창 버튼)가 쓰는 조각들 ──
    //
    // 자동 이관은 "지금 도메인이 비어 있을 때" 만 돈다. 이미 조금 쌓인 뒤에
    // 알아차린 사람은 그 조건에 걸리지 않아 버튼이 필요하다.
    let found = XPMigration.legacyTokens(from: [newerName, oldName])
    guard found["charmander"] == 77_932_312, found["squirtle"] == 2_892 else {
        failClean("예전 기록 훑기가 틀렸다: \(found)")
    }
    print("[selftest] 예전 기록 훑기: 펫 \(found.count)종")

    // 0 이하인 값은 "가져올 게 있다" 로 세지 않는다 — 버튼이 헛되이 보인다.
    let empty = "connor-pet.selftest.zero"
    UserDefaults().removePersistentDomain(forName: empty)
    UserDefaults(suiteName: empty)?.set(["charmander": 0.0], forKey: "petTokens")
    guard XPMigration.legacyTokens(from: [empty]).isEmpty else {
        UserDefaults().removePersistentDomain(forName: empty)
        failClean("0 인 기록을 가져올 것으로 셌다")
    }
    UserDefaults().removePersistentDomain(forName: empty)
    print("[selftest] 0 짜리 기록은 가져올 것으로 세지 않는다")

    // 퀘스트 기록 합치기: 이미 있는 것은 다시 넣지 않고, 새것만 더한다.
    let questTarget = "connor-pet.selftest.quests"
    UserDefaults().removePersistentDomain(forName: questTarget)
    guard let qt = UserDefaults(suiteName: questTarget) else { failClean("도메인 생성 실패") }
    qt.set(["gh:a#1"], forKey: "questCreditedIDs")
    let added = XPMigration.mergeQuestIDs(into: qt, from: [newerName, oldName])
    let merged = Set(qt.stringArray(forKey: "questCreditedIDs") ?? [])
    UserDefaults().removePersistentDomain(forName: questTarget)
    guard added == 2, merged == ["gh:a#1", "gh:a#2", "linear:T-1"] else {
        failClean("퀘스트 합치기가 틀렸다: 추가 \(added), 결과 \(merged.sorted())")
    }
    print("[selftest] 퀘스트 기록 합치기: 새것 \(added)건만 더했다")

    wipe()
    print("SELFTEST PASS")
    exit(0)
}
