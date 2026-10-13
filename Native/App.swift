import AppKit

@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    private var workspace: NativeWorkspace!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled icon directly so an in-place update replaces the cached Dock icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        // Keep the existing bundle identity so the signed-in WebKit profile persists.
        workspace = NativeWorkspace()
        installMenu()
        workspace.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { workspace?.show(); return true }
    func applicationWillTerminate(_ notification: Notification) { workspace?.prepareQuit() }

    private func installMenu() {
        let menu = NSMenu()
        func group(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu; menu.addItem(item)
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", shift: Bool = false, target: AnyObject? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = target
            entry.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            menu.addItem(entry)
        }
        let application = group("Nook")
        item(application, "About Nook", #selector(about), target: self)
        item(application, "Show Nook", #selector(show), "0", target: self)
        application.addItem(.separator())
        item(application, "Hide Nook", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(application, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        application.addItem(.separator())
        item(application, "Quit Nook", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let edit = group("Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", shift: true)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = group("View")
        for (index, service) in NativeService.allCases.enumerated() {
            let entry = NSMenuItem(title: service.title, action: #selector(selectService(_:)), keyEquivalent: String(index + 1))
            entry.target = self; entry.tag = index; view.addItem(entry)
        }
        item(view, "Camera", #selector(camera), "5", target: self)
        view.addItem(.separator())
        item(view, "Back", #selector(back), "[", target: self)
        item(view, "Reload", #selector(reload), "r", target: self)
        item(view, "Service Home", #selector(home), "h", shift: true, target: self)
        let windows = group("Window")
        item(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windows, "Close", #selector(NSWindow.performClose(_:)), "w")
        NSApp.windowsMenu = windows
        let help = group("Help")
        item(help, "Chat Notification Help", #selector(notificationHelp), target: self)
        item(help, "Request Notification Permission", #selector(notificationPermission), target: self)
        item(help, "Test App Notification", #selector(testNotification), target: self)
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
    }
    @objc private func show() { workspace.show() }
    @objc private func selectService(_ sender: NSMenuItem) { workspace.select(NativeService.allCases[sender.tag]) }
    @objc private func camera() { workspace.selectCamera() }
    @objc private func back() { workspace.goBack() }
    @objc private func reload() { workspace.reload() }
    @objc private func home() { workspace.goHome() }
    @objc private func notificationHelp() { workspace.notificationHelp() }
    @objc private func notificationPermission() { workspace.notifications.requestAuthorization() }
    @objc private func testNotification() { workspace.notifications.sendTest() }
    @objc private func about() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Nook", .applicationVersion: "0.0.1",
            .credits: NSAttributedString(string: "Swift · AppKit · WebKit\nChat · Mail · Drive · Calendar · Camera")]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

@main
enum NookMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = NativeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
