import AppKit

enum CameraPiPCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    fileprivate var isRight: Bool { self == .topRight || self == .bottomRight }
    fileprivate var isTop: Bool { self == .topLeft || self == .topRight }
    fileprivate var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

@MainActor
final class CameraPiPView: NSView {
    let videoContainer = NSView()
    var onReturnToCamera: (() -> Void)?
    private(set) var corner: CameraPiPCorner
    private let defaults: UserDefaults
    private var anchors: [NSLayoutConstraint] = []
    private var dragStart: (point: NSPoint, origin: NSPoint)?
    private var dragging = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        corner = defaults.string(forKey: "cameraPiPCorner").flatMap(CameraPiPCorner.init(rawValue:)) ?? .bottomRight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        videoContainer.wantsLayer = true
        videoContainer.layer?.backgroundColor = NSColor.black.cgColor
        videoContainer.layer?.cornerRadius = 14
        videoContainer.layer?.cornerCurve = .continuous
        videoContainer.layer?.masksToBounds = true
        videoContainer.layer?.borderWidth = 1
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoContainer)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320), heightAnchor.constraint(equalToConstant: 180),
            videoContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoContainer.topAnchor.constraint(equalTo: topAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Camera picture in picture")
        setAccessibilityHelp("Drag to a corner. Double-click or press Return to open Camera. Use arrow keys to move between corners.")
        toolTip = "Drag to a corner · Double-click to open Camera"
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(in host: NSView) {
        if superview !== host {
            NSLayoutConstraint.deactivate(anchors)
            removeFromSuperview()
        }
        host.addSubview(self, positioned: .above, relativeTo: nil)
        isHidden = false
        snap(to: corner)
    }

    func dismiss() {
        dragStart = nil
        dragging = false
        NSLayoutConstraint.deactivate(anchors)
        anchors = []
        removeFromSuperview()
    }

    func snap(to corner: CameraPiPCorner) {
        self.corner = corner
        defaults.set(corner.rawValue, forKey: "cameraPiPCorner")
        guard let host = superview else { return }
        NSLayoutConstraint.deactivate(anchors)
        anchors = [
            corner.isRight ? trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16)
                           : leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            corner.isTop ? topAnchor.constraint(equalTo: host.topAnchor, constant: 16)
                         : bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16)
        ]
        NSLayoutConstraint.activate(anchors)
        host.layoutSubtreeIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors(focused: Bool? = nil) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hasFocus = focused ?? (window?.firstResponder === self)
            videoContainer.layer?.borderColor = (hasFocus ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(dark ? 0.24 : 0.5)).cgColor
            videoContainer.layer?.borderWidth = hasFocus ? 2 : 1
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.25)
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowBlurRadius = 10
            self.shadow = shadow
        }
    }

    // VLC installs child views which otherwise consume mouse events meant for dragging.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { updateColors(focused: true); return true }
    override func resignFirstResponder() -> Bool { updateColors(focused: false); return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard event.clickCount < 2 else { onReturnToCamera?(); return }
        guard let host = superview else { return }
        dragStart = (host.convert(event.locationInWindow, from: nil), frame.origin)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host = superview, let start = dragStart else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        if !dragging {
            NSLayoutConstraint.deactivate(anchors)
            dragging = true
        }
        let limit = host.bounds.insetBy(dx: 16, dy: 16)
        setFrameOrigin(NSPoint(x: min(max(start.origin.x + point.x - start.point.x, limit.minX), limit.maxX - frame.width),
                               y: min(max(start.origin.y + point.y - start.point.y, limit.minY), limit.maxY - frame.height)))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragging = false }
        guard dragging, let host = superview else { return }
        let right = frame.midX >= host.bounds.midX
        let top = host.isFlipped ? frame.midY < host.bounds.midY : frame.midY >= host.bounds.midY
        snap(to: top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: snap(to: corner.isTop ? .topLeft : .bottomLeft)
        case 124: snap(to: corner.isTop ? .topRight : .bottomRight)
        case 125: snap(to: corner.isRight ? .bottomRight : .bottomLeft)
        case 126: snap(to: corner.isRight ? .topRight : .topLeft)
        case 36, 76: onReturnToCamera?()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { onReturnToCamera?(); return onReturnToCamera != nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (index, corner) in CameraPiPCorner.allCases.enumerated() {
            let item = NSMenuItem(title: corner.title, action: #selector(moveFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = self.corner == corner ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Camera", action: #selector(openCamera), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func moveFromMenu(_ item: NSMenuItem) { snap(to: CameraPiPCorner.allCases[item.tag]) }
    @objc private func openCamera() { onReturnToCamera?() }
}
