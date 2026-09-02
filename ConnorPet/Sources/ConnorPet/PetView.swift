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
    // (menu-bar toggle, see AppDelegate). Default off.
    private var barAlwaysVisible = false
    // Whether the XP bar mechanism is active at all. Off while evolution is
    // disabled — then no bar is ever shown and the sprite uses the full window
    // (no reserved strip), so the pet sits flush at the bottom.
    private var barEnabled = true

    // Live inputs, combined exactly like `selectPetAnimationName`.
    private var baseAnimation: PetAnimationName = .idle
    private var dragging = false
    private var dragDirection: PetDragDirection?
    private var hovering = false
    private var dragBaselineX: CGFloat = 0
    private var dragOffset: CGPoint = .zero
    private var didDragThisGesture = false

    var onRequestWindowMove: ((_ screenOrigin: CGPoint) -> Void)?
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

    /// Whether the XP bar mechanism is active (evolution enabled). When off, no
    /// bar is drawn and the sprite fills the whole window.
    func setBarEnabled(_ enabled: Bool) {
        guard enabled != barEnabled else { return }
        barEnabled = enabled
        needsDisplay = true
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
            case nil: return baseAnimation
            }
        }
        if hovering {
            return .jumping
        }
        return baseAnimation
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
        frameIndex = (frameIndex + 1) % frames.images.count
        needsDisplay = true
        scheduleNextFrame()
    }

    /// The square the sprite renders into. With the bar enabled it's the view
    /// minus the reserved bottom strip; with the bar disabled the sprite uses
    /// the whole view so the pet stays flush at the bottom.
    private var spriteRect: NSRect {
        guard barEnabled else { return bounds }
        return NSRect(x: 0, y: Self.barAreaHeight, width: bounds.width, height: bounds.height - Self.barAreaHeight)
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

        guard barEnabled else { return } // evolution off → no bar, sprite owns the whole view

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
        dragging = false
        dragDirection = nil
        applyDisplayAnimation()
    }
}
