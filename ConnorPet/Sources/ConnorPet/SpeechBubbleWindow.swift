import AppKit

/// The rounded panel body plus the little tail that points down at the pet.
private final class SpeechBubbleView: NSView {
    static let tailHeight: CGFloat = 9
    static let tailWidth: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    static let padding = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)

    var tailCenterX: CGFloat = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        // Tail is clamped so it always sits on the bubble's own edge, even when
        // the pet is near a screen edge and the bubble had to shift sideways.
        let half = Self.tailWidth / 2
        let cx = min(max(tailCenterX, Self.cornerRadius + half), body.maxX - Self.cornerRadius - half)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx + half, y: body.maxY - 1))
        tail.line(to: NSPoint(x: cx, y: bounds.maxY))
        tail.close()
        path.append(tail)

        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A borderless panel that floats just above the pet and shows what it is
/// saying. Separate from the pet window on purpose: the pet window is sized
/// tightly to the sprite, while this has to grow with the text.
final class SpeechBubbleWindow: NSPanel {
    private let bubble = SpeechBubbleView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var dismissTimer: Timer?

    private static let maxWidth: CGFloat = 340
    private static let gap: CGFloat = 6

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            // .nonactivatingPanel keeps clicking the bubble from pulling focus
            // away from whatever the user is actually typing in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true // never steals a click meant for the pet
        hidesOnDeactivate = false

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false

        bubble.addSubview(label)
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `text` above `petFrame` (screen coordinates) and hides it again
    /// after `duration`.
    func show(text: String, above petFrame: NSRect, duration: TimeInterval) {
        let inset = SpeechBubbleView.padding
        let textWidth = Self.maxWidth - inset.left - inset.right

        label.stringValue = text
        label.preferredMaxLayoutWidth = textWidth
        let textSize = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))

        let bodyWidth = min(Self.maxWidth, textSize.width + inset.left + inset.right)
        let bodyHeight = textSize.height + inset.top + inset.bottom
        let total = NSSize(width: bodyWidth, height: bodyHeight + SpeechBubbleView.tailHeight)

        label.frame = NSRect(x: inset.left, y: inset.top, width: bodyWidth - inset.left - inset.right, height: textSize.height)

        var origin = NSPoint(
            x: petFrame.midX - total.width / 2,
            y: petFrame.maxY + Self.gap
        )

        // Keep the whole bubble on the pet's own screen: shift sideways if it
        // would hang off, and flip below the pet if there is no room above.
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - total.width - 4)
            if origin.y + total.height > visible.maxY {
                origin.y = petFrame.minY - total.height - Self.gap
            }
            origin.y = max(origin.y, visible.minY + 4)
        }

        setFrame(NSRect(origin: origin, size: total), display: true)
        bubble.frame = NSRect(origin: .zero, size: total)
        bubble.tailCenterX = petFrame.midX - origin.x
        orderFrontRegardless()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}
