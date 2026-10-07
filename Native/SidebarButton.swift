import AppKit

@MainActor
final class NativeSidebarButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.toggle)
        wantsLayer = true
        layer?.cornerRadius = 10
        focusRingType = .exterior
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var state: NSControl.StateValue {
        didSet { updateBackground() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        if let window { isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        else { isHovered = false }
        updateBackground()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        // CALayer retains a resolved CGColor, so refresh it when AppKit changes appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if state == .on { color = .controlAccentColor.withAlphaComponent(isHovered ? 0.26 : 0.16) }
            else { color = isHovered ? .quaternaryLabelColor : .clear }
            layer?.backgroundColor = color.cgColor
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
}
