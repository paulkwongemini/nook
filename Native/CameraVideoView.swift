import AppKit

/// The complete image remains in VLC's drawable; only this viewport clips digital zoom.
@MainActor
final class CameraVideoView: NSView {
    let drawable = NSView()
    private(set) var zoom: CGFloat = 1
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    private(set) var displayedVideoRect = CGRect.zero
    var onZoomChange: ((CGFloat) -> Void)?
    var videoSize = CGSize(width: 16, height: 9) {
        didSet {
            guard videoSize.width.isFinite, videoSize.height.isFinite,
                  videoSize.width > 0, videoSize.height > 0,
                  (videoSize.width / videoSize.height).isFinite else {
                videoSize = oldValue
                return
            }
            updateGeometry()
        }
    }
    private var dragStart: (point: CGPoint, center: CGPoint)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        addSubview(drawable)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live camera video")
        updateInteractionHelp()
        updateGeometry()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setZoom(_ value: CGFloat) {
        guard value.isFinite else { return }
        let value = min(max(value, 1), 4)
        guard zoom != value else { return }
        zoom = value
        updateGeometry()
        updateInteractionHelp()
        onZoomChange?(zoom)
    }

    func resetView() {
        dragStart = nil
        center = CGPoint(x: 0.5, y: 0.5)
        setZoom(1)
        updateGeometry()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height) * zoom
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        center.x = clampedCenter(center.x, imageLength: size.width, viewportLength: bounds.width)
        center.y = clampedCenter(center.y, imageLength: size.height, viewportLength: bounds.height)
        displayedVideoRect = CGRect(x: bounds.midX - center.x * size.width,
                                    y: bounds.midY - center.y * size.height,
                                    width: size.width, height: size.height)
        drawable.frame = displayedVideoRect
    }

    private func clampedCenter(_ value: CGFloat, imageLength: CGFloat, viewportLength: CGFloat) -> CGFloat {
        guard imageLength > viewportLength else { return 0.5 }
        let edge = viewportLength / (2 * imageLength)
        return min(max(value, edge), 1 - edge)
    }

    private func updateInteractionHelp() {
        let help = zoom > 1 ? "Drag to pan the enlarged video. Use Reset to show the full image."
            : "Use the zoom controls to enlarge the video."
        setAccessibilityHelp(help)
        setAccessibilityValue("\(Int((zoom * 100).rounded())) percent zoom")
        toolTip = help
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: zoom > 1 ? (dragStart == nil ? .openHand : .closedHand) : .arrow)
    }

    // VLC creates child views which otherwise consume viewport gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard zoom > 1 else { return }
        dragStart = (convert(event.locationInWindow, from: nil), center)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, zoom > 1,
              displayedVideoRect.width > 0, displayedVideoRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        center = CGPoint(x: start.center.x - (point.x - start.point.x) / displayedVideoRect.width,
                         y: start.center.y - (point.y - start.point.y) / displayedVideoRect.height)
        updateGeometry()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }
}
