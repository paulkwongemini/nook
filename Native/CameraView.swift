import AppKit

@MainActor
final class CameraView: NSView {
    let renderTarget = CameraVideoView()
    private let form = NSStackView()
    private let hostField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let cameraControls = CameraControlsView(frame: .zero)
    private let formError = NSTextField(wrappingLabelWithString: "")
    private let accountNote = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "Set up your camera")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let installButton = NSButton(title: "Get VLC", target: nil, action: nil)
    private let keepOpenButton = NSButton(title: "Keep Open", target: nil, action: nil)
    private let credentials = CameraCredentialStore()
    private var settings: CameraSettings?
    private var player: CameraPlayer?
    private(set) var isActive = false
    private var editing = false
    private var playbackState: CameraPlayer.State = .idle
    private var lastNotifiedEligibility = false
    private var fullVideoConstraints: [NSLayoutConstraint] = []
    private var externalVideoConstraints: [NSLayoutConstraint] = []
    private(set) var keepOpen = false
    var onPresentationChange: (() -> Void)?
    var canKeepPlaying: Bool {
        guard isActive, !editing else { return false }
        switch playbackState {
        case .connecting, .playing: return true
        case .idle, .ended, .failed: return false
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildView() {
        let title = NSTextField(labelWithString: "Camera")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let settingsButton = NSButton(title: "Settings", target: self, action: #selector(editSettings))
        reconnectButton.target = self; reconnectButton.action = #selector(retry)
        stopButton.target = self; stopButton.action = #selector(stopPlayback)
        installButton.target = self; installButton.action = #selector(installVLC)
        keepOpenButton.setButtonType(.pushOnPushOff)
        keepOpenButton.bezelStyle = reconnectButton.bezelStyle
        keepOpenButton.target = self; keepOpenButton.action = #selector(toggleKeepOpen)
        keepOpenButton.toolTip = "Keep camera video and audio playing while you use other tabs."
        let heading = NSStackView(views: [title, status, keepOpenButton, reconnectButton, stopButton, settingsButton])
        heading.orientation = .horizontal
        heading.spacing = 14
        heading.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.insertArrangedSubview(spacer, at: 2)

        renderTarget.wantsLayer = true
        renderTarget.layer?.backgroundColor = NSColor.black.cgColor
        renderTarget.setAccessibilityLabel("Live camera video")
        renderTarget.onZoomChange = { [weak self] in self?.cameraControls.updateZoom($0) }
        cameraControls.onZoomChange = { [weak self] in self?.renderTarget.setZoom($0) }
        cameraControls.onReset = { [weak self] in self?.renderTarget.resetView() }
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        let empty = NSStackView(views: [message, installButton])
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 16
        installButton.isHidden = true
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        let intro = NSTextField(wrappingLabelWithString: "Use the camera account you created in Tapo. Connect your home VPN when viewing from outside home.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 13)
        form.addArrangedSubview(intro)
        for (label, field, placeholder) in [("Camera IP address", hostField, "192.168.1.100"),
                                           ("Camera username", usernameField, "Username"),
                                           ("Camera password", passwordField, "Password")] {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 12, weight: .medium)
            field.placeholderString = placeholder
            field.setAccessibilityLabel(label)
            field.font = .systemFont(ofSize: 14)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            let row = NSStackView(views: [caption, field])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 5
            form.addArrangedSubview(row)
        }
        passwordField.target = self; passwordField.action = #selector(saveAndConnect)
        let save = NSButton(title: "Save and Connect", target: self, action: #selector(saveAndConnect))
        save.bezelStyle = .rounded
        form.addArrangedSubview(save)
        formError.textColor = .systemRed
        formError.font = .systemFont(ofSize: 12)
        form.addArrangedSubview(formError)
        accountNote.textColor = .secondaryLabelColor
        accountNote.font = .systemFont(ofSize: 11)
        form.addArrangedSubview(accountNote)
        updateAccountSource(nil)

        [heading, renderTarget, empty, form, cameraControls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        fullVideoConstraints = [
            renderTarget.leadingAnchor.constraint(equalTo: leadingAnchor), renderTarget.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderTarget.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            renderTarget.bottomAnchor.constraint(equalTo: cameraControls.topAnchor, constant: -8)
        ]
        NSLayoutConstraint.activate(fullVideoConstraints)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            form.centerXAnchor.constraint(equalTo: centerXAnchor), form.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 24),
            form.widthAnchor.constraint(equalToConstant: 340), intro.widthAnchor.constraint(equalTo: form.widthAnchor),
            formError.widthAnchor.constraint(equalTo: form.widthAnchor), accountNote.widthAnchor.constraint(equalTo: form.widthAnchor),
            cameraControls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            cameraControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            cameraControls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            cameraControls.heightAnchor.constraint(equalToConstant: 96)
        ])
        renderTarget.isHidden = true
        cameraControls.isHidden = true
        stopButton.isEnabled = false
        reconnectButton.isEnabled = false
    }

    func setKeepOpen(_ enabled: Bool) {
        guard keepOpen != enabled else { return }
        keepOpen = enabled
        keepOpenButton.state = enabled ? .on : .off
        keepOpenButton.bezelColor = enabled ? .controlAccentColor : nil
        keepOpenButton.contentTintColor = enabled ? .white : nil
        onPresentationChange?()
    }

    func moveVideo(to container: NSView) {
        if container === self { restoreVideo(); return }
        guard renderTarget.superview !== container else { return }
        NSLayoutConstraint.deactivate(fullVideoConstraints + externalVideoConstraints)
        renderTarget.removeFromSuperview()
        container.addSubview(renderTarget)
        externalVideoConstraints = [
            renderTarget.leadingAnchor.constraint(equalTo: container.leadingAnchor), renderTarget.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            renderTarget.topAnchor.constraint(equalTo: container.topAnchor), renderTarget.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        NSLayoutConstraint.activate(externalVideoConstraints)
    }

    func restoreVideo() {
        guard renderTarget.superview !== self else { return }
        NSLayoutConstraint.deactivate(externalVideoConstraints)
        externalVideoConstraints.removeAll()
        renderTarget.removeFromSuperview()
        addSubview(renderTarget, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate(fullVideoConstraints)
    }

    private func notifyEligibilityChange() {
        guard lastNotifiedEligibility != canKeepPlaying else { return }
        lastNotifiedEligibility = canKeepPlaying
        onPresentationChange?()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        do {
            try loadSettings()
            if editing || settings == nil { showSettings() }
            else { reconnect() }
        } catch { showSettings(error: (error as? CameraSettingsError)?.errorDescription ?? "Could not load camera settings. Please try again.") }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        cameraControls.setVideoEnabled(false)
        cameraControls.stop()
        player?.stop()
        settings = nil
        passwordField.stringValue = ""
        renderTarget.isHidden = true
        status.stringValue = "Stopped"
        stopButton.isEnabled = false
        reconnectButton.isEnabled = false
        playbackState = .idle
        notifyEligibilityChange()
    }

    func reconnect() {
        guard isActive else { return }
        guard let settings else { showSettings(); return }
        do {
            startPlayback(try settings.streamURL())
            cameraControls.connect(settings)
        }
        catch { showSettings(error: "Check the camera IP address.") }
    }

    func startPlayback(_ url: URL) {
        guard isActive else { return }
        editing = false
        renderTarget.resetView()
        cameraControls.setVideoEnabled(false)
        cameraControls.stop()
        cameraControls.isHidden = false
        playbackState = .connecting
        defer { notifyEligibilityChange() }
        form.isHidden = true
        installButton.isHidden = true
        message.stringValue = "Connecting to your camera…"
        renderTarget.isHidden = true
        status.stringValue = "Connecting…"
        reconnectButton.isEnabled = false
        stopButton.isEnabled = true
        do {
            if player == nil {
                player = try CameraPlayer()
                player?.onStateChange = { [weak self] state in self?.playerChanged(state) }
            }
        } catch {
            playbackState = .failed
            status.stringValue = "VLC needed"
            message.stringValue = "Install the official VLC app in Applications, then reconnect. Nook uses VLC to play your camera inside this tab."
            installButton.isHidden = false
            stopButton.isEnabled = false
            reconnectButton.isEnabled = true
            return
        }
        do { try player?.play(url, in: renderTarget.drawable) }
        catch { player?.stop(); playerChanged(.failed) }
    }

    func showSettings() { showSettings(error: nil) }
    private func showSettings(error: String?) {
        editing = true
        cameraControls.setVideoEnabled(false)
        cameraControls.stop()
        cameraControls.isHidden = true
        playbackState = .idle
        player?.stop()
        notifyEligibilityChange()
        renderTarget.isHidden = true
        form.isHidden = false
        message.stringValue = ""
        installButton.isHidden = true
        stopButton.isEnabled = false
        reconnectButton.isEnabled = false
        status.stringValue = "Camera settings"
        formError.stringValue = error ?? ""
        hostField.stringValue = UserDefaults.standard.string(forKey: "cameraHost") ?? ""
        usernameField.stringValue = ""
        passwordField.stringValue = ""
        updateAccountSource(nil)
        if isActive, error == nil {
            do {
                let environmentAccount = try credentials.loadEnvironmentAccount()
                let account = try environmentAccount ?? credentials.load()
                usernameField.stringValue = account?.username ?? ""
                passwordField.stringValue = account?.password ?? ""
                updateAccountSource(environmentAccount)
            } catch { formError.stringValue = (error as? CameraSettingsError)?.errorDescription ?? "Could not load camera settings. Please try again." }
        }
        window?.makeFirstResponder(hostField)
    }

    private func updateAccountSource(_ environmentAccount: CameraAccount?) {
        usernameField.isEditable = environmentAccount == nil
        passwordField.isEditable = environmentAccount == nil
        if let account = environmentAccount {
            usernameField.stringValue = account.username
            passwordField.stringValue = account.password
        }
        let source = environmentAccount == nil
            ? "Your camera account is saved in macOS Keychain."
            : "Your camera account is loaded from .env. Edit that file to change the username or password. You can save the camera IP address here."
        accountNote.stringValue = source + " Turn on Keep Open to watch while using other tabs. Closing the window stops playback."
    }

    private func loadSettings() throws {
        guard let account = try credentials.load(), let host = UserDefaults.standard.string(forKey: "cameraHost") else {
            settings = nil
            return
        }
        settings = try CameraSettings(host: host, username: account.username, password: account.password)
    }

    @objc private func saveAndConnect() {
        guard isActive else { return }
        let wasUsingEnvironmentAccount = !usernameField.isEditable
        if wasUsingEnvironmentAccount {
            usernameField.stringValue = ""
            passwordField.stringValue = ""
        }
        updateAccountSource(nil)
        do {
            let environmentAccount = try credentials.loadEnvironmentAccount()
            if environmentAccount == nil, wasUsingEnvironmentAccount {
                let account = try credentials.load()
                usernameField.stringValue = account?.username ?? ""
                passwordField.stringValue = account?.password ?? ""
            }
            updateAccountSource(environmentAccount)
            let value = try CameraSettings(host: hostField.stringValue,
                                           username: environmentAccount?.username ?? usernameField.stringValue,
                                           password: environmentAccount?.password ?? passwordField.stringValue)
            if environmentAccount == nil { try credentials.save(value) }
            UserDefaults.standard.set(value.host, forKey: "cameraHost")
            settings = value
            passwordField.stringValue = ""
            formError.stringValue = ""
            reconnect()
        } catch { formError.stringValue = (error as? CameraSettingsError)?.errorDescription ?? "Could not save the camera account. Please try again." }
    }
    @objc private func editSettings() { showSettings() }
    @objc private func retry() {
        do {
            try loadSettings()
            reconnect()
        } catch { showSettings(error: (error as? CameraSettingsError)?.errorDescription ?? "Could not load camera settings. Please try again.") }
    }
    @objc private func toggleKeepOpen() { setKeepOpen(keepOpenButton.state == .on) }
    @objc private func stopPlayback() {
        cameraControls.stop()
        player?.stop()
        playerChanged(.idle)
    }
    @objc private func installVLC() {
        if let url = URL(string: "https://www.videolan.org/vlc/") { NSWorkspace.shared.open(url) }
    }

    private func playerChanged(_ state: CameraPlayer.State) {
        playbackState = state
        cameraControls.setVideoEnabled(isActive && !editing && state == .playing)
        defer { notifyEligibilityChange() }
        guard isActive, !editing else { return }
        renderTarget.isHidden = true
        stopButton.isEnabled = false
        reconnectButton.isEnabled = true
        switch state {
        case .idle: status.stringValue = "Stopped"; message.stringValue = "Video stopped."
        case .connecting:
            status.stringValue = "Connecting…"; message.stringValue = "Connecting to your camera…"
            stopButton.isEnabled = true
            reconnectButton.isEnabled = false
        case .playing:
            if let size = player?.videoSize { renderTarget.videoSize = size }
            status.stringValue = "Live"; message.stringValue = ""
            renderTarget.isHidden = false
            stopButton.isEnabled = true
        case .ended: status.stringValue = "Disconnected"; message.stringValue = "The stream ended. Reconnect to watch again."
        case .failed: status.stringValue = "Could not connect"; message.stringValue = "Check that your home VPN is connected and the camera account is correct, then reconnect."
        }
    }
}
