import AppKit

// Replace only the external playback and movement clients. Exercise the real
// camera views and settings without contacting a camera or loading VLC.
@MainActor
final class CameraPlayer {
    enum State { case idle, connecting, playing, ended, failed }
    static var latest: CameraPlayer?
    var onStateChange: ((State) -> Void)?
    var videoSize: CGSize? = CGSize(width: 1280, height: 720)
    private(set) var plays = 0
    private(set) var stops = 0
    init() throws { Self.latest = self }
    func play(_ url: URL, in view: NSView) throws {
        plays += 1
        onStateChange?(.connecting)
    }
    func stop() { stops += 1; onStateChange?(.idle) }
}

struct CameraPreset: Equatable { let token: String; let name: String }

enum CameraDirection: CaseIterable { case up, down, left, right }

@MainActor
final class CameraPTZ {
    static var instances: [CameraPTZ] = []
    var preparation: CheckedContinuation<Void, Error>?
    var travel: CheckedContinuation<Void, Error>?
    var presets: [CameraPreset] = []
    var presetError: Error?
    var cleanup: CheckedContinuation<Void, Never>?
    init(settings: CameraSettings) { Self.instances.append(self) }
    func prepare() async throws {
        try await withCheckedThrowingContinuation { preparation = $0 }
    }
    func move(_ direction: CameraDirection) async throws {}
    func loadPresets() async throws -> [CameraPreset] {
        if let presetError { throw presetError }
        return presets
    }
    func savePreset(name: String, replacing token: String? = nil) async throws {
        presets.append(CameraPreset(token: "saved", name: name))
    }
    func removePreset(token: String) async throws {}
    func gotoPreset(token: String) async throws {
        try await withCheckedThrowingContinuation { travel = $0 }
    }
    // Allow a late response after cancellation to exercise the view's guard.
    func cancel() {}
    func waitUntilStopped() async {
        if travel != nil { await withCheckedContinuation { cleanup = $0 } }
    }
    func finish(_ error: Error? = nil) {
        if let error { preparation?.resume(throwing: error) }
        else { preparation?.resume() }
        preparation = nil
    }
}

@main
struct CameraConnectionTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); try await testPresetControls(); print("Camera connection ordering and failure isolation checks passed"); exit(0) }
            catch { fputs("Camera connection test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor
    static func run() async throws {
        guard let bundleID = Bundle.main.bundleIdentifier,
              bundleID.hasPrefix("local.nook.native.connection-tests.") else {
            throw failure("Run this test from its isolated test bundle")
        }
        let environment = CameraCredentialStore.defaultEnvironmentFile
        let directory = environment.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        try "NOOK_CAMERA_USERNAME=fixture-user\nNOOK_CAMERA_PASSWORD=fixture-password\n"
            .write(to: environment, atomically: true, encoding: .utf8)
        UserDefaults.standard.set("192.0.2.1", forKey: "cameraHost")
        let camera = CameraView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        defer { camera.deactivate() }
        let controls = camera.subviews.compactMap { $0 as? CameraControlsView }.first!
        let descendants = descendants(of: controls)
        let zoom = descendants.compactMap { $0 as? NSSlider }.first!
        let arrows = descendants.compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("moveCamera:") }

        camera.activate()
        let player = CameraPlayer.latest!
        try check(player.plays == 1, "Opening the camera must start video playback")
        try check(CameraPTZ.instances.isEmpty, "Movement discovery must wait until video is playing")
        try check(!zoom.isEnabled, "Zoom waits for live video")
        player.onStateChange?(.playing)
        try await waitUntil { CameraPTZ.instances.first?.preparation != nil }
        try check(!camera.renderTarget.isHidden && camera.canKeepPlaying && zoom.isEnabled,
                  "Video and Zoom must be available while movement discovery is pending")
        let first = CameraPTZ.instances[0]
        let stops = player.stops
        first.finish(failure("Movement controls unavailable"))
        try await waitUntil { controls.toolTip?.contains("Movement controls unavailable") == true }
        try check(!camera.renderTarget.isHidden && camera.canKeepPlaying && zoom.isEnabled && arrows.allSatisfy { !$0.isEnabled },
                  "Movement failure must leave live video and Zoom available")
        zoom.doubleValue = 2
        zoom.sendAction(zoom.action, to: zoom.target)
        try check(camera.renderTarget.zoom == 2 && player.plays == 1 && player.stops == stops,
                  "Zoom must work without stopping or restarting video after movement failure")
        player.onStateChange?(.playing)
        try check(CameraPTZ.instances.count == 1, "Repeated playing callbacks must not restart discovery")

        camera.reconnect()
        try check(CameraPTZ.instances.count == 1, "Reconnecting must also wait for video")
        player.onStateChange?(.playing)
        try await waitUntil { CameraPTZ.instances.last?.preparation != nil }
        let previous = CameraPTZ.instances.last!
        camera.reconnect()
        previous.finish()
        await Task.yield()
        try check(arrows.allSatisfy { !$0.isEnabled }, "Late discovery must not enable controls for a new stream")
        player.onStateChange?(.playing)
        try await waitUntil { CameraPTZ.instances.last?.preparation != nil }
        CameraPTZ.instances.last!.finish()
        try await waitUntil { arrows.allSatisfy(\.isEnabled) }
        player.onStateChange?(.failed)
        try check(arrows.allSatisfy { !$0.isEnabled } && !zoom.isEnabled,
                  "Losing video must disable movement and Zoom")

        for end in [CameraPlayer.State.idle, .ended, .failed] {
            camera.reconnect()
            let count = CameraPTZ.instances.count
            player.onStateChange?(end)
            player.onStateChange?(.playing)
            try check(CameraPTZ.instances.count == count, "Stopped or failed startup must discard pending discovery")
        }
        camera.reconnect()
        let count = CameraPTZ.instances.count
        camera.startPlayback(URL(fileURLWithPath: "/generated-fixture.mp4"))
        player.onStateChange?(.playing)
        try check(CameraPTZ.instances.count == count, "Local playback must not connect controls from an earlier stream")

        camera.reconnect()
        player.onStateChange?(.playing)
        try await waitUntil { CameraPTZ.instances.last?.preparation != nil }
        camera.deactivate()
        CameraPTZ.instances.last!.finish()
        await Task.yield()
        try check(!camera.canKeepPlaying && arrows.allSatisfy { !$0.isEnabled } && !zoom.isEnabled,
                  "Closing the camera must ignore late discovery results")
    }

    @MainActor
    static func testPresetControls() async throws {
        let controls = CameraControlsView(frame: NSRect(x: 0, y: 0, width: 850, height: 140))
        let buttons = descendants(of: controls).compactMap { $0 as? NSButton }
        let slots = buttons.filter { $0.action == NSSelectorFromString("activatePreset:") }
        try check(slots.count == 3 && slots.allSatisfy { !$0.isEnabled }, "Show exactly three disabled preset slots before connecting")
        let settings = try CameraSettings(host: "192.0.2.1", username: "fixture", password: "fixture")
        controls.connect(settings)
        try await waitUntil { CameraPTZ.instances.last?.preparation != nil }
        let client = CameraPTZ.instances.last!
        client.presets = [CameraPreset(token: "a", name: "Position 1"), CameraPreset(token: "b", name: "Position 2")]
        client.finish()
        try await waitUntil { slots[0].isEnabled && slots[1].isEnabled }
        try check(slots.map(\.title) == ["Position 1", "Position 2", "Position 3"] && !slots[2].isEnabled, "Show fixed position buttons and disable empty destinations")
        let setters = buttons.filter { $0.action == NSSelectorFromString("setPreset:") }
        try check(setters.count == 3 && setters.allSatisfy(\.isEnabled), "Each position has an enabled Set button")
        setters[2].performClick(nil)
        try await waitUntil { slots[2].isEnabled }
        try check(client.presets.last?.name == "Position 3", "Set must save the correct slot and immediately enable its destination")
        slots[0].performClick(nil)
        try await waitUntil { client.travel != nil }
        try check(buttons.filter { $0.action == NSSelectorFromString("moveCamera:") || $0.action == NSSelectorFromString("activatePreset:") || $0.action == NSSelectorFromString("setPreset:") }.allSatisfy { !$0.isEnabled }, "Disable arrows and presets while travelling")
        controls.connect(settings)
        let replacement = CameraPTZ.instances.last!
        try await waitUntil { client.cleanup != nil }
        try check(replacement.preparation == nil && slots.allSatisfy { !$0.isEnabled }, "Reconnect must wait for previous physical movement cleanup")
        client.travel?.resume(); client.travel = nil
        client.cleanup?.resume(); client.cleanup = nil
        try await waitUntil { replacement.preparation != nil }
        let failed = CameraPTZ.instances.last!
        failed.presetError = failure("Presets unavailable")
        failed.finish()
        let arrows = buttons.filter { $0.action == NSSelectorFromString("moveCamera:") }
        try await waitUntil { arrows.allSatisfy(\.isEnabled) }
        try check(slots.allSatisfy { !$0.isEnabled }, "Preset discovery failure must leave arrows available")
        controls.stop()
    }

    @MainActor
    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CameraConnectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw failure("Timed out waiting for the expected camera state")
    }
}
