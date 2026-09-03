import Foundation

/// The two fixed roles in a battle. Roles are stable across both peers (they're
/// decided by who initiated the challenge), so a battle simulated from the same
/// seed produces an identical script and winner on *both* machines — nobody has
/// to trust the other side's rendering. Each app maps "am I the challenger or
/// the accepter?" onto its own side of the screen at render time.
enum BattleRole: String, Codable {
    case challenger
    case accepter

    var opponent: BattleRole { self == .challenger ? .accepter : .challenger }
}

/// One exchange in the scripted battle: `attacker` fires, dealing `damage`.
struct BattleRound: Equatable {
    let attacker: BattleRole
    let damage: Int
}

/// The full deterministic result of one battle. `rounds` is the blow-by-blow
/// used to drive the on-screen projectile animation; `winner` is who's left
/// standing. Both peers compute this identically from the shared seed.
struct BattleOutcome: Equatable {
    let rounds: [BattleRound]
    let winner: BattleRole
    let startHP: Int
}

/// Tiny seeded PRNG (xorshift64*), used instead of `UInt64.random` so both
/// peers get the *same* sequence from the same seed. `Int.random`/`Math.random`
/// would diverge between machines — the whole point is a shared, reproducible
/// battle script from a single number sent over the wire.
struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift64* dies on a zero state — nudge it to a fixed nonzero constant.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }

    /// Uniform-ish int in `range` (small ranges, modulo bias is negligible here).
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// Simulate a full battle from `seed`. Attacker alternates each round (classic
/// Digimon back-and-forth), damage is 1–2 per hit, both start at `startHP`.
/// The battle ends the instant one side hits 0 HP, so the last attacker is the
/// winner. Deterministic: same seed in → same `BattleOutcome` out, on any machine.
func simulateBattle(seed: UInt64, startHP: Int = 6) -> BattleOutcome {
    var rng = DeterministicRNG(seed: seed)
    var hp: [BattleRole: Int] = [.challenger: startHP, .accepter: startHP]
    var rounds: [BattleRound] = []

    // Coin-flip who strikes first, then strictly alternate.
    var attacker: BattleRole = rng.int(in: 0...1) == 0 ? .challenger : .accepter

    // The `< 200` guard is a pure safety net against a logic bug looping forever;
    // with 1–2 damage on 6 HP a real battle resolves in a handful of rounds.
    while hp[.challenger]! > 0 && hp[.accepter]! > 0 && rounds.count < 200 {
        let damage = rng.int(in: 1...2)
        let target = attacker.opponent
        hp[target]! -= damage
        rounds.append(BattleRound(attacker: attacker, damage: damage))
        attacker = target
    }

    // Whoever landed the final blow wins. (rounds is never empty: startHP >= 1.)
    let winner = rounds.last?.attacker ?? .challenger
    return BattleOutcome(rounds: rounds, winner: winner, startHP: startHP)
}
