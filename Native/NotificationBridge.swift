import AppKit
import WebKit
import UserNotifications

@MainActor
final class NativeNotificationBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    var onActivate: (() -> Void)?
    var onError: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private final class Entry {
        let pageID: String
        let tag: String
        weak var webView: WKWebView?
        init(_ pageID: String, tag: String, webView: WKWebView?) {
            self.pageID = pageID; self.tag = tag; self.webView = webView
        }
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var closedIDs: [String] = []

    override init() { super.init(); center.delegate = self }

    func install(on controller: WKUserContentController) {
        guard let url = Bundle.main.url(forResource: "notifications", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            onError?("Could not load notification support.")
            return
        }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "nookNativeNotifications")
    }

    func requestAuthorization() {
        Task { _ = await authorize() }
    }

    func sendTest() {
        Task {
            guard await authorize() == "granted" else {
                onError?("Allow notifications for Nook in macOS System Settings → Notifications.")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Nook"
            content.body = "This is a test notification from Nook, not an actual Chat message."
            content.sound = .default
            do { try await center.add(UNNotificationRequest(identifier: "nook-test", content: content, trigger: nil)) }
            catch { onError?("Could not display the test notification: \(error.localizedDescription)") }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == "chat.google.com",
              origin.port == 0 || origin.port == 443,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let webView = message.webView
        switch type {
        case "status", "permission":
            let request = string(body["request"], limit: 160)
            Task {
                let permission = type == "permission" ? await authorize() : await currentPermission()
                reply(["permission": permission, "request": request], to: webView)
            }
        case "show":
            let id = string(body["id"], limit: 160)
            guard !id.isEmpty else { return }
            let title = string(body["title"], limit: 120)
            let text = string(body["body"], limit: 500)
            let tag = string(body["tag"], limit: 120)
            let silent = body["silent"] as? Bool ?? false
            Task {
                guard await currentPermission() == "granted" else {
                    reply(["id": id, "event": "error", "permission": await currentPermission()], to: webView)
                    return
                }
                guard !closedIDs.contains(id) else { return }
                // A tag replaces only this app's notification, never an arbitrary system identifier.
                let replaced = entries.first { !$0.value.tag.isEmpty && $0.value.tag == tag }
                let identifier = replaced?.key ?? UUID().uuidString
                if let old = replaced?.value { reply(["id": old.pageID, "event": "close"], to: old.webView) }
                if entries[identifier] == nil { order.append(identifier) }
                entries[identifier] = Entry(id, tag: tag, webView: webView)
                while order.count > 128 {
                    let oldest = order.removeFirst()
                    entries.removeValue(forKey: oldest)
                    center.removePendingNotificationRequests(withIdentifiers: [oldest])
                    center.removeDeliveredNotifications(withIdentifiers: [oldest])
                }
                let content = UNMutableNotificationContent()
                content.title = title; content.body = text
                if !silent { content.sound = .default }
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                    if closedIDs.contains(id) {
                        center.removePendingNotificationRequests(withIdentifiers: [identifier])
                        center.removeDeliveredNotifications(withIdentifiers: [identifier])
                        return
                    }
                    reply(["id": id, "event": "show"], to: webView)
                } catch {
                    entries.removeValue(forKey: identifier); order.removeAll { $0 == identifier }
                    reply(["id": id, "event": "error"], to: webView)
                    onError?("Could not display the Chat notification: \(error.localizedDescription)")
                }
            }
        case "close":
            let id = string(body["id"], limit: 160)
            closedIDs.append(id)
            if closedIDs.count > 128 { closedIDs.removeFirst() }
            guard let entry = entries.first(where: { $0.value.pageID == id && $0.value.webView === webView }) else { return }
            entries.removeValue(forKey: entry.key); order.removeAll { $0 == entry.key }
            center.removePendingNotificationRequests(withIdentifiers: [entry.key])
            center.removeDeliveredNotifications(withIdentifiers: [entry.key])
        default: break
        }
    }

    private func string(_ value: Any?, limit: Int) -> String { String((value as? String ?? "").prefix(limit)) }
    private func currentPermission() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "default"
        }
    }
    private func authorize() async -> String {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { onError?("Could not request notification permission: \(error.localizedDescription)") }
        return await currentPermission()
    }
    private func reply(_ payload: [String: String], to webView: WKWebView?) {
        guard let webView, webView.url?.scheme == "https", webView.url?.host == "chat.google.com",
              webView.url?.port == nil || webView.url?.port == 443,
              let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__nookNotificationReceive?.(\(json))", completionHandler: nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let activate = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if activate {
                self.onActivate?()
                if let entry = self.entries[identifier] { self.reply(["id": entry.pageID, "event": "click"], to: entry.webView) }
            }
            completionHandler()
        }
    }
}
