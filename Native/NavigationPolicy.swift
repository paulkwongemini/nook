import Foundation

enum NativeService: String, CaseIterable {
    case chat, gmail, drive, calendar

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .gmail: return "Mail"
        case .drive: return "Drive"
        case .calendar: return "Calendar"
        }
    }

    var url: URL {
        switch self {
        case .chat: return URL(string: "https://chat.google.com/")!
        case .gmail: return URL(string: "https://mail.google.com/mail/u/0/")!
        case .drive: return URL(string: "https://drive.google.com/drive/u/0/")!
        case .calendar: return URL(string: "https://calendar.google.com/calendar/u/0/r")!
        }
    }
}

enum NavigationTarget: Equatable {
    case embedded, external, blocked
}

struct NativeNavigationPolicy {
    private static let embeddedHosts: Set<String> = [
        "chat.google.com", "mail.google.com", "drive.google.com", "calendar.google.com",
        "accounts.google.com", "myaccount.google.com", "contacts.google.com"
    ]
    private static let documentHosts: Set<String> = [
        "docs.google.com", "sheets.google.com", "slides.google.com"
    ]

    static func target(for url: URL, authentication: Bool = false) -> NavigationTarget {
        guard url.user == nil, url.password == nil else { return .blocked }
        if url.scheme?.lowercased() == "mailto" { return .external }
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return .blocked }
        if documentHosts.contains(host) { return .external }
        if authentication { return .embedded }
        guard secureHost(url) != nil else { return .external }
        return embeddedHosts.contains(host) || isProductPage(url) ? .embedded : .external
    }

    static func service(for url: URL) -> NativeService? {
        guard let host = secureHost(url) else { return nil }
        let path = path(of: url)
        if host == "mail.google.com", path.hasPrefix("/mail/") { return .gmail }
        if host == "drive.google.com", path.hasPrefix("/drive/") { return .drive }
        if host == "calendar.google.com", path.hasPrefix("/calendar/") { return .calendar }
        if host == "chat.google.com", matches(path, "^/(?:u/[0-9]+|app)(?:/|$)") { return .chat }
        return nil
    }

    static func isEntryPage(_ url: URL) -> Bool {
        guard let host = secureHost(url) else { return false }
        if host == "accounts.google.com" || isProductPage(url) { return true }
        return ["chat.google.com", "mail.google.com", "drive.google.com", "calendar.google.com"].contains(host)
            && ["", "/"].contains(path(of: url))
    }

    static func notificationService(for url: URL) -> NativeService? {
        switch secureHost(url) {
        case "chat.google.com": return .chat
        case "mail.google.com": return .gmail
        default: return nil
        }
    }

    static func allowsDownload(_ destination: URL, from source: URL) -> Bool {
        guard let sourceHost = secureHost(source),
              ["chat.google.com", "mail.google.com", "drive.google.com", "calendar.google.com"].contains(sourceHost),
              destination.user == nil, destination.password == nil else { return false }
        if destination.scheme?.lowercased() == "https" {
            return destination.host?.isEmpty == false
        }
        guard destination.scheme?.lowercased() == "blob",
              let blobURL = URL(string: String(destination.absoluteString.dropFirst(5))),
              secureHost(blobURL) == sourceHost else { return false }
        return path(of: blobURL).split(separator: "/").count == 1
    }

    static func dialogOrigin(scheme: String, host: String, port: Int) -> String {
        let unknown = "Web page with an unknown origin"
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard ["https", "http"].contains(scheme), (0...65535).contains(port),
              matches(host, "^[a-z0-9._:\\[\\]-]+$") else { return unknown }
        let hostLiteral = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        let suffix = port == 0 || port == defaultPort ? "" : ":\(port)"
        let label = "\(scheme)://\(hostLiteral)\(suffix)"
        guard let components = URLComponents(string: label), components.url != nil,
              components.host == hostLiteral, components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil else { return unknown }
        return label
    }

    private static func secureHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    private static func path(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    private static func isProductPage(_ url: URL) -> Bool {
        switch secureHost(url) {
        case "workspace.google.com":
            return matches(path(of: url), "^/(?:intl/[^/]+/)?(?:products/)?(?:gmail|drive|chat|calendar)(?:/|$)")
        case "www.google.com":
            return matches(path(of: url), "^/(?:intl/[^/]+/)?(?:gmail/about|drive|chat|calendar)(?:/|$)")
        default: return false
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
