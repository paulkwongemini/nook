import AppKit
import WebKit

@MainActor
final class FileDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
final class DownloadProbe: NSObject, WKNavigationDelegate {
    let workspace: NativeWorkspace
    var converted = false
    init(_ workspace: NativeWorkspace) { self.workspace = workspace }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        workspace.webView(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        converted = true
        download.cancel { _ in }
    }
}

@MainActor
final class SmokeDelegate: NSObject, NSApplicationDelegate {
    private var workspace: NativeWorkspace!
    private let phase = CommandLine.arguments[1]
    private let storeID = UUID(uuidString: CommandLine.arguments[2])!
    private var external: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); print("Native WebKit \(phase): passed"); exit(0) }
            catch { fputs("Native WebKit smoke failed: \(error)\n", stderr); exit(1) }
        }
        Task { try? await Task.sleep(nanoseconds: 45_000_000_000); fputs("Native WebKit smoke timed out\n", stderr); exit(1) }
    }
    private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func waitForLoad(_ web: WKWebView) async throws {
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
        }
        throw NSError(domain: "Smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture did not load"])
    }
    private func dragDestination(at location: NSPoint, types: [NSPasteboard.PasteboardType]) throws -> NSView? {
        let root = workspace.window.contentView!
        // Test-only access to the same AppKit destination hit test used during a native drag.
        // Ordinary hitTest does not exercise WKWebView's separate drag destination routing.
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        try check(root.responds(to: selector), "AppKit exposes its native drag destination hit test")
        typealias DragHitTest = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        let hitTest = unsafeBitCast(root.method(for: selector), to: DragHitTest.self)
        var point = root.superview?.convert(location, from: nil) ?? location
        return hitTest(root, selector, &point, NSSet(array: types))
    }
    private func checkFileDrop(_ web: WKWebView, afterServiceSwitch: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-file-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Finder upload fixture.txt")
        let contents = "Local Finder file upload fixture."
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try check(pasteboard.writeObjects([file as NSURL]), "File drag writes a native file URL")
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.addTypes([filenames], owner: nil)
        pasteboard.setPropertyList([file.path], forType: filenames)
        _ = try await web.evaluateJavaScript("""
            document.getElementById('file-drop-fixture')?.remove();
            window.fileDropProbe = { entered: 0, over: 0, dropped: 0, files: [], error: '', ready: false };
            (() => {
                const target = document.createElement('div');
                target.id = 'file-drop-fixture';
                target.style = 'position:fixed;inset:60px;background:#eee;z-index:9999';
                target.textContent = 'Local native file drop target';
                target.addEventListener('dragenter', event => { event.preventDefault(); fileDropProbe.entered++; });
                target.addEventListener('dragover', event => {
                    event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; fileDropProbe.over++;
                });
                target.addEventListener('drop', async event => {
                    event.preventDefault(); fileDropProbe.dropped++;
                    try {
                        fileDropProbe.files = await Promise.all(Array.from(event.dataTransfer.files,
                            async file => ({name: file.name, text: await file.text()})));
                    } catch (error) { fileDropProbe.error = String(error); }
                    fileDropProbe.ready = true;
                });
                document.body.append(target);
            })(); true
            """)
        let location = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        let info = FileDraggingInfo(window: workspace.window, pasteboard: pasteboard, location: location)
        let destination = try dragDestination(at: location, types: pasteboard.types ?? [])
        let destinationService = workspace.views.first { $0.value === destination }?.key.rawValue ?? String(describing: destination)
        print("Native file drop routing (after service switch: \(afterServiceSwitch)): \(destinationService)")
        try check(destination === web, "Finder file drags must target visible Chat, not a hidden service (destination: \(destinationService))")
        _ = web.draggingEntered(info)
        var operation: NSDragOperation = []
        for _ in 0..<100 {
            operation = web.draggingUpdated(info)
            try await Task.sleep(nanoseconds: 25_000_000)
            let entered = try await web.evaluateJavaScript("fileDropProbe.entered") as? Int ?? 0
            if entered > 0 && operation.contains(.copy) { break }
        }
        let entered = try await web.evaluateJavaScript("fileDropProbe.entered") as? Int ?? 0
        try check(entered > 0, "Native Finder drag enters the page")
        try check(operation.contains(.copy), "The page accepts copying the Finder file")
        try check(web.prepareForDragOperation(info), "WebKit prepares the Finder file drop")
        try check(web.performDragOperation(info), "WebKit accepts the Finder file drop")
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("fileDropProbe.ready")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let result = try await web.evaluateJavaScript("fileDropProbe") as? [String: Any] ?? [:]
        try check(result["dropped"] as? Int == 1, "Native Finder drag reaches the page's drop handler")
        try check(result["error"] as? String == "", "Dropped file remains readable by the web process")
        let files = result["files"] as? [[String: String]] ?? []
        try check(files.count == 1 && files.first?["name"] == file.lastPathComponent && files.first?["text"] == contents,
                  "Finder file drop preserves the filename and actual file bytes")
        try check(external.isEmpty, "Uploading a file does not open an external application")
        web.concludeDragOperation(info)
        _ = try await web.evaluateJavaScript("document.getElementById('file-drop-fixture').remove(); true")
        print("Native Finder file drop and readable payload (after service switch: \(afterServiceSwitch)): passed")
    }
    private func waitForCamera(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(false, "Camera playback did not reach its expected state")
    }
    private func checkCameraContinuity(_ camera: CameraView, keepOpen: NSButton) async throws {
        let clip = URL(fileURLWithPath: "build/camera-fixture.mp4")
        workspace.selectCamera()
        camera.startPlayback(clip)
        try await waitForCamera { camera.canKeepPlaying && !camera.renderTarget.isHidden && !camera.renderTarget.drawable.subviews.isEmpty }
        let video = camera.renderTarget.drawable.subviews.first!
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(camera)
        let zoom = controls.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Digital zoom" }!
        let reset = controls.compactMap { $0 as? NSButton }.first { $0.title == "Reset" }!
        try check(zoom.isEnabled && reset.isEnabled, "Playback enables Zoom and Reset")
        zoom.doubleValue = 2
        zoom.sendAction(zoom.action!, to: zoom.target)
        try check(camera.renderTarget.zoom == 2, "Zoom control enlarges the real video viewport")
        keepOpen.performClick(nil)
        for service in NativeService.allCases {
            workspace.select(service)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            guard let pip = workspace.cameraPiP, let host = pip.superview else {
                try check(false, "Keep Open must create an in-window picture in picture")
                return
            }
            try check(camera.isActive && camera.canKeepPlaying && camera.isHidden,
                      "Keep Open preserves live playback while the full camera panel is hidden")
            try check(camera.renderTarget.superview === pip.videoContainer && camera.renderTarget.drawable.subviews.first === video,
                      "Switching Google tabs reuses the same live native video")
            try check(host.subviews.last === pip && !workspace.views[service]!.isHidden,
                      "The mini-player remains above each selected Google page")
            try check(camera.renderTarget.bounds.size == NSSize(width: 320, height: 180),
                      "The live renderer fits the mini-player")
            try check(camera.renderTarget.zoom == 2, "Zoom remains active in the mini-player")
        }
        let pip = workspace.cameraPiP!
        try check(pip.accessibilityPerformPress(), "The mini-player can reopen Camera")
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        try check(workspace.isCameraSelected && pip.superview == nil && camera.renderTarget.superview === camera,
                  "Returning to Camera restores the full-size video")
        try check(camera.renderTarget.drawable.subviews.first === video && camera.canKeepPlaying,
                  "Returning to Camera does not reconnect or replace the video")
        workspace.select(.calendar)
        workspace.window.miniaturize(nil)
        try await waitForCamera { workspace.window.isMiniaturized && !camera.isActive }
        try check(pip.superview == nil && camera.renderTarget.superview === camera,
                  "Minimizing stops background playback and removes the mini-player")
        workspace.window.deminiaturize(nil)
        try await waitForCamera { !workspace.window.isMiniaturized }
        workspace.selectCamera()
        camera.startPlayback(clip)
        try await waitForCamera { !camera.renderTarget.isHidden && !camera.renderTarget.drawable.subviews.isEmpty }
        zoom.doubleValue = 3
        zoom.sendAction(zoom.action!, to: zoom.target)
        reset.performClick(nil)
        try check(camera.renderTarget.zoom == 1 && camera.renderTarget.center == CGPoint(x: 0.5, y: 0.5),
                  "Reset restores the full frame and centered view")
        keepOpen.performClick(nil)
        workspace.select(.calendar)
        try check(!camera.keepOpen && !camera.isActive && pip.superview == nil,
                  "With Keep Open off, changing tabs stops playback")
        try await waitForCamera { camera.renderTarget.drawable.subviews.isEmpty }
        print("Camera Zoom, Keep Open, all Google tabs, full-size return, and minimize: passed")
    }
    private func checkShellAppearance() async throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(workspace.window.contentView!).compactMap { $0 as? NativeSidebarButton }
        try check(buttons.map { $0.accessibilityLabel() ?? "" } == ["Chat", "Mail", "Drive", "Calendar", "Camera"],
                  "Sidebar keeps Google services in order and adds Camera last")
        try check(workspace.window.appearance == nil, "The window inherits system appearance")
        let chatButton = buttons.first { $0.tag == 0 }!
        let gmailButton = buttons.first { $0.tag == 1 }!
        for button in buttons {
            let cell = button.cell as! NSButtonCell
            try check(cell.accessibilitySubrole() == .toggle,
                      "Sidebar buttons retain native accessibility toggle semantics")
            try check((cell.accessibilityValue() as? NSNumber)?.intValue == button.state.rawValue,
                      "Assistive tools can identify the selected service")
        }
        let event = NSEvent()
        var backgrounds: [CGFloat] = []
        var hoverColors: [CGColor] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            workspace.window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 100_000_000)
            workspace.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                backgrounds.append(workspace.window.backgroundColor.usingColorSpace(.genericRGB)!.redComponent)
            }
            gmailButton.mouseExited(with: event)
            try check(gmailButton.layer!.backgroundColor!.alpha == 0, "An idle unselected service has no highlight")
            gmailButton.mouseEntered(with: event)
            let hovered = gmailButton.layer!.backgroundColor!
            hoverColors.append(hovered)
            try check(hovered.alpha > 0 && gmailButton.state == .off, "Hover is visible without changing services")
            gmailButton.mouseExited(with: event)
            try check(gmailButton.layer!.backgroundColor!.alpha == 0, "Hover clears on pointer exit")
            chatButton.mouseExited(with: event)
            let selected = chatButton.layer!.backgroundColor!
            chatButton.mouseEntered(with: event)
            try check(chatButton.layer!.backgroundColor! != selected, "Selected service also responds to hover")
            chatButton.mouseExited(with: event)
            try check(chatButton.state == .on && chatButton.layer!.backgroundColor! == selected,
                      "Selection highlight remains after pointer exit")
        }
        try check(backgrounds[0] > backgrounds[1] + 0.4, "The shell switches from light to dark with its appearance")
        try check(hoverColors[0] != hoverColors[1], "Hover colors adapt to light and dark backgrounds")
        workspace.window.appearance = nil
        for service in NativeService.allCases {
            guard let url = Bundle.main.url(forResource: service.rawValue, withExtension: "png", subdirectory: "ServiceIcons"),
                  let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else {
                throw NSError(domain: "Smoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing bundled service icon: \(service)"])
            }
            try check(bitmap.pixelsWide == 192 && bitmap.pixelsHigh == 192 && bitmap.hasAlpha,
                      "Original icon is bundled at full resolution with transparency")
            try check(NativeIcons.image(for: service).size == NSSize(width: 24, height: 24), "Service icon fits the sidebar")
            try check(NativeIcons.image(for: service).isTemplate, "Service icon follows native appearance")
        }
        print("Shell light/dark appearance, service hover, and bundled icons: passed")
    }
    private func run() async throws {
        let store = WKWebsiteDataStore(forIdentifier: storeID)
        if phase == "cleanup" {
            try await WKWebsiteDataStore.remove(forIdentifier: storeID)
            return
        }
        // These preferences belong to the isolated smoke-test app, not Nook.
        NSWindow.removeFrame(usingName: "NookNativeMain")
        if phase == "read", let screen = NSScreen.main {
            let visible = screen.visibleFrame
            UserDefaults.standard.set("\(Int(visible.minX)) \(Int(visible.minY)) 1280 37 \(Int(screen.frame.minX)) \(Int(screen.frame.minY)) \(Int(screen.frame.width)) \(Int(screen.frame.height)) ",
                                      forKey: "NSWindow Frame NookNativeMain")
        }
        workspace = NativeWorkspace(dataStore: store, automaticallyLoadsPages: false, showsPopups: false,
                                    externalOpener: { [weak self] in self?.external.append($0) })
        let chat = workspace.views[.chat]!
        workspace.window.orderFront(nil)
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        print("Initial window size: \(workspace.window.frame.size), webview size: \(chat.frame.size)")
        try check(workspace.window.frame.width >= 960 && workspace.window.frame.height >= 700,
                  "Initial display must not collapse to the titlebar, including a restored 37pt frame")
        try check(chat.bounds.width >= 899 && chat.bounds.height >= 664,
                  "Initial display must contain a usable web area before manual resizing")
        try await checkShellAppearance()
        if phase == "write" {
            let cookie = HTTPCookie(properties: [.domain: "nook-fixture.invalid", .path: "/", .name: "native-session", .value: "fixture-only", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
            await store.httpCookieStore.setCookie(cookie)
        }
        let cookies = await store.httpCookieStore.allCookies()
        try check(cookies.contains { $0.name == "native-session" && $0.value == "fixture-only" }, "Shared profile persists between processes")
        chat.loadHTMLString("<!doctype html><title>Local Chat fixture</title><input id='draft' value='unsent fixture'><p>No Google network requests</p>", baseURL: NativeService.chat.url)
        try await waitForLoad(chat)
        try check(workspace.window.title == "Nook", "Window name")
        let notificationName = try await chat.evaluateJavaScript("Notification.name") as? String
        try check(notificationName == "NativeNotification", "Chat notification bridge installed at document start")
        try check(chat.customUserAgent?.isEmpty != false, "Keep WebKit's native user agent prefix")
        let userAgent = try await chat.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try check(userAgent.contains("AppleWebKit/") && !userAgent.contains("Chrome/") && !userAgent.contains("Electron/"), "WebKit identifies itself honestly")
        print("Chat browser identity: \(userAgent)")
        try check(userAgent.range(of: "Version/[0-9]+(?:\\.[0-9]+)* Safari/[0-9.]+ Nook/[0-9.]+", options: .regularExpression) != nil,
                  "Chat needs a Safari-compatible browser version while retaining the Nook identity")
        try await checkFileDrop(chat, afterServiceSwitch: false)
        workspace.select(.gmail)
        let gmail = workspace.views[.gmail]!
        gmail.loadHTMLString("<!doctype html><title>Local Gmail fixture</title><p>Fixture</p>", baseURL: NativeService.gmail.url)
        try await waitForLoad(gmail)
        try check(chat.isHidden && !gmail.isHidden, "Only selected service is visible")
        try check(gmail.configuration.websiteDataStore === chat.configuration.websiteDataStore, "One shared account store")
        let gmailUserAgent = try await gmail.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try check(gmail.customUserAgent?.isEmpty != false && gmailUserAgent == userAgent,
                  "Gmail needs the same Safari-compatible WebKit identity as Chat")
        let gmailBridge = try await gmail.evaluateJavaScript("typeof window.__nookNotificationReceive") as? String
        try check(gmailBridge == "undefined", "Notification capability not installed in Gmail")
        workspace.select(.drive)
        let drive = workspace.views[.drive]!
        drive.loadHTMLString("<!doctype html><title>Local Drive fixture</title><p>Fixture</p>", baseURL: NativeService.drive.url)
        try await waitForLoad(drive)
        let driveUserAgent = try await drive.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try check(drive.customUserAgent?.isEmpty != false && driveUserAgent == userAgent,
                  "Drive needs the same Safari-compatible WebKit identity as Chat and Gmail")
        workspace.select(.calendar)
        let calendar = workspace.views[.calendar]!
        calendar.loadHTMLString("<!doctype html><title>Local Calendar fixture</title><input id='event' value='unsaved event'>", baseURL: NativeService.calendar.url)
        try await waitForLoad(calendar)
        try check(drive.isHidden && !calendar.isHidden, "Calendar is visible after service selection")
        try check(calendar.configuration.websiteDataStore === chat.configuration.websiteDataStore,
                  "Calendar shares the signed-in account store")
        let calendarUserAgent = try await calendar.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        try check(calendar.customUserAgent?.isEmpty != false && calendarUserAgent == userAgent,
                  "Calendar uses the same Safari-compatible WebKit identity")
        let calendarBridge = try await calendar.evaluateJavaScript("typeof window.__nookNotificationReceive") as? String
        try check(calendarBridge == "undefined", "Calendar does not claim Chat notification support")
        try check(workspace.views.count == 4, "Four reusable service views")
        workspace.select(.chat)
        try check(workspace.views[.chat] === chat, "Service switch preserves view")
        let draft = try await chat.evaluateJavaScript("document.getElementById('draft').value") as? String
        try check(draft == "unsent fixture", "Service switch preserves draft")
        try await checkFileDrop(chat, afterServiceSwitch: true)
        workspace.select(.calendar)
        try check(workspace.views[.calendar] === calendar, "Returning to Calendar preserves its page")
        let eventDraft = try await calendar.evaluateJavaScript("document.getElementById('event').value") as? String
        try check(eventDraft == "unsaved event", "Service switch preserves the Calendar event draft")
        workspace.selectCamera()
        guard let camera = workspace.cameraView else {
            throw NSError(domain: "Smoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Camera panel was not created"])
        }
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        try check(workspace.isCameraSelected && camera.isActive && !camera.isHidden && workspace.views.values.allSatisfy(\.isHidden),
                  "Camera replaces the visible page without opening an external app")
        try check(camera.bounds.width >= 899 && camera.bounds.height >= 664, "Camera fills the content area")
        try check(workspace.views.count == 4 && external.isEmpty, "Camera keeps the Google pages and account session intact")
        let cameraDropLocation = camera.convert(NSPoint(x: camera.bounds.midX, y: camera.bounds.midY), to: nil)
        let cameraDropDestination = try dragDestination(at: cameraDropLocation,
                                                       types: [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        try check(!(cameraDropDestination is WKWebView), "A file dragged over Camera must not target a hidden Google page")
        func cameraSubviews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + cameraSubviews($0) } }
        let cameraButtons = cameraSubviews(camera).compactMap { $0 as? NSButton }
        guard let keepOpen = cameraButtons.first(where: { $0.title == "Keep Open" }),
              let reconnect = cameraButtons.first(where: { $0.title == "Reconnect" }) else {
            throw NSError(domain: "Smoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Camera Keep Open control is missing"])
        }
        let sliders = cameraSubviews(camera).compactMap { $0 as? NSSlider }
        try check(sliders.count == 1 && sliders[0].accessibilityLabel() == "Digital zoom" &&
                  sliders[0].minValue == 1 && sliders[0].maxValue == 4 && !sliders[0].isEnabled,
                  "Camera offers 1–4× digital zoom, disabled until video plays")
        try check(!cameraButtons.contains { $0.title == "Mute" } &&
                  !cameraButtons.contains { $0.title == "Lock" || $0.title == "Unlock" } &&
                  cameraButtons.contains { $0.title == "Reset" && !$0.isEnabled },
                  "Camera offers Reset without tracking or volume controls, disabled until video plays")
        let directionButtons = cameraButtons.filter { ($0.accessibilityLabel() ?? "").hasPrefix("Move camera ") }
        try check(directionButtons.count == 4 && directionButtons.allSatisfy { !$0.isEnabled },
                  "All four camera directions stay disabled before control discovery")
        let environmentFile = CameraCredentialStore.defaultEnvironmentFile
        try check(environmentFile.deletingLastPathComponent().lastPathComponent == "local.nook.native.tests" &&
                  !FileManager.default.fileExists(atPath: environmentFile.path), "The account fixture must be isolated from Nook's real .env")
        try FileManager.default.createDirectory(at: environmentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: environmentFile) }
        try "NOOK_CAMERA_USERNAME=smoke-camera\nNOOK_CAMERA_PASSWORD=smoke-secret\n".write(to: environmentFile, atomically: true, encoding: .utf8)
        camera.showSettings()
        let accountFields = cameraSubviews(camera).compactMap { $0 as? NSTextField }.filter {
            ["Camera username", "Camera password"].contains($0.accessibilityLabel() ?? "")
        }
        try check(accountFields.count == 2 && accountFields.allSatisfy { !$0.isEditable && !$0.stringValue.isEmpty },
                  "File-backed account fields are populated and read-only")
        try check(cameraSubviews(camera).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("loaded from .env") },
                  "Camera settings explain the account source")
        try FileManager.default.removeItem(at: environmentFile)
        camera.showSettings()
        try check(accountFields.allSatisfy { $0.isEditable && $0.stringValue.isEmpty },
                  "Removing .env restores editable fallback fields without stale file credentials")
        try check(!camera.keepOpen && keepOpen.state == .off && keepOpen.bezelColor == reconnect.bezelColor,
                  "Keep Open starts off with the normal toolbar button appearance")
        keepOpen.performClick(nil)
        try check(camera.keepOpen && keepOpen.state == .on && keepOpen.bezelColor == .controlAccentColor,
                  "Keep Open changes to the active color when clicked")
        keepOpen.performClick(nil)
        try check(!camera.keepOpen && keepOpen.state == .off && keepOpen.bezelColor == reconnect.bezelColor,
                  "A second click restores the normal toolbar button appearance")
        workspace.reload()
        workspace.goHome()
        try check(workspace.isCameraSelected && calendar.isHidden, "Camera navigation never reloads the previous Google page")
        workspace.goBack()
        try check(!workspace.isCameraSelected && !camera.isActive && camera.isHidden && !calendar.isHidden,
                  "Back leaves Camera and restores the previous service")
        let preservedEvent = try await calendar.evaluateJavaScript("document.getElementById('event').value") as? String
        try check(preservedEvent == "unsaved event", "Camera use preserves an unsaved Calendar draft")
        if ProcessInfo.processInfo.environment["NOOK_TEST_CAMERA"] == "1" {
            try await checkCameraContinuity(camera, keepOpen: keepOpen)
        }
        workspace.select(.chat)
        for size in [NSSize(width: 1280, height: 860), NSSize(width: 1040, height: 720)] {
            workspace.window.setContentSize(size)
            workspace.window.contentView?.layoutSubtreeIfNeeded()
            let root = workspace.window.contentView!
            let frame = chat.convert(chat.bounds, to: root)
            try check(abs(frame.minX - 61) < 1 && abs(frame.width - (root.bounds.width - 61)) < 1, "Webview fills width beside rail")
            try check(abs(frame.minY) < 1 && abs(frame.height - (root.bounds.height - 36)) < 1, "Webview fills height below titlebar")
        }
        workspace.window.setContentSize(NSSize(width: 320, height: 180))
        workspace.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        print("Resized window size: \(workspace.window.frame.size), root size: \(workspace.window.contentView!.frame.size), minimum: \(workspace.window.contentMinSize)")
        try check(workspace.window.frame.width >= 960 && workspace.window.frame.height >= 700,
                  "Resizing must preserve the minimum usable window size")
        _ = try await chat.evaluateJavaScript("window.fixturePopup = window.open('about:blank'); true")
        try await Task.sleep(nanoseconds: 200_000_000)
        let popup = NSApp.windows.first { $0 !== workspace.window && $0.contentView is WKWebView }
        try check(popup != nil, "Login popup stays inside the native app")
        if let child = popup?.contentView as? WKWebView { try check(child.configuration.websiteDataStore === store, "Popup shares account store") }
        _ = try await chat.evaluateJavaScript("window.fixturePopup.close(); true")
        _ = try await chat.evaluateJavaScript("window.open('https://docs.google.com/document/d/fixture'); true")
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(external.count == 1 && external[0].host == "docs.google.com", "Documents open externally exactly once")
        let download = DownloadProbe(workspace)
        chat.navigationDelegate = download
        _ = try await chat.evaluateJavaScript("const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['local download fixture'], {type:'text/plain'})); a.download='fixture.txt'; document.body.append(a); a.click(); true")
        for _ in 0..<100 {
            if download.converted { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try check(download.converted, "Page-generated Blob download reaches WKDownload without external navigation")
        chat.navigationDelegate = workspace
        workspace.selectCamera()
        if ProcessInfo.processInfo.environment["NOOK_TEST_CAMERA"] == "1" {
            camera.startPlayback(URL(fileURLWithPath: "build/camera-fixture.mp4"))
            try await waitForCamera { !camera.renderTarget.isHidden && !camera.renderTarget.drawable.subviews.isEmpty }
            camera.setKeepOpen(true)
            workspace.select(.chat)
            try check(workspace.cameraPiP?.superview != nil, "Close test begins with a live mini-player")
        }
        workspace.window.performClose(nil)
        try check(!camera.isActive, "Closing the window deactivates camera playback")
        try check(workspace.cameraPiP?.superview == nil && camera.renderTarget.superview === camera,
                  "Closing the window removes the mini-player and restores the video host")
        try check(!workspace.window.isVisible && workspace.views[.chat] === chat, "Closing window keeps Chat alive")
        workspace.prepareQuit()
        // Allow WebKit's asynchronous cookie persistence to settle before process exit.
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}

@main
enum NativeSmokeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = SmokeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
