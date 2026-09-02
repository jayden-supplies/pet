import Foundation

/// Headless integration test for the LAN battle handshake, run via
/// `CONNORPET_SELFTEST=battle swift run`. Spins up two `BattleService`s in one
/// process (as if two Macs on the same Wi-Fi), has A discover B over Bonjour,
/// challenge it, B auto-accept, and then asserts both sides computed the *same*
/// battle (agreeing winner, opposite roles, correct opponent pet). Prints
/// `SELFTEST PASS`/`SELFTEST FAIL` and exits — never returns.
func runBattleSelfTest() -> Never {
    print("[selftest] starting LAN battle handshake test…")

    let serviceA = BattleService(displayName: "TesterA", petSlug: "totodile")
    let serviceB = BattleService(displayName: "TesterB", petSlug: "charmander")

    var resultA: (role: BattleRole, outcome: BattleOutcome, oppName: String, oppPet: String)?
    var resultB: (role: BattleRole, outcome: BattleOutcome, oppName: String, oppPet: String)?
    var challenged = false

    func fail(_ why: String) -> Never {
        print("SELFTEST FAIL: \(why)")
        exit(1)
    }

    func evaluate() {
        guard let a = resultA, let b = resultB else { return }

        var problems: [String] = []
        if a.role != .challenger { problems.append("A should be challenger, got \(a.role)") }
        if b.role != .accepter { problems.append("B should be accepter, got \(b.role)") }
        if a.outcome != b.outcome { problems.append("outcomes differ (seed desync)") }
        if a.outcome.winner != b.outcome.winner { problems.append("winners disagree: \(a.outcome.winner) vs \(b.outcome.winner)") }
        if a.oppName != "TesterB" { problems.append("A sees wrong opponent name: \(a.oppName)") }
        if b.oppName != "TesterA" { problems.append("B sees wrong opponent name: \(b.oppName)") }
        if a.oppPet != "charmander" { problems.append("A sees wrong opponent pet: \(a.oppPet)") }
        if b.oppPet != "totodile" { problems.append("B sees wrong opponent pet: \(b.oppPet)") }

        guard problems.isEmpty else { fail(problems.joined(separator: "; ")) }

        let winnerName = a.outcome.winner == .challenger ? "TesterA" : "TesterB"
        print("[selftest] both sides agree: \(a.outcome.rounds.count) rounds, winner = \(a.outcome.winner) (\(winnerName))")
        print("SELFTEST PASS")
        exit(0)
    }

    serviceB.onIncomingChallenge = { fromName, respond in
        print("[selftest] B received challenge from \(fromName) → accepting")
        respond(true)
    }
    serviceA.onBattleStart = { role, outcome, oppName, oppPet in
        print("[selftest] A battle start: role=\(role) opp=\(oppName)/\(oppPet)")
        resultA = (role, outcome, oppName, oppPet)
        evaluate()
    }
    serviceB.onBattleStart = { role, outcome, oppName, oppPet in
        print("[selftest] B battle start: role=\(role) opp=\(oppName)/\(oppPet)")
        resultB = (role, outcome, oppName, oppPet)
        evaluate()
    }
    serviceA.onPeersChanged = { peers in
        guard !challenged, let b = peers.first(where: { $0.id == serviceB.instanceID }) else { return }
        challenged = true
        print("[selftest] A discovered B (\(b.name)) → challenging")
        serviceA.challenge(b) { result in
            print("[selftest] A challenge result: \(result)")
            if case .failed = result { fail("challenge failed at transport layer") }
        }
    }

    serviceA.start()
    serviceB.start()

    // Hard timeout: if discovery or the handshake never completes, don't hang CI.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        fail("timed out after 20s (resultA=\(resultA != nil), resultB=\(resultB != nil), challenged=\(challenged))")
    }

    dispatchMain()
}
