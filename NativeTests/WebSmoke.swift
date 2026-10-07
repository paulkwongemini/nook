import AppKit
import WebKit

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
        Task { try? await Task.sleep(nanoseconds: 25_000_000_000); fputs("Native WebKit smoke timed out\n", stderr); exit(1) }
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
    private func checkShellAppearance() async throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(workspace.window.contentView!).compactMap { $0 as? NativeSidebarButton }
        try check(buttons.map { $0.accessibilityLabel() ?? "" } == ["Chat", "Mail", "Drive", "Calendar"],
                  "Sidebar exposes all four services in the requested order")
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
        workspace.select(.calendar)
        try check(workspace.views[.calendar] === calendar, "Returning to Calendar preserves its page")
        let eventDraft = try await calendar.evaluateJavaScript("document.getElementById('event').value") as? String
        try check(eventDraft == "unsaved event", "Service switch preserves the Calendar event draft")
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
        workspace.window.performClose(nil)
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
