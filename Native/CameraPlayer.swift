import AppKit
import Darwin

/// Optional VLC playback. Google services remain usable without VLC installed.
@MainActor
final class CameraPlayer {
    enum State { case idle, connecting, playing, ended, failed }
    var onStateChange: ((State) -> Void)?
    private(set) var videoSize: CGSize?
    private let playback: VLCPlayback
    private var generation = 0

    init() throws { playback = VLCPlayback(api: try VLCAPI.load()) }

    func play(_ url: URL, in view: NSView) throws {
        guard url.isFileURL || (url.scheme?.lowercased() == "rtsp" && url.host?.isEmpty == false) else {
            throw CameraPlaybackError.invalidAddress
        }
        generation += 1
        videoSize = nil
        let request = generation
        onStateChange?(.connecting)
        playback.play(url, in: view) { [weak self] state, size in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.videoSize = size
                self.onStateChange?(state)
            }
        }
    }

    func stop() {
        generation += 1
        videoSize = nil
        playback.stop()
        onStateChange?(.idle)
    }

    deinit { playback.stop() }
}

private enum CameraPlaybackError: LocalizedError {
    case missingVLC, incompatibleVLC, invalidAddress
    var errorDescription: String? {
        switch self {
        case .missingVLC: return "Install VLC in Applications to watch the camera inside Nook."
        case .incompatibleVLC: return "Nook could not load VLC. Install the current VLC 3 version for this Mac, then reopen Nook."
        case .invalidAddress: return "Enter a valid RTSP camera address."
        }
    }
}

// libVLC 3 stop/release can wait for AppKit work. Never run them on the main
// thread or wait synchronously for this queue from the main thread.
private final class VLCPlayback {
    private let api: VLCAPI
    private let queue = DispatchQueue(label: "local.nook.camera.playback")
    private var instance: OpaquePointer?
    private var player: OpaquePointer?
    private var renderView: NSView?
    private var timer: DispatchSourceTimer?

    init(api: VLCAPI) { self.api = api }

    func play(_ url: URL, in view: NSView, notify: @escaping (CameraPlayer.State, CGSize?) -> Void) {
        let liveStream = !url.isFileURL
        queue.async { [self] in
            stopCurrent()
            renderView = view
            let arguments = ["--ignore-config", "--quiet", "--no-interact", "--keystore=memory", "--no-video-title-show"]
                .map { (argument: String) in argument.withCString { strdup($0)! } }
            defer { arguments.forEach { free($0) } }
            let pointers = arguments.map { Optional(UnsafePointer($0)) }
            guard let engine = pointers.withUnsafeBufferPointer({ api.new(Int32($0.count), $0.baseAddress) }) else {
                stopCurrent()
                notify(.failed, nil)
                return
            }
            instance = engine
            // RTSP URLs may contain credentials. Do not send VLC messages to logs.
            api.setLog(engine, { _, _, _, _, _ in }, nil)
            guard let media = url.absoluteString.withCString({ api.newMedia(engine, $0) }) else {
                stopCurrent()
                notify(.failed, nil)
                return
            }
            ":rtsp-tcp".withCString { api.addOption(media, $0) }
            player = api.newPlayer(media)
            api.releaseMedia(media)
            guard let player else {
                stopCurrent()
                notify(.failed, nil)
                return
            }
            api.setView(player, Unmanaged.passUnretained(view).toOpaque())
            guard api.play(player) == 0 else {
                stopCurrent()
                notify(.failed, nil)
                return
            }
            let deadline = Date().addingTimeInterval(20)
            var lastState = CameraPlayer.State.connecting
            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now(), repeating: .milliseconds(250))
            poll.setEventHandler { [weak self] in
                guard let self, let player = self.player else { return }
                let rawState = self.api.state(player)
                let state: CameraPlayer.State
                if rawState == 7 { state = .failed }
                else if rawState == 6 { state = liveStream ? .failed : .ended }
                else if rawState == 3 && self.api.hasVideo(player) > 0 { state = .playing }
                else if lastState != .playing && Date() > deadline { state = .failed }
                else { return }
                if state != lastState {
                    lastState = state
                    var width: UInt32 = 0
                    var height: UInt32 = 0
                    let size: CGSize? = state == .playing && self.api.videoSize(player, 0, &width, &height) == 0 && width > 0 && height > 0
                        ? CGSize(width: Int(width), height: Int(height)) : nil
                    notify(state, size)
                }
                if state == .failed || state == .ended { self.stopCurrent() }
            }
            timer = poll
            poll.resume()
        }
    }

    func stop() { queue.async { [self] in stopCurrent() } }

    private func stopCurrent() {
        timer?.cancel()
        timer = nil
        if let player {
            api.stop(player)
            api.setView(player, nil)
            api.releasePlayer(player)
            self.player = nil
        }
        if let instance {
            api.release(instance)
            self.instance = nil
        }
        if let view = renderView {
            // Retain the drawable through vout shutdown and release it on AppKit's thread.
            DispatchQueue.main.async { withExtendedLifetime(view) {} }
            renderView = nil
        }
    }
}

private typealias VLCLogCallback = @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void

private final class VLCAPI {
    let new: @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
    let release: @convention(c) (OpaquePointer) -> Void
    let setLog: @convention(c) (OpaquePointer, VLCLogCallback?, UnsafeMutableRawPointer?) -> Void
    let newMedia: @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> OpaquePointer?
    let addOption: @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void
    let releaseMedia: @convention(c) (OpaquePointer) -> Void
    let newPlayer: @convention(c) (OpaquePointer) -> OpaquePointer?
    let setView: @convention(c) (OpaquePointer, UnsafeMutableRawPointer?) -> Void
    let play: @convention(c) (OpaquePointer) -> Int32
    let stop: @convention(c) (OpaquePointer) -> Void
    let releasePlayer: @convention(c) (OpaquePointer) -> Void
    let state: @convention(c) (OpaquePointer) -> Int32
    let hasVideo: @convention(c) (OpaquePointer) -> UInt32
    let videoSize: @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32

    // The loaded engine and its plugins must outlive every asynchronous playback
    // callback. Keep a successful load for the process lifetime, including handles.
    @MainActor private static var loaded: VLCAPI?

    @MainActor
    static func load() throws -> VLCAPI {
        if let loaded { return loaded }
        let paths = ["/Applications/VLC.app", NSHomeDirectory() + "/Applications/VLC.app"]
        var foundVLC = false
        for path in paths where FileManager.default.fileExists(atPath: path) {
            foundVLC = true
            let base = path + "/Contents/MacOS"
            guard let core = dlopen(base + "/lib/libvlccore.dylib", RTLD_NOW | RTLD_GLOBAL) else { continue }
            guard let library = dlopen(base + "/lib/libvlc.dylib", RTLD_NOW | RTLD_GLOBAL) else {
                dlclose(core)
                continue
            }
            do {
                let api = try VLCAPI(library)
                // Set once, before libVLC starts any threads; never read VLC's preferences.
                setenv("VLC_PLUGIN_PATH", base + "/plugins", 1)
                loaded = api
                return api
            } catch {
                dlclose(library)
                dlclose(core)
            }
        }
        throw foundVLC ? CameraPlaybackError.incompatibleVLC : CameraPlaybackError.missingVLC
    }

    private init(_ library: UnsafeMutableRawPointer) throws {
        func symbol<T>(_ name: String, _: T.Type = T.self) throws -> T {
            guard let pointer = dlsym(library, name) else { throw CameraPlaybackError.incompatibleVLC }
            return unsafeBitCast(pointer, to: T.self)
        }
        let version = try symbol("libvlc_get_version", (@convention(c) () -> UnsafePointer<CChar>).self)
        guard String(cString: version()).hasPrefix("3.") else { throw CameraPlaybackError.incompatibleVLC }
        new = try symbol("libvlc_new")
        release = try symbol("libvlc_release")
        setLog = try symbol("libvlc_log_set")
        newMedia = try symbol("libvlc_media_new_location")
        addOption = try symbol("libvlc_media_add_option")
        releaseMedia = try symbol("libvlc_media_release")
        newPlayer = try symbol("libvlc_media_player_new_from_media")
        setView = try symbol("libvlc_media_player_set_nsobject")
        play = try symbol("libvlc_media_player_play")
        stop = try symbol("libvlc_media_player_stop")
        releasePlayer = try symbol("libvlc_media_player_release")
        state = try symbol("libvlc_media_player_get_state")
        hasVideo = try symbol("libvlc_media_player_has_vout")
        videoSize = try symbol("libvlc_video_get_size")
    }
}
