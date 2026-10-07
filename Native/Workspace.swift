import AppKit
import WebKit

@MainActor
final class NativeWorkspace: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let window: NSWindow
    let dataStore: WKWebsiteDataStore
    let notifications = NativeNotificationBridge()
    private(set) var selected: NativeService = .chat
    private(set) var views: [NativeService: WKWebView] = [:]
    private let surface = NSView()
    private var buttons: [NativeService: NativeSidebarButton] = [:]
    private let automaticallyLoadsPages: Bool
    private let showsPopups: Bool
    private let externalOpener: (URL) -> Void
    private var contexts: [ObjectIdentifier: Context] = [:]
    private var popups: [ObjectIdentifier: NSWindow] = [:]
    private var downloads: [ObjectIdentifier: Transfer] = [:]
    private var quitting = false
    private var showingError = false

    private final class Context {
        let service: NativeService
        var authenticating = false
        var sawAuthentication = false
        var retried = false
        var initialBlank = true
        weak var popup: NSWindow?
        init(_ service: NativeService) { self.service = service }
    }
    private struct Transfer {
        let download: WKDownload
        var temporary: URL?
        var destination: URL?
    }

    init(dataStore: WKWebsiteDataStore? = nil, automaticallyLoadsPages: Bool = true, showsPopups: Bool = true,
         externalOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.dataStore = dataStore ?? .default()
        self.automaticallyLoadsPages = automaticallyLoadsPages
        self.showsPopups = showsPopups
        self.externalOpener = externalOpener
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Nook"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 700)
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self
        window.setFrameAutosaveName("NookNativeMain")
        if !window.setFrameUsingName("NookNativeMain") { window.center() }
        buildShell()
        notifications.onActivate = { [weak self] in self?.select(.chat); self?.show() }
        notifications.onError = { [weak self] in self?.report($0) }
        select(.chat)
    }

    private func buildShell() {
        guard let root = window.contentView else { return }
        let titlebar = NSView()
        let rail = NSView()
        // NSBox infers separator orientation from its initial frame.
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: 1, height: 100))
        separator.boxType = .separator
        [titlebar, rail, separator, surface].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            // NSWindow.minSize does not constrain an Auto Layout resize.
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 960),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 700),
            titlebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), titlebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebar.topAnchor.constraint(equalTo: root.topAnchor), titlebar.heightAnchor.constraint(equalToConstant: 36),
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor), rail.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor), rail.widthAnchor.constraint(equalToConstant: 60),
            separator.leadingAnchor.constraint(equalTo: rail.trailingAnchor), separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: rail.topAnchor), separator.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 1), surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: titlebar.bottomAnchor), surface.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        for (index, service) in NativeService.allCases.enumerated() {
            let button = NativeSidebarButton(frame: .zero)
            button.image = NativeIcons.image(for: service)
            button.target = self
            button.action = #selector(serviceClicked(_:))
            button.tag = index
            button.toolTip = service.title
            button.setAccessibilityLabel(service.title)
            button.translatesAutoresizingMaskIntoConstraints = false
            rail.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
                button.topAnchor.constraint(equalTo: rail.topAnchor, constant: CGFloat(16 + index * 52)),
                button.widthAnchor.constraint(equalToConstant: 40), button.heightAnchor.constraint(equalToConstant: 40)
            ])
            buttons[service] = button
        }
    }

    @objc private func serviceClicked(_ sender: NSButton) { select(NativeService.allCases[sender.tag]) }

    private func makeView(service: NativeService, configuration: WKWebViewConfiguration? = nil, authentication: Bool = false) -> WKWebView {
        let config = configuration ?? WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // macOS WKWebView omits the Version/Safari tokens used by Google's browser checks.
        // Append compatibility tokens to the native WebKit identity, retaining our app name.
        if configuration == nil,
           let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           let safari = Bundle(url: safariURL),
           let version = safari.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            // 605.1.15 is the frozen macOS WebKit UA token, not its internal build number.
            config.applicationNameForUserAgent = "Version/\(version) Safari/605.1.15 Nook/\(appVersion)"
        }
        if configuration == nil { notifications.install(on: config.userContentController) }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        let context = Context(service)
        context.authenticating = authentication
        context.sawAuthentication = authentication
        contexts[ObjectIdentifier(web)] = context
        return web
    }

    private func ensure(_ service: NativeService) -> WKWebView {
        if let web = views[service] { return web }
        let web = makeView(service: service)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isHidden = true
        surface.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: surface.leadingAnchor), web.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            web.topAnchor.constraint(equalTo: surface.topAnchor), web.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        views[service] = web
        if automaticallyLoadsPages { web.load(URLRequest(url: service.url)) }
        return web
    }

    func select(_ service: NativeService) {
        _ = ensure(.chat)
        let web = ensure(service)
        selected = service
        for (key, view) in views { view.isHidden = key != service }
        for (key, button) in buttons {
            button.state = key == service ? .on : .off
        }
        if automaticallyLoadsPages { reopenEntry(web, includeSignIn: false) }
        window.makeFirstResponder(web)
    }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func prepareQuit() { quitting = true }
    func reload() {
        guard let web = views[selected] else { return }
        if !reopenEntry(web, includeSignIn: true) { web.reload() }
    }
    func goBack() { views[selected]?.goBack() }
    func goHome() { views[selected]?.load(URLRequest(url: selected.url)) }

    @discardableResult private func reopenEntry(_ web: WKWebView, includeSignIn: Bool) -> Bool {
        guard let url = web.url, NativeNavigationPolicy.isEntryPage(url),
              includeSignIn || url.host != "accounts.google.com",
              let service = contexts[ObjectIdentifier(web)]?.service else { return false }
        web.load(URLRequest(url: service.url))
        return true
    }

    private func retryEntries(_ context: Context) {
        guard context.sawAuthentication, !context.retried, !quitting else { return }
        context.retried = true
        if automaticallyLoadsPages { for web in views.values { reopenEntry(web, includeSignIn: true) } }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window && !quitting { sender.orderOut(nil); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let popup = notification.object as? NSWindow, popup !== window,
              let web = popup.contentView as? WKWebView else { return }
        let key = ObjectIdentifier(web)
        if let context = contexts[key] { retryEntries(context) }
        contexts.removeValue(forKey: key)
        popups.removeValue(forKey: key)
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let context = contexts[ObjectIdentifier(webView)] else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload {
            let origin = action.sourceFrame.securityOrigin
            var source = URLComponents()
            source.scheme = origin.protocol; source.host = origin.host
            if origin.port != 0 { source.port = origin.port }
            let allowed = source.url.map { NativeNavigationPolicy.allowsDownload(url, from: $0) } ?? false
            decisionHandler(allowed ? .download : .cancel)
            return
        }
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        // WebKit can create an empty window before the page assigns its login URL.
        if url.absoluteString == "about:blank", context.initialBlank { decisionHandler(.allow); return }
        context.initialBlank = false
        let route = NativeNavigationPolicy.target(for: url, authentication: context.authenticating)
        if route == .embedded {
            if url.host == "accounts.google.com" { context.authenticating = true; context.sawAuthentication = true }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if route == .external { externalOpener(url) }
            else if action.navigationType == .linkActivated { report("This link type is not supported.") }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url, let context = contexts[ObjectIdentifier(webView)] else { return }
        context.initialBlank = false
        if NativeNavigationPolicy.service(for: url) != nil {
            context.authenticating = false
            if context.popup != nil { retryEntries(context) }
        }
        context.popup?.title = "\(url.host ?? "Google") · Nook"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let parent = contexts[ObjectIdentifier(webView)] else { return nil }
        if let url = action.request.url, url.absoluteString != "about:blank" {
            let route = NativeNavigationPolicy.target(for: url, authentication: parent.authenticating)
            if route != .embedded { if route == .external { externalOpener(url) }; return nil }
        }
        let child = makeView(service: parent.service, configuration: configuration, authentication: parent.authenticating)
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        popup.title = "Google Sign-In · Nook"
        popup.isReleasedWhenClosed = false
        popup.delegate = self
        popup.contentView = child
        contexts[ObjectIdentifier(child)]?.popup = popup
        popups[ObjectIdentifier(child)] = popup
        popup.center()
        if showsPopups { popup.makeKeyAndOrderFront(nil) }
        return child
    }
    func webViewDidClose(_ webView: WKWebView) { contexts[ObjectIdentifier(webView)]?.popup?.close() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ web: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if !web.isHidden { report("Could not open the page. Press ⌘R to try again.\n\(error.localizedDescription)") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !webView.isHidden { report("The page stopped working. Press ⌘R to reload.") }
    }

    func report(_ message: String) {
        guard !showingError else { return }
        showingError = true
        let alert = NSAlert()
        alert.messageText = "Nook"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.showingError = false }
    }

    func notificationHelp() {
        report("1. Sign in to Chat and enable desktop notifications in Chat settings.\n2. Choose “Request Notification Permission” and allow Nook notifications in macOS.\n3. Check that a message from someone else produces a macOS notification banner.\n\nNook forwards the page’s Notification calls to macOS. Service worker Web Push is not supported, and macOS notification banners for actual Chat messages have not yet been verified. Hearing a sound alone or seeing a test notification does not confirm that incoming message notifications work.\n\nNotifications cannot arrive when Nook is not running or your Mac is asleep.")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = webAlert(frame, message)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: webView.window ?? window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = webAlert(frame, message)
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: webView.window ?? window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = webAlert(frame, prompt)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: webView.window ?? window) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    private func webAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert()
        let origin = frame.securityOrigin
        alert.messageText = NativeNavigationPolicy.dialogOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
        alert.informativeText = String(message.prefix(2000))
        return alert
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: webView.window ?? window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { track(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { track(download) }
    private func track(_ download: WKDownload) { downloads[ObjectIdentifier(download)] = Transfer(download: download); download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else { completionHandler(nil); return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nook-\(UUID().uuidString).download")
            self.downloads[ObjectIdentifier(download)]?.destination = destination
            self.downloads[ObjectIdentifier(download)]?.temporary = temporary
            completionHandler(temporary)
        }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = downloads.removeValue(forKey: ObjectIdentifier(download)),
              let temporary = transfer.temporary, let destination = transfer.destination else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch { report("Could not save the downloaded file. Temporary file: \(temporary.path)\n\(error.localizedDescription)") }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let temporary = downloads.removeValue(forKey: ObjectIdentifier(download))?.temporary { try? FileManager.default.removeItem(at: temporary) }
        if (error as NSError).code != NSURLErrorCancelled { report("Download failed: \(error.localizedDescription)") }
    }
}
