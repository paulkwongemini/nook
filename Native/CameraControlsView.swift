import AppKit

@MainActor
final class CameraControlsView: NSView {
    var onZoomChange: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var directionButtons: [NSButton] = []
    private let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let zoomValue = NSTextField(labelWithString: "1.0×")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private var ptz: CameraPTZ?
    private var movementTask: Task<Void, Never>?
    private var generation = 0
    private var presets: [CameraPreset] = []
    private var presetButtons: [NSButton] = []
    private var presetSetButtons: [NSButton] = []
    private var cleanupTask: Task<Void, Never>?
    private var presetsAvailable = false

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
        let positions = NSStackView()
        positions.orientation = .vertical
        positions.alignment = .leading
        positions.spacing = 2
        for index in 0..<3 {
            let button = NSButton(title: "Position \(index + 1)", target: self, action: #selector(activatePreset(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let setter = NSButton(title: "Set", target: self, action: #selector(setPreset(_:)))
            setter.bezelStyle = .rounded
            setter.tag = index
            setter.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let row = NSStackView(views: [button, setter])
            row.spacing = 4
            positions.addArrangedSubview(row)
            presetButtons.append(button)
            presetSetButtons.append(setter)
        }
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
        [pad, positions, videoControls].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: leadingAnchor), pad.centerYAnchor.constraint(equalTo: centerYAnchor),
            pad.widthAnchor.constraint(equalToConstant: 90),
            positions.leadingAnchor.constraint(equalTo: pad.trailingAnchor, constant: 14),
            positions.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoControls.leadingAnchor.constraint(equalTo: positions.trailingAnchor, constant: 28),
            videoControls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            videoControls.centerYAnchor.constraint(equalTo: pad.centerYAnchor)
        ])
        updatePresetButtons(enabled: false)
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

    func waitForVideo() {
        stop()
        setStatus("Waiting for live video…")
    }

    func connect(_ settings: CameraSettings) {
        stop()
        let current = generation
        let cleanup = cleanupTask
        let ptz = CameraPTZ(settings: settings)
        self.ptz = ptz
        setStatus("Connecting camera controls…")
        movementTask = Task { [weak self] in
            do {
                await cleanup?.value
                guard let self, self.generation == current, !Task.isCancelled else { return }
                try await ptz.prepare()
                guard self.generation == current, !Task.isCancelled else { return }
                self.setStatus("Loading presets…")
                do {
                    let presets = try await ptz.loadPresets()
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.presets = Array(presets.prefix(3))
                    self.presetsAvailable = true
                    self.updatePresetButtons(enabled: true)
                    self.setStatus("Click an arrow or a saved position.")
                } catch {
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.setStatus("Presets unavailable. Reconnect to retry.")
                }
                self.directionButtons.forEach { $0.isEnabled = true }
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
        let previous = ptz
        previous?.cancel()
        let pendingCleanup = cleanupTask
        cleanupTask = Task {
            await pendingCleanup?.value
            await previous?.waitUntilStopped()
        }
        ptz = nil
        presets = []
        presetsAvailable = false
        updatePresetButtons(enabled: false)
        directionButtons.forEach { $0.isEnabled = false }

        setStatus("Reconnect to use camera controls.")
    }

    @objc private func moveCamera(_ sender: NSButton) {
        let directions = CameraDirection.allCases
        guard sender.isEnabled, directions.indices.contains(sender.tag), let ptz else { return }
        let current = generation
        directionButtons.forEach { $0.isEnabled = false }
        updatePresetButtons(enabled: false)

        setStatus("Moving…")
        movementTask = Task { [weak self] in
            do {
                try await ptz.move(directions[sender.tag])
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.directionButtons.forEach { $0.isEnabled = true }
                self.updatePresetButtons(enabled: true)
                self.setStatus("Click an arrow to move a short step.")
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.showError(error)
            }
        }
    }

    private func preset(at index: Int) -> CameraPreset? {
        presets.first { $0.name == "Position \(index + 1)" }
    }

    private func updatePresetButtons(enabled: Bool) {
        for index in 0..<3 {
            let preset = preset(at: index)
            let name = "Position \(index + 1)"
            presetButtons[index].title = name
            presetButtons[index].toolTip = preset == nil ? "Use Set to save this position." : "Move camera to \(name)."
            presetButtons[index].setAccessibilityLabel("Move to \(name)")
            presetButtons[index].isEnabled = enabled && presetsAvailable && preset != nil
            presetSetButtons[index].title = "Set"
            presetSetButtons[index].isEnabled = enabled && presetsAvailable
            presetSetButtons[index].toolTip = "Save the current camera direction as \(name)."
            presetSetButtons[index].setAccessibilityLabel("Set \(name)")
            // Keep deletion available without adding another visible control.
            let menu = NSMenu()
            let delete = NSMenuItem(title: "Delete Saved Position", action: #selector(deletePreset(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = preset
            delete.isEnabled = enabled && preset != nil
            menu.autoenablesItems = false
            menu.addItem(delete)
            presetButtons[index].menu = menu
        }
    }

    @objc private func activatePreset(_ sender: NSButton) {
        guard sender.isEnabled, let preset = preset(at: sender.tag) else { return }
        performPresetAction(status: "Moving to \(preset.name)…") { try await $0.gotoPreset(token: preset.token) }
        sender.title = "Moving…"
    }

    @objc private func setPreset(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        let current = generation
        let name = "Position \(sender.tag + 1)"
        let existing = preset(at: sender.tag)
        if existing != nil {
            guard confirm(title: "Replace \(name)?", detail: "The current camera direction will replace this saved position.", action: "Replace"),
                  generation == current else { return }
        }
        performPresetAction(status: "Saving \(name)…") { try await $0.savePreset(name: name, replacing: existing?.token) }
        sender.title = "…"
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        let current = generation
        guard let preset = sender.representedObject as? CameraPreset,
              confirm(title: "Delete \(preset.name)?", detail: "This saved position will be removed from the camera.", action: "Delete"),
              generation == current else { return }
        performPresetAction(status: "Deleting position…") { try await $0.removePreset(token: preset.token) }
    }

    private func confirm(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func performPresetAction(status: String, operation: @escaping (CameraPTZ) async throws -> Void) {
        guard let ptz, presetsAvailable, presetSetButtons.contains(where: \.isEnabled) else { return }
        let current = generation
        directionButtons.forEach { $0.isEnabled = false }
        updatePresetButtons(enabled: false)

        setStatus(status)
        movementTask = Task { [weak self] in
            do {
                try await operation(ptz)
                let presets = try await ptz.loadPresets()
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.presets = Array(presets.prefix(3))
                self.directionButtons.forEach { $0.isEnabled = true }
                self.updatePresetButtons(enabled: true)
                self.setStatus("Click an arrow or a saved position.")
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.showError(error)
            }
        }
    }

    private func setStatus(_ message: String) {
        toolTip = message
        setAccessibilityHelp(message)
    }

    private func showError(_ error: Error) {
        let message = error.localizedDescription + " Click Reconnect to try again."
        setStatus(message)
        updatePresetButtons(enabled: false)
        if let window {
            let alert = NSAlert()
            alert.messageText = "Camera controls unavailable"
            alert.informativeText = message
            alert.beginSheetModal(for: window)
        }
    }
}
