import AppKit
import Darwin

// A generated local clip exercises optional VLC loading, native embedding, and
// rapid reconnect/stop. This must never receive a private camera URL.
@main
struct CameraPlayerSmoke {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: CameraPlayerSmoke <generated local clip>\n", stderr)
            exit(2)
        }
        let clip = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Nook generated camera playback test"
        let root = window.contentView!
        let fullHost = NSView(frame: root.bounds)
        let miniHost = NSView(frame: NSRect(x: 380, y: 20, width: 240, height: 135))
        miniHost.wantsLayer = true
        miniHost.layer?.cornerRadius = 12
        miniHost.layer?.masksToBounds = true
        root.addSubview(fullHost)
        root.addSubview(miniHost)
        miniHost.isHidden = true
        let view = NSView(frame: fullHost.bounds)
        view.autoresizingMask = [.width, .height]
        fullHost.addSubview(view)
        window.orderFront(nil)
        Task { @MainActor in
            do {
                let player = try CameraPlayer()
                var state = CameraPlayer.State.idle
                player.onStateChange = { state = $0 }
                for round in 0..<3 {
                    try player.play(clip, in: view)
                    try await waitUntil("Generated clip must play in Nook's NSView") {
                        state == .playing && !view.subviews.isEmpty
                    }
                    if round == 0 {
                        try await checkReparenting(player, view: view, fullHost: fullHost, miniHost: miniHost)
                    }
                    player.stop()
                    try await waitUntil("Stopping must release the native video view") {
                        view.subviews.isEmpty
                    }
                }
                // A queued stop must not stop the next session or revive old callbacks.
                try player.play(clip, in: view)
                player.stop()
                try player.play(clip, in: view)
                try await waitUntil("Rapid reconnect must show the newest session") {
                    state == .playing && !view.subviews.isEmpty
                }
                player.stop()
                try await waitUntil("Final stop must complete without blocking AppKit") {
                    view.subviews.isEmpty
                }
                // Reject unsupported schemes without echoing even fake credentials.
                do {
                    try player.play(URL(string: "https://fixture-user:fixture-password@localhost/")!, in: view)
                    throw NSError(domain: "CameraPlayerSmoke", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Unsupported address was accepted"])
                } catch {
                    if error.localizedDescription.contains("fixture-") ||
                       error.localizedDescription == "Unsupported address was accepted" { throw error }
                }
                try player.play(URL(string: "rtsp://fixture-user:fixture-password@127.0.0.1:1/stream1")!, in: view)
                try await waitUntil("Connection failure must report a safe, recoverable failure", timeout: 25) { state == .failed }
                try player.play(clip, in: view)
                try await waitUntil("Playback must recover after a failed connection") {
                    state == .playing && !view.subviews.isEmpty
                }
                player.stop()
                try await waitUntil("Failed connection recovery must also stop cleanly") { view.subviews.isEmpty }
                print("Camera player: embedded video, repeated stop, rapid reconnect, failure recovery, and uninterrupted mini-player passed")
                window.orderOut(nil)
                exit(0)
            } catch {
                fputs("Camera player smoke failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    static func checkReparenting(_ camera: CameraPlayer, view: NSView, fullHost: NSView, miniHost: NSView) async throws {
        var before = try await playbackSnapshot(camera)
        let videoView = view.subviews.first
        for host in [miniHost, fullHost] {
            view.removeFromSuperview()
            host.addSubview(view)
            view.frame = host.bounds
            miniHost.isHidden = host !== miniHost
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let after = try await playbackSnapshot(camera)
            guard after.player == before.player, after.time > before.time,
                  after.volume == 100, after.muted == 0,
                  view.subviews.first === videoView,
                  view.subviews.first?.frame.size == host.bounds.size else {
                throw NSError(domain: "CameraPlayerSmoke", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Moving the video must preserve its player, advancing clock, audio, and fitted video layer"])
            }
            before = after
        }
    }

    struct PlaybackSnapshot {
        let player: OpaquePointer
        let time: Int64
        let volume: Int32
        let muted: Int32
    }

    @MainActor
    static func playbackSnapshot(_ camera: CameraPlayer) async throws -> PlaybackSnapshot {
        guard let playback = Mirror(reflecting: camera).descendant("playback"),
              let queue = Mirror(reflecting: playback).descendant("queue") as? DispatchQueue,
              let library = dlopen(nil, RTLD_NOW),
              let timeSymbol = dlsym(library, "libvlc_media_player_get_time"),
              let volumeSymbol = dlsym(library, "libvlc_audio_get_volume"),
              let muteSymbol = dlsym(library, "libvlc_audio_get_mute") else {
            throw NSError(domain: "CameraPlayerSmoke", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot inspect real VLC playback"])
        }
        defer { dlclose(library) }
        let getTime = unsafeBitCast(timeSymbol, to: (@convention(c) (OpaquePointer) -> Int64).self)
        let getVolume = unsafeBitCast(volumeSymbol, to: (@convention(c) (OpaquePointer) -> Int32).self)
        let getMute = unsafeBitCast(muteSymbol, to: (@convention(c) (OpaquePointer) -> Int32).self)
        let actual: PlaybackSnapshot? = await withCheckedContinuation { continuation in
            queue.async {
                guard let player = Mirror(reflecting: playback).descendant("player") as? OpaquePointer else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PlaybackSnapshot(player: player, time: getTime(player),
                                                               volume: getVolume(player), muted: getMute(player)))
            }
        }
        guard let actual else {
            throw NSError(domain: "CameraPlayerSmoke", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Playback unexpectedly stopped"])
        }
        return actual
    }

    @MainActor
    static func waitUntil(_ message: String, timeout: Int = 10, _ condition: () -> Bool) async throws {
        for _ in 0..<(timeout * 10) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "CameraPlayerSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
