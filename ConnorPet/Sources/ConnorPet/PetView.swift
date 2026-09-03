import AppKit

/// Renders the current sprite frame and owns all pointer interaction
/// (drag → running-left/right, hover → jumping), mirroring
/// `usePetPointerInteraction.ts` + `PetOverlay.tsx`'s render precedence.
final class PetView: NSView {
    /// Height reserved at the bottom of the view for the XP bar (game convention
    /// puts progression bars along the bottom, not overhead — overhead space
    /// reads as health/status). The sprite renders in the square above it.
    static let barAreaHeight: CGFloat = 18

    private var spriteSheet: SpriteSheet
    private var trackingArea: NSTrackingArea?

    private var frameIndex = 0
    private var frameTimer: Timer?
    private var currentFrames: SpriteAnimationFrames?
    private var currentAnimationKey: String?

    // XP bar inputs. `percent` (0...1) sets the fill width; `stage` (0/1/2)
    // sets the fill color, so the bar's color tracks the pet's evolution stage.
    private var progressPercent: Double = 0
    private var progressStage: Int = 0
    // When true the bar is always drawn; when false it only appears on hover
    // (menu-bar toggle, see AppDelegate). Default on.
    private var barAlwaysVisible = true

    // Live inputs, combined exactly like `selectPetAnimationName`.
    private var baseAnimation: PetAnimationName = .idle
    private var dragging = false
    private var dragDirection: PetDragDirection?
    private var hovering = false
    private var dragBaselineX: CGFloat = 0
    private var dragOffset: CGPoint = .zero
    private var didDragThisGesture = false

    /// Set while the pet is delivering a briefing — outranks hover so the
    /// pointer sitting on the pet (which it always is, right after a click)
    /// does not replace the waving motion with the hover jump.
    private var speaking = false
    private var speakingTimer: Timer?

    /// Motion pinned from the right-click menu. While set it overrides the
    /// agent state entirely, so any motion can be inspected on demand; picking
    /// "자동" clears it and hands control back to the live status.
    private var pinnedAnimation: PetAnimationName?

    /// 한 바퀴만 돌고 스스로 물러나는 모션(불뿜기). 고정(pin)과 달리 끝나면
    /// 원래 상태로 돌아간다 — 체크포인트 동작이라 계속 뿜고 있으면 곤란하다.
    private var oneShotAnimation: PetAnimationName?

    /// 속성기가 실제로 재생됐을 때. 호출부가 시각을 기록한다.
    var onSkillUsed: (() -> Void)?

    /// 속성기 프레임이 바뀔 때마다 호출된다. 매니페스트 좌표(프레임 기준)를
    /// 그대로 넘기고, 화면 좌표 환산과 그리기는 호출부가 한다.
    /// grow 가 0 이면 이번 프레임에는 이펙트가 없다.
    var onFlameFrame: ((_ mouthInFrame: CGPoint, _ grow: CGFloat) -> Void)?

    var onRequestWindowMove: ((_ screenOrigin: CGPoint) -> Void)?
    /// Left click (not a drag). The delegate returns the text to say, or nil
    /// to stay quiet.
    var onClick: (() -> String?)?
    var onSpeak: ((_ text: String, _ duration: TimeInterval) -> Void)?
    var onSilence: (() -> Void)?
    /// Fires once each time the pointer enters the pet — the "you noticed it"
    /// gesture AppDelegate uses to dismiss a lingering review/헤롱헤롱 state.
    var onHoverEnter: (() -> Void)?

    init(spriteSheet: SpriteSheet) {
        self.spriteSheet = spriteSheet
        super.init(frame: .zero)
        wantsLayer = true
        applyDisplayAnimation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Public: base agent-status animation

    func setBaseAnimation(_ name: PetAnimationName) {
        guard baseAnimation != name else { return }
        baseAnimation = name
        applyDisplayAnimation()
    }

    // MARK: - Public: XP bar

    /// Updates the XP bar fill (`percent`, 0...1) and its color (`stage`).
    func setProgress(percent: Double, stage: Int) {
        let clamped = min(1, max(0, percent))
        guard clamped != progressPercent || stage != progressStage else { return }
        progressPercent = clamped
        progressStage = stage
        needsDisplay = true
    }

    /// Whether the XP bar shows all the time (true) or only while hovered (false).
    func setBarAlwaysVisible(_ always: Bool) {
        guard always != barAlwaysVisible else { return }
        barAlwaysVisible = always
        needsDisplay = true
    }

    // MARK: - Public: swapping the active character

    /// Switches the rendered character (e.g. via the menu-bar picker) while
    /// preserving live interaction state (hover/drag/base status animation).
    /// 현재 재생 중인 시트. 호출부가 매니페스트(프레임 크기 등)를 읽는다.
    var currentSpriteSheet: SpriteSheet { spriteSheet }

    func setSpriteSheet(_ newSheet: SpriteSheet) {
        spriteSheet = newSheet
        currentAnimationKey = nil // force applyDisplayAnimation to restart from frame 0
        applyDisplayAnimation()
    }

    // MARK: - Selection precedence (mirrors selectPetAnimationName)

    private func selectedAnimation() -> PetAnimationName {
        if dragging {
            switch dragDirection {
            case .right: return .runningRight
            case .left: return .runningLeft
            case nil: return pinnedAnimation ?? baseAnimation
            }
        }
        if let oneShot = oneShotAnimation {
            return oneShot
        }
        if let pinned = pinnedAnimation {
            return pinned
        }
        if speaking {
            return .waving
        }
        if hovering {
            return .jumping
        }
        return baseAnimation
    }

    // MARK: - Speaking

    /// 브리핑 말풍선이 떠 있는 시간. 여러 세션을 훑어 읽을 수 있어야 한다.
    static let briefingDuration: TimeInterval = 30

    private func speak(_ text: String) {
        let duration = Self.briefingDuration
        speaking = true
        applyDisplayAnimation()
        onSpeak?(text, duration)

        speakingTimer?.invalidate()
        speakingTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.speaking = false
            self?.applyDisplayAnimation()
        }
    }

    private func stopSpeaking() {
        speakingTimer?.invalidate()
        speakingTimer = nil
        guard speaking else { return }
        speaking = false
        onSilence?()
        applyDisplayAnimation()
    }

    // MARK: - Right-click motion menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "모션", action: nil, keyEquivalent: "").isEnabled = false

        let auto = NSMenuItem(title: "자동 (에이전트 상태 따르기)", action: #selector(pinMotion(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil as String?
        auto.state = pinnedAnimation == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        for name in PetAnimationName.allCases {
            // 단축키가 붙은 모션은 고정이 아니라 그 자리에서 한 번 실행되는 동작이다.
            let shortcut = name.menuShortcut
            let action: Selector
            switch name {
            case _ where name.isSkill: action = #selector(useSkill(_:))
            case .waving:              action = #selector(speakBriefing(_:))
            default:                   action = #selector(pinMotion(_:))
            }
            let item = NSMenuItem(title: name.koreanLabel, action: action,
                                  keyEquivalent: shortcut ?? "")
            if shortcut != nil {
                // 기본값이 ⌘ 라서 비워야 글자 단독으로 먹는다.
                item.keyEquivalentModifierMask = []
            }
            item.target = self
            item.representedObject = name.rawValue
            item.state = (shortcut == nil && pinnedAnimation == name) ? .on : .off
            // A motion with no row in this pet's manifest cannot be played.
            item.isEnabled = spriteSheet.animation(named: name.rawValue) != nil
            menu.addItem(item)
        }

        // 종료. 지금까지는 메뉴바 아이콘에서만 끌 수 있었는데, 펫이 눈앞에 있는데
        // 메뉴바까지 올라가야 하는 게 번거롭다.
        //
        // 단축키는 일부러 안 붙였다. 메뉴가 열린 상태에서 글자 키가 그대로 먹으므로
        // (a·s 가 그렇게 동작한다) 종료에까지 달면 오타 한 번에 앱이 꺼진다.
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "나가", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// 좌클릭과 같은 동작 — 브리핑을 말한다. 좌클릭이 펫을 맞춰야 하는 반면
    /// 이쪽은 메뉴에서 s 로 바로 부를 수 있다.
    @objc private func speakBriefing(_ sender: NSMenuItem) {
        pinnedAnimation = nil
        stopSpeaking()
        if let text = onClick?(), !text.isEmpty {
            speak(text)
        }
    }

    @objc private func useSkill(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let name = PetAnimationName(rawValue: raw) else { return }
        pinnedAnimation = nil
        if playOnce(name) {
            onSkillUsed?()
        }
    }

    @objc private func pinMotion(_ sender: NSMenuItem) {
        stopSpeaking()
        if let raw = sender.representedObject as? String {
            pinnedAnimation = PetAnimationName(rawValue: raw)
        } else {
            pinnedAnimation = nil
        }
        applyDisplayAnimation()
    }

    private func applyDisplayAnimation() {
        let name = selectedAnimation()
        guard let frames = spriteSheet.resolvedAnimation(for: name), !frames.images.isEmpty else { return }

        let key = name.rawValue
        // Why: mirrors PetOverlay's restartKey — only restart from frame 0 when
        // the resolved animation actually changes; re-selecting the same one
        // (e.g. still hovering) must not visibly reset mid-loop.
        if key != currentAnimationKey {
            currentAnimationKey = key
            currentFrames = frames
            frameIndex = 0
            scheduleNextFrame()
            needsDisplay = true
            publishFlameState()
        }
    }

    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        guard let frames = currentFrames, !frames.durationsMs.isEmpty else { return }
        let holdMs = frames.durationsMs[frameIndex % frames.durationsMs.count]
        frameTimer = Timer.scheduledTimer(withTimeInterval: holdMs / 1000.0, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard let frames = currentFrames, !frames.images.isEmpty else { return }
        let next = frameIndex + 1
        // 1회 재생 모션은 마지막 프레임에서 멈추고 원래 상태로 돌아간다.
        if oneShotAnimation != nil, next >= frames.images.count {
            oneShotAnimation = nil
            onFlameFrame?(.zero, 0)
            currentAnimationKey = nil // 다음 모션을 0프레임부터 다시 시작시킨다
            applyDisplayAnimation()
            return
        }
        frameIndex = next % frames.images.count
        needsDisplay = true
        publishFlameState()
        scheduleNextFrame()
    }

    /// The square the sprite renders into — the whole view minus the XP-bar
    /// strip reserved along the bottom.
    private var spriteRect: NSRect {
        NSRect(x: 0, y: Self.barAreaHeight, width: bounds.width, height: bounds.height - Self.barAreaHeight)
    }

    /// 모션을 한 바퀴만 재생한다. 이 펫에 그 행이 없으면 아무것도 하지 않는다.
    @discardableResult
    func playOnce(_ name: PetAnimationName) -> Bool {
        guard spriteSheet.animation(named: name.rawValue) != nil else { return false }
        stopSpeaking()
        oneShotAnimation = name
        currentAnimationKey = nil
        applyDisplayAnimation()
        return true
    }

    /// 지금 재생 중인 프레임에 맞는 불길 상태를 호출부에 알린다.
    private func publishFlameState() {
        guard let skill = spriteSheet.manifest.skill,
              oneShotAnimation?.rawValue == skill.row,
              case let track = skill.mouthByFrame,
              track.indices.contains(frameIndex)
        else {
            onFlameFrame?(.zero, 0)
            return
        }
        let m = track[frameIndex]
        onFlameFrame?(CGPoint(x: m.x, y: m.y), CGFloat(m.grow))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frames = currentFrames, frames.images.indices.contains(frameIndex) else { return }
        let image = frames.images[frameIndex]
        // Why: .sourceOver blends onto whatever pixels are already in the layer's
        // backing store. Since every frame has transparent margins, switching to a
        // differently-shaped sprite (e.g. via the menu-bar pet picker, or even
        // Totodile's own asymmetric run-cycle frames) left a faint ghost of the
        // previous frame visible wherever the new frame is transparent but the old
        // one wasn't. .copy overwrites the whole rect (color + alpha) with the new
        // frame's pixels instead of blending, so there's nothing left to bleed through.
        image.draw(in: spriteRect, from: .zero, operation: .copy, fraction: 1.0)

        // The bar strip is never touched by the sprite draw above, so clear it
        // to transparent each frame (.copy) before optionally drawing the bar —
        // otherwise a hidden bar (hover-only mode, pointer gone) would linger.
        let barArea = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barAreaHeight)
        NSColor.clear.setFill()
        NSGraphicsContext.current?.compositingOperation = .copy
        barArea.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        if barAlwaysVisible || hovering {
            drawXPBar(in: barArea)
        }
    }

    private func drawXPBar(in area: NSRect) {
        let hInset: CGFloat = 12
        let barHeight: CGFloat = 8
        let track = NSRect(
            x: area.minX + hInset,
            y: area.midY - barHeight / 2,
            width: area.width - hInset * 2,
            height: barHeight
        )
        let radius = barHeight / 2

        // Track (empty portion) — dark, semi-transparent, faint border.
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0, alpha: 0.42).setFill()
        trackPath.fill()
        NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        // Filled portion — width is the XP %, color is the evolution stage.
        guard progressPercent > 0 else { return }
        let fillWidth = max(barHeight, track.width * CGFloat(progressPercent))
        let fill = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius)
        Self.stageColor(progressStage).setFill()
        fillPath.fill()
        // Glossy top highlight so the fill reads as a filled gauge, not a flat block.
        let gloss = NSRect(x: fill.minX + 1, y: fill.midY, width: fill.width - 2, height: fill.height / 2 - 1)
        let glossPath = NSBezierPath(roundedRect: gloss, xRadius: radius / 2, yRadius: radius / 2)
        NSColor(calibratedWhite: 1, alpha: 0.30).setFill()
        glossPath.fill()
    }

    /// Fill color per evolution stage: green (base) → blue (1st) → gold (final),
    /// so the bar's color alone tells you how far the pet has evolved.
    private static func stageColor(_ stage: Int) -> NSColor {
        switch stage {
        case 0: return NSColor(calibratedRed: 0.37, green: 0.82, blue: 0.40, alpha: 1)
        case 1: return NSColor(calibratedRed: 0.29, green: 0.64, blue: 1.00, alpha: 1)
        default: return NSColor(calibratedRed: 1.00, green: 0.79, blue: 0.23, alpha: 1)
        }
    }

    // MARK: - Pointer interaction

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHoverEnter?()
        applyDisplayAnimation()
        if !barAlwaysVisible { needsDisplay = true } // reveal hover-only bar
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyDisplayAnimation()
        if !barAlwaysVisible { needsDisplay = true } // hide hover-only bar again
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        didDragThisGesture = false
        dragDirection = nil
        dragBaselineX = event.locationInWindow.x
        dragOffset = CGPoint(
            x: event.locationInWindow.x,
            y: event.locationInWindow.y
        )
        applyDisplayAnimation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let deltaX = event.locationInWindow.x - dragBaselineX
        let (direction, accepted) = nextPetDragAnimation(current: dragDirection, deltaX: deltaX)
        if accepted {
            dragDirection = direction
            dragBaselineX = event.locationInWindow.x
            didDragThisGesture = true
            applyDisplayAnimation()
        }

        // Move the owning window with the pointer (screen coordinates).
        guard let window = window else { return }
        let mouseLocationInScreen = window.convertPoint(toScreen: event.locationInWindow)
        let newOrigin = CGPoint(
            x: mouseLocationInScreen.x - dragOffset.x,
            y: mouseLocationInScreen.y - dragOffset.y
        )
        onRequestWindowMove?(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        let wasClick = !didDragThisGesture
        dragging = false
        dragDirection = nil

        if wasClick {
            // A second click while talking dismisses the bubble instead of
            // restarting it — otherwise the pet cannot be told to be quiet.
            if speaking {
                stopSpeaking()
            } else if let text = onClick?(), !text.isEmpty {
                speak(text)
                return
            }
        }
        applyDisplayAnimation()
    }
}
