import AppKit

/// Renders the current sprite frame and owns all pointer interaction
/// (drag → running-left/right, hover → jumping), mirroring
/// `usePetPointerInteraction.ts` + `PetOverlay.tsx`'s render precedence.
final class PetView: NSView {
    private var spriteSheet: SpriteSheet
    private var trackingArea: NSTrackingArea?

    private var frameIndex = 0
    private var frameTimer: Timer?
    private var currentFrames: SpriteAnimationFrames?
    private var currentAnimationKey: String?

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

    /// 불뿜기가 실제로 재생됐을 때. 호출부가 시각을 기록한다.
    var onFireBreath: (() -> Void)?

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

    // MARK: - Public: swapping the active character

    /// Switches the rendered character (e.g. via the menu-bar picker) while
    /// preserving live interaction state (hover/drag/base status animation).
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

    private func speak(_ text: String) {
        // Long briefings need to stay up long enough to actually read: a floor
        // of 4s plus ~55ms per character, capped so it never sticks forever.
        let duration = min(24.0, max(4.0, 4.0 + Double(text.count) * 0.055))
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
            // 불뿜기는 고정이 아니라 1회 재생이고, 메뉴가 열린 상태에서 a 로 바로 쏜다.
            let isOneShot = (name == .fireBreath)
            let item = NSMenuItem(
                title: name.koreanLabel,
                action: isOneShot ? #selector(fireBreath(_:)) : #selector(pinMotion(_:)),
                keyEquivalent: isOneShot ? "a" : ""
            )
            if isOneShot {
                // 기본값이 ⌘ 라서 비워야 a 단독으로 먹는다.
                item.keyEquivalentModifierMask = []
            }
            item.target = self
            item.representedObject = name.rawValue
            item.state = (!isOneShot && pinnedAnimation == name) ? .on : .off
            // A motion with no row in this pet's manifest cannot be played.
            item.isEnabled = spriteSheet.animation(named: name.rawValue) != nil
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func fireBreath(_ sender: NSMenuItem) {
        pinnedAnimation = nil
        if playOnce(.fireBreath) {
            onFireBreath?()
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
            currentAnimationKey = nil // 다음 모션을 0프레임부터 다시 시작시킨다
            applyDisplayAnimation()
            return
        }
        frameIndex = next % frames.images.count
        needsDisplay = true
        scheduleNextFrame()
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
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
    }

    // MARK: - Pointer interaction

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHoverEnter?()
        applyDisplayAnimation()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyDisplayAnimation()
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
