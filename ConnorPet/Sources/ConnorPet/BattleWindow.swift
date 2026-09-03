import AppKit
import QuartzCore

/// A fullscreen, transparent, click-through overlay that hosts a battle. It's a
/// `.nonactivatingPanel` (not a plain NSWindow) so showing it never switches
/// Spaces or steals focus, and `ignoresMouseEvents` lets every click fall
/// through to whatever's underneath. The pets sit at opposite screen edges — as
/// if in different places — and the projectile flies the whole width between
/// them. Auto-closes a few seconds after the WIN/LOSE banner.
final class BattleWindow: NSPanel {
    private var onClosed: (() -> Void)?

    init(view: BattleView, onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true      // full click-through — non-intrusive overlay
        hidesOnDeactivate = false       // MANDATORY: else it vanishes when another app focuses
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view

        view.onFinished = { [weak self] in
            // Hold the WIN/LOSE banner on screen briefly, then dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self?.close() }
        }
    }

    // A click-through overlay must never become key/main — that would activate
    // the app and pull focus off whatever the user is doing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show without activating the app (so focus/Space stay put).
    func present() { orderFrontRegardless() }

    override func close() {
        (contentView as? BattleView)?.stop()
        onClosed?()
        onClosed = nil
        super.close()
    }
}

/// Renders a full 1:1 battle from a deterministic `BattleOutcome`, in the spirit
/// of the Digimon device: two monsters stand far apart, trade flaming projectiles
/// across the whole screen, dodge some shots (turn away + hop back), HP bars
/// drain, and a WIN/LOSE banner lands at the end. "Me" is always drawn on the
/// left, the opponent on the right, regardless of challenger/accepter role.
///
/// The flame trail is a `CAEmitterLayer` (additive fire particles) whose position
/// follows the manually-computed projectile each tick; everything else is drawn
/// in `draw(_:)`, ticked by a 60fps timer off `elapsed` so the animation stays
/// perfectly reproducible from the shared seed.
final class BattleView: NSView {
    private let mySheet: SpriteSheet
    private let oppSheet: SpriteSheet
    private let myName: String
    private let oppName: String
    private let myRole: BattleRole
    private let outcome: BattleOutcome

    /// HP snapshot for each role after round *i* is fully applied; index 0 is the
    /// pre-battle full-HP state, so `hpTimeline[i+1]` is "after round i".
    private let hpTimeline: [(challenger: Int, accepter: Int)]

    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var finished = false
    var onFinished: (() -> Void)?

    // Battle "stance" frames — the shared idle sprite bakes in a sleep/Zzz
    // overlay, which looks wrong mid-fight, so battle uses the clean `running`
    // bounce (no status-condition reskin) instead.
    private let myPose: SpriteAnimationFrames?
    private let oppPose: SpriteAnimationFrames?

    // Flame trail for the in-flight projectile (see class doc).
    private var fireEmitter: CAEmitterLayer?

    // Timing (seconds) — deliberately slow so the projectile is easy to follow
    // as it crosses the whole screen.
    private let introDuration: TimeInterval = 1.3
    // One clear turn per round: the attacker winds up, fires, the shot crosses,
    // the defender reacts, then a beat of calm before the *other* pet's turn.
    private let roundDuration: TimeInterval = 1.7
    private let windupFraction: TimeInterval = 0.14 // attacker lunges before the shot leaves
    private let hitFraction: TimeInterval = 0.62     // when a *hit* projectile connects

    init(mySheet: SpriteSheet, oppSheet: SpriteSheet, myName: String, oppName: String, myRole: BattleRole, outcome: BattleOutcome) {
        self.mySheet = mySheet
        self.oppSheet = oppSheet
        self.myName = myName
        self.oppName = oppName
        self.myRole = myRole
        self.outcome = outcome
        // Prefer the clean `running` bounce; fall back to whatever resolves.
        self.myPose = mySheet.animation(named: "running") ?? mySheet.resolvedAnimation(for: .running)
        self.oppPose = oppSheet.animation(named: "running") ?? oppSheet.resolvedAnimation(for: .running)

        // Replay rounds into an HP timeline the renderer can index by time.
        var timeline: [(challenger: Int, accepter: Int)] = [(outcome.startHP, outcome.startHP)]
        var ch = outcome.startHP, ac = outcome.startHP
        for round in outcome.rounds {
            if round.attacker == .challenger { ac = max(0, ac - round.damage) }
            else { ch = max(0, ch - round.damage) }
            timeline.append((ch, ac))
        }
        self.hpTimeline = timeline

        super.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        wantsLayer = true
        setUpEmitter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Flame emitter (CAEmitterLayer)

    /// A small radial white→transparent glow, drawn in code (no asset catalog),
    /// tinted warm per-cell and composited additively for a fiery bloom.
    private static func makeGlowImage(diameter: Int = 64) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: diameter, height: diameter,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { return nil }
        let c = CGPoint(x: diameter / 2, y: diameter / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(diameter) / 2, options: [])
        return ctx.makeImage()
    }

    private func setUpEmitter() {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 6, height: 6)
        emitter.renderMode = .additive // overlapping particles brighten → fire glow

        let fire = CAEmitterCell()
        fire.name = "fire"
        fire.contents = Self.makeGlowImage()
        fire.birthRate = 0 // gated live via KVC while a projectile is in flight
        fire.lifetime = 0.55
        fire.lifetimeRange = 0.15
        fire.velocity = 24
        fire.velocityRange = 18
        fire.emissionRange = .pi * 2 // radiate all around → round fireball
        fire.scale = 0.75
        fire.scaleRange = 0.3
        fire.scaleSpeed = -0.9      // shrink as it burns out
        fire.alphaSpeed = -1.8      // fade
        fire.color = CGColor(red: 1, green: 0.55, blue: 0.16, alpha: 1)
        fire.greenSpeed = -0.5      // redden as it cools
        fire.blueSpeed = -0.4
        emitter.emitterCells = [fire]

        layer?.addSublayer(emitter)
        fireEmitter = emitter
    }

    /// Move the flame to `point` and turn emission on/off. Wrapped in a
    /// non-animated transaction so the position snaps each frame instead of
    /// lagging behind on an implicit animation.
    private func updateEmitter(active: Bool, at point: CGPoint) {
        guard let emitter = fireEmitter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.emitterPosition = point
        // Toggle the *named* cell's birthRate via KVC (toggling the layer's own
        // birthRate is unreliable for stop/start).
        emitter.setValue(active ? 260.0 : 0.0, forKeyPath: "emitterCells.fire.birthRate")
        CATransaction.commit()
    }

    // MARK: - Lifecycle

    func start() {
        startTime = Date().timeIntervalSinceReferenceDate
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        updateEmitter(active: false, at: .zero)
    }

    private var elapsed: TimeInterval { Date().timeIntervalSinceReferenceDate - startTime }
    private var battleEnd: TimeInterval { introDuration + Double(outcome.rounds.count) * roundDuration }
    private var burstIndex = 0
    private var nextBurstAt: TimeInterval = 0

    private func tick() {
        if !finished && elapsed >= battleEnd {
            finished = true
            updateEmitter(active: false, at: .zero)
            onFinished?()
        }
        needsDisplay = true
        maybeCaptureSnapshot()
    }

    // Test hook: with CONNORPET_BATTLE_SNAPSHOT set, dump a *burst* of frames
    // (`<stem>_NN.png`) every 0.3s. `cacheDisplay` renders only THIS instance's
    // own overlay — never another running copy's — so the burst shows one
    // machine's clean turn-by-turn view for headless verification.
    private func maybeCaptureSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["CONNORPET_BATTLE_SNAPSHOT"],
              elapsed >= nextBurstAt, burstIndex <= 30 else { return }
        nextBurstAt = elapsed + 0.3
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let outURL = dir.appendingPathComponent(String(format: "%@_%02d.%@", stem, burstIndex, ext))
        burstIndex += 1
        display()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outURL)
        }
    }

    // MARK: - Layout (fullscreen)

    private var petSize: CGFloat { min(180, bounds.height * 0.24) }
    private var baselineY: CGFloat { bounds.height * 0.42 }
    private var leftCenter: CGPoint { CGPoint(x: bounds.width * 0.16, y: baselineY) }
    private var rightCenter: CGPoint { CGPoint(x: bounds.width * 0.84, y: baselineY) }
    private var projectileY: CGFloat { baselineY + petSize * 0.04 }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()

        let t = elapsed
        let myIsChallenger = (myRole == .challenger)

        // Which round, and how far into it.
        let roundsElapsed = max(0, t - introDuration)
        let roundIndex = min(outcome.rounds.count, Int(roundsElapsed / roundDuration))
        let roundProgress = roundDuration > 0 ? (roundsElapsed - Double(roundIndex) * roundDuration) / roundDuration : 0

        let inRound = roundIndex < outcome.rounds.count
        let round = inRound ? outcome.rounds[roundIndex] : nil
        let attackerIsMe = round.map { $0.attacker == myRole } ?? false
        let dodged = round?.dodged ?? false

        // HP shown: on a *landing* hit, snap to the post-round value once the
        // projectile connects; a dodge never changes HP.
        let connected = inRound && !dodged && roundProgress >= hitFraction
        let hpIndex = connected ? roundIndex + 1 : roundIndex
        let hp = hpTimeline[min(hpIndex, hpTimeline.count - 1)]
        let myHP = myIsChallenger ? hp.challenger : hp.accepter
        let oppHP = myIsChallenger ? hp.accepter : hp.challenger

        // Defender reactions: a landing hit flashes+shakes them; a dodge turns
        // them away and hops them back around the moment the shot arrives. The
        // attacker jabs forward as it fires so it's obvious whose turn it is.
        var myFlash = false, oppFlash = false
        var myDodge: CGFloat = 0, oppDodge: CGFloat = 0   // 0…1 dodge amount
        var myLunge: CGFloat = 0, oppLunge: CGFloat = 0   // attacker forward jab (px)
        if inRound {
            let defenderIsMe = !attackerIsMe
            if dodged {
                // Dodge window straddles the pass-by point.
                let d = dodgeAmount(progress: roundProgress)
                if defenderIsMe { myDodge = d } else { oppDodge = d }
            } else if roundProgress >= hitFraction && roundProgress < hitFraction + 0.2 {
                if defenderIsMe { myFlash = true } else { oppFlash = true }
            }
            let lunge = attackLunge(progress: roundProgress) * (petSize * 0.16)
            if attackerIsMe { myLunge = lunge } else { oppLunge = lunge }
        }

        // Pets: left = me facing right; right = opponent facing left (flipped).
        // A dodging pet flips to face away and hops backward (away from center).
        drawPet(myPose, center: leftCenter, baseFlipped: false,
                dodge: myDodge, awaySign: -1, lunge: myLunge, flash: myFlash)
        drawPet(oppPose, center: rightCenter, baseFlipped: true,
                dodge: oppDodge, awaySign: +1, lunge: oppLunge, flash: oppFlash)

        // Projectile + flame.
        drawProjectile(roundIndex: roundIndex, inRound: inRound, attackerIsMe: attackerIsMe,
                       dodged: dodged, roundProgress: roundProgress)

        // HP bars + names, pinned to the top corners.
        let barW = min(340, bounds.width * 0.30)
        let barY = bounds.height * 0.80
        drawHP(name: myName, hp: myHP, maxHP: outcome.startHP,
               at: CGRect(x: bounds.width * 0.06, y: barY, width: barW, height: 20), rightAligned: false)
        drawHP(name: oppName, hp: oppHP, maxHP: outcome.startHP,
               at: CGRect(x: bounds.width * 0.94 - barW, y: barY, width: barW, height: 20), rightAligned: true)

        if t < introDuration { drawCenterBanner("VS", color: .white) }
        if finished {
            let iWon = (outcome.winner == myRole)
            drawCenterBanner(iWon ? "WIN!" : "LOSE", color: iWon ? .systemYellow : .systemGray)
        }
    }

    /// Smooth 0→1→0 dodge intensity across the pass-by window of a dodged round.
    private func dodgeAmount(progress: Double) -> CGFloat {
        let lo = hitFraction - 0.22, hi = hitFraction + 0.18
        guard progress >= lo, progress <= hi else { return 0 }
        return CGFloat(sin((progress - lo) / (hi - lo) * .pi))
    }

    /// Quick out-and-back jab the attacker does as it fires (0→1→0), so it reads
    /// as clearly *this* pet's turn.
    private func attackLunge(progress: Double) -> CGFloat {
        let hi = windupFraction + 0.24
        guard progress >= 0, progress <= hi else { return 0 }
        return CGFloat(sin(progress / hi * .pi))
    }

    private func drawBackground() {
        // Semi-transparent arena: dark enough to read HP/pets, sheer enough that
        // the desktop shows through — reinforcing "the pets are out in your space".
        let top = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.12, alpha: 0.46)
        let bottom = NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.06, alpha: 0.34)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)

        // Faint ground line at the pets' feet.
        let footY = baselineY - petSize * 0.5
        let ground = NSBezierPath()
        ground.move(to: NSPoint(x: 0, y: footY))
        ground.line(to: NSPoint(x: bounds.width, y: footY))
        NSColor(white: 1, alpha: 0.10).setStroke()
        ground.lineWidth = 2
        ground.stroke()
    }

    private func drawPet(_ frames: SpriteAnimationFrames?, center: CGPoint, baseFlipped: Bool,
                         dodge: CGFloat, awaySign: CGFloat, lunge: CGFloat, flash: Bool) {
        guard let frames, !frames.images.isEmpty else { return }
        // Cycle pose frames by wall-clock using their declared durations.
        let totalMs = frames.durationsMs.reduce(0, +)
        var index = 0
        if totalMs > 0 {
            var acc = (elapsed * 1000).truncatingRemainder(dividingBy: totalMs)
            for (i, d) in frames.durationsMs.enumerated() {
                if acc < d { index = i; break }
                acc -= d
            }
        }
        let image = frames.images[min(index, frames.images.count - 1)]

        // Dodging: hop backward (away from center) and turn to face away.
        // Attacking: jab forward (toward center = opposite of "away").
        let hopX = awaySign * dodge * (petSize * 0.22)
        let hopY = dodge * (petSize * 0.10)
        let lungeX = -awaySign * lunge
        let flipped = dodge > 0.5 ? !baseFlipped : baseFlipped
        let cx = center.x + hopX + lungeX
        let cy = center.y + hopY
        let rect = NSRect(x: cx - petSize / 2, y: cy - petSize / 2, width: petSize, height: petSize)

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        if flipped {
            ctx?.translateBy(x: rect.midX, y: 0)
            ctx?.scaleBy(x: -1, y: 1)
            ctx?.translateBy(x: -rect.midX, y: 0)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        if flash {
            NSColor(calibratedRed: 1, green: 0.25, blue: 0.25, alpha: 0.55).set()
            image.draw(in: rect, from: .zero, operation: .sourceAtop, fraction: 0.55)
        }
        ctx?.restoreGState()
    }

    /// Positions the flame emitter and draws a bright core, or clears the flame
    /// when nothing's in flight. On a hit the projectile stops at the defender;
    /// on a dodge it sails past them and off the far edge of the screen.
    private func drawProjectile(roundIndex: Int, inRound: Bool, attackerIsMe: Bool,
                                dodged: Bool, roundProgress: Double) {
        guard inRound else { updateEmitter(active: false, at: .zero); return }

        // Attacker's muzzle and the target point.
        let fromX = attackerIsMe ? leftCenter.x + petSize * 0.30 : rightCenter.x - petSize * 0.30
        let defenderFrontX = attackerIsMe ? rightCenter.x - petSize * 0.30 : leftCenter.x + petSize * 0.30

        // The shot only leaves the muzzle after the attacker's wind-up.
        guard roundProgress >= windupFraction else { updateEmitter(active: false, at: .zero); return }
        let flight = 1.0 - windupFraction

        let x: CGFloat
        let visible: Bool
        if dodged {
            // Fly from muzzle past the defender to off-screen over the rest of the turn.
            let offX: CGFloat = attackerIsMe ? bounds.width + 100 : -100
            let p = (roundProgress - windupFraction) / flight
            x = fromX + (offX - fromX) * CGFloat(p)
            visible = true
        } else {
            // Fly to the defender over [windup, hitFraction], then it's spent.
            let frac = min((roundProgress - windupFraction) / (hitFraction - windupFraction), 1.0)
            x = fromX + (defenderFrontX - fromX) * CGFloat(frac)
            visible = roundProgress < hitFraction
        }

        guard visible else { updateEmitter(active: false, at: .zero); return }
        let point = CGPoint(x: x, y: projectileY)
        updateEmitter(active: true, at: point)

        // Bright core so there's a solid head (and something for the snapshot to
        // capture — the emitter's live particles don't render into cacheDisplay).
        let core = NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: core).fill()
        let halo = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        NSColor(calibratedRed: 1, green: 0.55, blue: 0.15, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: halo).fill()
    }

    private func drawHP(name: String, hp: Int, maxHP: Int, at rect: CGRect, rightAligned: Bool) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white
        ]
        let nameStr = name as NSString
        let nameSize = nameStr.size(withAttributes: nameAttrs)
        let nameX = rightAligned ? rect.maxX - nameSize.width : rect.minX
        nameStr.draw(at: NSPoint(x: nameX, y: rect.maxY + 4), withAttributes: nameAttrs)

        let bg = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.35).setFill(); bg.fill()
        NSColor(white: 1, alpha: 0.18).setStroke(); bg.stroke()

        let frac = maxHP > 0 ? CGFloat(max(0, hp)) / CGFloat(maxHP) : 0
        let fillWidth = (rect.width - 2) * frac
        let fillRect = rightAligned
            ? CGRect(x: rect.maxX - 1 - fillWidth, y: rect.minY + 1, width: fillWidth, height: rect.height - 2)
            : CGRect(x: rect.minX + 1, y: rect.minY + 1, width: fillWidth, height: rect.height - 2)
        let color: NSColor = frac > 0.5 ? .systemGreen : (frac > 0.25 ? .systemYellow : .systemRed)
        if fillWidth > 0.5 {
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
        }
    }

    private func drawCenterBanner(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 88, weight: .heavy),
            .foregroundColor: color,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.5
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + 30), withAttributes: attrs)
    }
}
