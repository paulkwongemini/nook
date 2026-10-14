import AppKit

@MainActor
final class CameraControlsView: NSView {
    var onZoomChange: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var directionButtons: [NSButton] = []
    private let directionStatus = NSTextField(wrappingLabelWithString: "Connect to move the camera.")
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let zoomValue = NSTextField(labelWithString: "1.0×")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private var ptz: CameraPTZ?
    private var movementTask: Task<Void, Never>?
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildView() {
        let directions = [("chevron.up", "up"), ("chevron.down", "down"),
                          ("chevron.left", "left"), ("chevron.right", "right")]
        for (index, item) in directions.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: item.0, accessibilityDescription: nil)!,
                                  target: self, action: #selector(moveCamera(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.setAccessibilityLabel("Move camera \(item.1)")
            button.toolTip = "Move camera \(item.1) a short step."
            button.isEnabled = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            directionButtons.append(button)
        }
        let middle = NSStackView(views: [directionButtons[2], directionButtons[3]])
        middle.spacing = 26
        let pad = NSStackView(views: [directionButtons[0], middle, directionButtons[1]])
        pad.orientation = .vertical
        pad.spacing = 2
        pad.alignment = .centerX
        let directionTitle = NSTextField(labelWithString: "Pan & Tilt")
        directionTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let directionInfo = NSStackView(views: [directionTitle, directionStatus])
        directionInfo.orientation = .vertical
        directionInfo.alignment = .leading
        directionInfo.spacing = 6

        directionStatus.font = .systemFont(ofSize: 11)
        directionStatus.textColor = .secondaryLabelColor
        directionStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let zoomTitle = NSTextField(labelWithString: "Zoom")
        zoomTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        zoomSlider.target = self
        zoomSlider.action = #selector(changeZoom)
        zoomSlider.isContinuous = true
        zoomSlider.setAccessibilityLabel("Digital zoom")
        zoomSlider.toolTip = "Enlarge the video without moving the camera. Drag the enlarged image to pan."
        zoomSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        zoomValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        resetButton.target = self; resetButton.action = #selector(resetZoom)
        resetButton.toolTip = "Return to the full image."
        let videoControls = NSStackView(views: [zoomTitle, zoomSlider, zoomValue, resetButton])
        videoControls.spacing = 10
        [pad, directionInfo, videoControls].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: leadingAnchor), pad.centerYAnchor.constraint(equalTo: centerYAnchor),
            pad.widthAnchor.constraint(equalToConstant: 90),
            directionInfo.leadingAnchor.constraint(equalTo: pad.trailingAnchor, constant: 14),
            directionInfo.centerYAnchor.constraint(equalTo: centerYAnchor),
            directionInfo.widthAnchor.constraint(equalToConstant: 180),
            directionStatus.widthAnchor.constraint(equalTo: directionInfo.widthAnchor),
            videoControls.leadingAnchor.constraint(equalTo: directionInfo.trailingAnchor, constant: 28),
            videoControls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            videoControls.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setVideoEnabled(false)
    }

    func setVideoEnabled(_ enabled: Bool) {
        zoomSlider.isEnabled = enabled
        resetButton.isEnabled = enabled
    }

    func updateZoom(_ zoom: CGFloat) {
        zoomSlider.doubleValue = Double(zoom)
        zoomValue.stringValue = String(format: "%.1f×", Double(zoom))
    }

    @objc private func changeZoom() { onZoomChange?(CGFloat(zoomSlider.doubleValue)) }
    @objc private func resetZoom() { onReset?() }

    func connect(_ settings: CameraSettings) {
        stop()
        let current = generation
        let ptz = CameraPTZ(settings: settings)
        self.ptz = ptz
        directionStatus.stringValue = "Connecting camera controls…"
        movementTask = Task { [weak self] in
            do {
                try await ptz.prepare()
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.directionButtons.forEach { $0.isEnabled = true }
                self.directionStatus.stringValue = "Click an arrow to move a short step."
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.showError(error)
            }
        }
    }

    func stop() {
        generation += 1
        movementTask?.cancel()
        movementTask = nil
        ptz?.cancel()
        ptz = nil
        directionButtons.forEach { $0.isEnabled = false }
        directionStatus.textColor = .secondaryLabelColor
        directionStatus.stringValue = "Reconnect to use camera controls."
    }

    @objc private func moveCamera(_ sender: NSButton) {
        let directions = CameraDirection.allCases
        guard sender.isEnabled, directions.indices.contains(sender.tag), let ptz else { return }
        let current = generation
        directionButtons.forEach { $0.isEnabled = false }
        directionStatus.stringValue = "Moving…"
        movementTask = Task { [weak self] in
            do {
                try await ptz.move(directions[sender.tag])
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.directionButtons.forEach { $0.isEnabled = true }
                self.directionStatus.stringValue = "Click an arrow to move a short step."
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        directionStatus.textColor = .systemRed
        directionStatus.stringValue = error.localizedDescription + " Click Reconnect to try again."
    }
}
