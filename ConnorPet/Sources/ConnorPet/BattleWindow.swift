import AppKit

/// The floating window that hosts a battle. Titled + centered so it reads as a
/// distinct "game screen" over the desktop pet. Auto-closes when the battle's
/// result has been shown; also closes on click or Esc.
final class BattleWindow: NSWindow {
    private var onClosed: (() -> Void)?

    init(view: BattleView, onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        let size = BattleView.preferredSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "대전"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
        center()

        view.onFinished = { [weak self] in
            // Give the WIN/LOSE banner a few seconds on screen, then dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.close() }
        }
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        (contentView as? BattleView)?.stop()
        onClosed?()
        onClosed = nil
        super.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) } // Esc
    }
}

/// Renders a full 1:1 battle from a deterministic `BattleOutcome`, in the spirit
/// of the Digimon device: two monsters face each other, trade projectile hits,
/// HP bars drain, and a WIN/LOSE banner lands at the end. "Me" is always drawn
/// on the left, the opponent on the right, regardless of challenger/accepter role.
final class BattleView: NSView {
    static let preferredSize = NSSize(width: 520, height: 360)

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

    // Idle sprite frames for each side (pre-sliced once).
    private let myIdle: SpriteAnimationFrames?
    private let oppIdle: SpriteAnimationFrames?

    // Timing (seconds).
    private let introDuration: TimeInterval = 1.0
    private let roundDuration: TimeInterval = 0.8
    private let hitFraction: TimeInterval = 0.55 // when in a round the projectile connects

    init(mySheet: SpriteSheet, oppSheet: SpriteSheet, myName: String, oppName: String, myRole: BattleRole, outcome: BattleOutcome) {
        self.mySheet = mySheet
        self.oppSheet = oppSheet
        self.myName = myName
        self.oppName = oppName
        self.myRole = myRole
        self.outcome = outcome
        self.myIdle = mySheet.resolvedAnimation(for: .idle)
        self.oppIdle = oppSheet.resolvedAnimation(for: .idle)

        // Replay rounds into an HP timeline the renderer can index by time.
        var timeline: [(challenger: Int, accepter: Int)] = [(outcome.startHP, outcome.startHP)]
        var ch = outcome.startHP, ac = outcome.startHP
        for round in outcome.rounds {
            if round.attacker == .challenger { ac = max(0, ac - round.damage) }
            else { ch = max(0, ch - round.damage) }
            timeline.append((ch, ac))
        }
        self.hpTimeline = timeline

        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func start() {
        startTime = Date().timeIntervalSinceReferenceDate
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.close()
    }

    private var elapsed: TimeInterval { Date().timeIntervalSinceReferenceDate - startTime }

    private var battleEnd: TimeInterval { introDuration + Double(outcome.rounds.count) * roundDuration }

    private var snapshotDone = false

    private func tick() {
        if !finished && elapsed >= battleEnd {
            finished = true
            onFinished?()
        }
        needsDisplay = true
        maybeCaptureSnapshot()
    }

    // Test hook: once the battle is well underway, render this view to a PNG at
    // CONNORPET_BATTLE_SNAPSHOT so a headless run can verify the rendering.
    private func maybeCaptureSnapshot() {
        guard !snapshotDone, elapsed > introDuration + roundDuration * 1.5,
              let path = ProcessInfo.processInfo.environment["CONNORPET_BATTLE_SNAPSHOT"] else { return }
        snapshotDone = true
        display() // force an immediate draw so the rep isn't blank
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Layout constants

    private let petSize: CGFloat = 132
    private var leftCenter: CGPoint { CGPoint(x: 132, y: 150) }
    private var rightCenter: CGPoint { CGPoint(x: bounds.width - 132, y: 150) }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        drawBackground()

        let t = elapsed
        let myRoleIsChallenger = (myRole == .challenger)

        // Current round index and progress within it.
        let roundsElapsed = max(0, t - introDuration)
        let roundIndex = min(outcome.rounds.count, Int(roundsElapsed / roundDuration))
        let roundProgress = roundDuration > 0 ? (roundsElapsed - Double(roundIndex) * roundDuration) / roundDuration : 0

        // HP shown: after the current round's hit connects, snap to the post-round
        // value; before that, still show the pre-round value.
        let hitConnected = roundIndex < outcome.rounds.count && roundProgress >= hitFraction
        let hpIndex = hitConnected ? roundIndex + 1 : roundIndex
        let hp = hpTimeline[min(hpIndex, hpTimeline.count - 1)]
        let myHP = myRoleIsChallenger ? hp.challenger : hp.accepter
        let oppHP = myRoleIsChallenger ? hp.accepter : hp.challenger

        // Is either side being hit right now (for a shake/flash)?
        var leftShake: CGFloat = 0, rightShake: CGFloat = 0
        var leftFlash = false, rightFlash = false
        if roundIndex < outcome.rounds.count {
            let attacker = outcome.rounds[roundIndex].attacker
            let attackerIsMe = (attacker == myRole)
            // The target is the *other* side.
            let targetIsLeft = !attackerIsMe
            if roundProgress >= hitFraction && roundProgress < hitFraction + 0.22 {
                let shake = sin((roundProgress - hitFraction) * .pi / 0.22) * 6
                if targetIsLeft { leftShake = shake; leftFlash = true }
                else { rightShake = shake; rightFlash = true }
            }
        }

        // Pets. Left = me (face right), right = opponent (face left → flipped).
        drawPet(myIdle, center: CGPoint(x: leftCenter.x + leftShake, y: leftCenter.y), flipped: false, flash: leftFlash, ctx: ctx)
        drawPet(oppIdle, center: CGPoint(x: rightCenter.x + rightShake, y: rightCenter.y), flipped: true, flash: rightFlash, ctx: ctx)

        // Projectile in flight during the pre-hit portion of a round.
        if roundIndex < outcome.rounds.count && roundProgress < hitFraction {
            let attacker = outcome.rounds[roundIndex].attacker
            let attackerIsMe = (attacker == myRole)
            let p = roundProgress / hitFraction // 0→1 across the gap
            let fromX = attackerIsMe ? leftCenter.x + petSize * 0.32 : rightCenter.x - petSize * 0.32
            let toX = attackerIsMe ? rightCenter.x - petSize * 0.32 : leftCenter.x + petSize * 0.32
            let x = fromX + (toX - fromX) * CGFloat(p)
            drawProjectile(at: CGPoint(x: x, y: leftCenter.y + 6), ctx: ctx)
        }

        // HP bars + names.
        drawHP(name: myName, hp: myHP, maxHP: outcome.startHP, at: CGRect(x: 24, y: bounds.height - 52, width: 200, height: 18), rightAligned: false)
        drawHP(name: oppName, hp: oppHP, maxHP: outcome.startHP, at: CGRect(x: bounds.width - 224, y: bounds.height - 52, width: 200, height: 18), rightAligned: true)

        // Intro "VS" and final banner.
        if t < introDuration {
            drawCenterBanner("VS", color: .white, scale: 1.0 - CGFloat(max(0, t - 0.5)) * 0.0)
        }
        if finished {
            let iWon = (outcome.winner == myRole)
            drawCenterBanner(iWon ? "WIN!" : "LOSE", color: iWon ? NSColor.systemYellow : NSColor.systemGray)
        }
    }

    private func drawBackground() {
        // Gameboy-ish gradient arena.
        let top = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)

        // Ground line the pets stand on.
        let ground = NSBezierPath()
        ground.move(to: NSPoint(x: 0, y: 92))
        ground.line(to: NSPoint(x: bounds.width, y: 92))
        NSColor(white: 1, alpha: 0.12).setStroke()
        ground.lineWidth = 2
        ground.stroke()
    }

    private func drawPet(_ frames: SpriteAnimationFrames?, center: CGPoint, flipped: Bool, flash: Bool, ctx: CGContext?) {
        guard let frames, !frames.images.isEmpty else { return }
        // Cycle idle frames by wall-clock using their declared durations.
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
        let rect = NSRect(x: center.x - petSize / 2, y: center.y - petSize / 2, width: petSize, height: petSize)

        ctx?.saveGState()
        if flipped {
            ctx?.translateBy(x: rect.midX, y: 0)
            ctx?.scaleBy(x: -1, y: 1)
            ctx?.translateBy(x: -rect.midX, y: 0)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        if flash {
            // Red hit overlay, masked to the sprite's alpha.
            NSColor(calibratedRed: 1, green: 0.2, blue: 0.2, alpha: 0.55).set()
            let overlay = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            image.draw(in: overlay, from: .zero, operation: .sourceAtop, fraction: 0.55)
        }
        ctx?.restoreGState()
    }

    private func drawProjectile(at point: CGPoint, ctx: CGContext?) {
        let outer = NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
        let inner = NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: outer).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: inner).fill()
    }

    private func drawHP(name: String, hp: Int, maxHP: Int, at rect: CGRect, rightAligned: Bool) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        let nameStr = name as NSString
        let nameSize = nameStr.size(withAttributes: nameAttrs)
        let nameX = rightAligned ? rect.maxX - nameSize.width : rect.minX
        nameStr.draw(at: NSPoint(x: nameX, y: rect.maxY + 2), withAttributes: nameAttrs)

        // Bar background.
        let bg = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor(white: 1, alpha: 0.15).setFill()
        bg.fill()

        // Fill proportional to HP; color shifts green→yellow→red as it drains.
        let frac = maxHP > 0 ? CGFloat(max(0, hp)) / CGFloat(maxHP) : 0
        let fillWidth = rect.width * frac
        let fillRect = rightAligned
            ? CGRect(x: rect.maxX - fillWidth, y: rect.minY, width: fillWidth, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let color: NSColor = frac > 0.5 ? .systemGreen : (frac > 0.25 ? .systemYellow : .systemRed)
        if fillWidth > 0.5 {
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
            color.setFill()
            fill.fill()
        }
    }

    private func drawCenterBanner(_ text: String, color: NSColor, scale: CGFloat = 1.0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64 * max(scale, 0.01), weight: .heavy),
            .foregroundColor: color,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + 20), withAttributes: attrs)
    }
}
