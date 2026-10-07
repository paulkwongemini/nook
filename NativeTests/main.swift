import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func url(_ value: String) -> URL { URL(string: value)! }

let destinations: [(NativeService, String, String)] = [
    (.chat, "Chat", "https://chat.google.com/"),
    (.gmail, "Mail", "https://mail.google.com/mail/u/0/"),
    (.drive, "Drive", "https://drive.google.com/drive/u/0/"),
    (.calendar, "Calendar", "https://calendar.google.com/calendar/u/0/r")
]
check(NativeService.allCases == [.chat, .gmail, .drive, .calendar], "Service order: Chat, Mail, Drive, Calendar")
for (service, title, address) in destinations {
    check(service.title == title, "Title for \(service)")
    check(service.url.absoluteString == address, "Canonical URL for \(service)")
    check(NativeNavigationPolicy.target(for: service.url) == .embedded, "Canonical service stays embedded")
}

let routes: [(String, Bool, NavigationTarget)] = [
    ("https://calendar.google.com/calendar/u/0/r", false, .embedded),
    ("https://workspace.google.com/products/calendar/", false, .embedded),
    ("https://calendar.google.com.evil.example/calendar/u/0/r", false, .external),
    ("https://calendar.google.com:8443/calendar/u/0/r", false, .external),
    ("https://accounts.google.com/v3/signin/identifier", false, .embedded),
    ("https://myaccount.google.com/", false, .embedded),
    ("https://contacts.google.com/", false, .embedded),
    ("https://CHAT.GOOGLE.COM:443/u/0/", false, .embedded),
    ("https://workspace.google.com/products/gmail/", false, .embedded),
    ("https://workspace.google.com/intl/ko/products/drive/", false, .embedded),
    ("https://www.google.com/intl/en/gmail/about/", false, .embedded),
    ("https://www.google.com/drive/", false, .embedded),
    ("https://www.google.com/search?q=chat", false, .external),
    ("https://workspace.google.com/pricing/", false, .external),
    ("https://workspace.google.com/products/gmail-evil/", false, .external),
    ("https://chat.google.com.evil.example/", false, .external),
    ("https://mail.google.com:8443/mail/u/0/", false, .external),
    ("https://example.com/news", false, .external),
    ("https://sso.example.com/saml?RelayState=chat", true, .embedded),
    ("https://accounts.google.com/signin/saml", true, .embedded),
    ("https://docs.google.com/document/d/example/edit", false, .external),
    ("https://docs.google.com/spreadsheets/d/example/edit", true, .external),
    ("https://sheets.google.com/", true, .external),
    ("https://slides.google.com/", true, .external),
    ("mailto:person@example.com?subject=Hello", false, .external),
    ("http://chat.google.com/", false, .blocked),
    ("http://sso.example.com/saml", true, .blocked),
    ("https://person:secret@chat.google.com/", false, .blocked),
    ("https://person@accounts.google.com/", true, .blocked),
    ("file:///tmp/example.html", true, .blocked),
    ("data:text/html,example", true, .blocked),
    ("javascript:alert(1)", false, .blocked),
    ("about:blank", true, .blocked),
    ("customapp://chat.google.com/", true, .blocked),
    ("/relative/path", false, .blocked)
]
for (address, authentication, expected) in routes {
    check(NativeNavigationPolicy.target(for: url(address), authentication: authentication) == expected,
          "Navigation target for \(address), authentication=\(authentication)")
}

let applicationURLs: [(String, NativeService?)] = [
    ("https://calendar.google.com/calendar/u/0/r", .calendar),
    ("https://calendar.google.com/calendar/u/0/r/eventedit", .calendar),
    ("https://calendar.google.com:443/calendar/u/0/r", .calendar),
    ("https://calendar.google.com/calendars/", nil),
    ("https://calendar.google.com.evil.example/calendar/u/0/r", nil),
    ("https://calendar.google.com:8443/calendar/u/0/r", nil),
    ("https://chat.google.com/u/0/", .chat),
    ("https://chat.google.com/u/23/app", .chat),
    ("https://chat.google.com/app", .chat),
    ("https://chat.google.com/app/space/example", .chat),
    ("https://mail.google.com/mail/u/0/#inbox", .gmail),
    ("https://drive.google.com/drive/u/0/folders/example", .drive),
    ("https://drive.google.com:443/drive/u/0/", .drive),
    ("https://chat.google.com/", nil),
    ("https://chat.google.com/u/person/", nil),
    ("https://chat.google.com/application", nil),
    ("https://mail.google.com/mailbox/", nil),
    ("https://drive.google.com/driveway/", nil),
    ("https://accounts.google.com/ServiceLogin", nil),
    ("https://workspace.google.com/products/gmail/", nil),
    ("https://mail.google.com.evil.example/mail/u/0/", nil),
    ("https://mail.google.com:8443/mail/u/0/", nil),
    ("http://mail.google.com/mail/u/0/", nil),
    ("https://person@mail.google.com/mail/u/0/", nil)
]
for (address, expected) in applicationURLs {
    check(NativeNavigationPolicy.service(for: url(address)) == expected, "Application service for \(address)")
}

let entryURLs: [(String, Bool)] = [
    ("https://calendar.google.com/", true),
    ("https://workspace.google.com/intl/en/products/calendar/", true),
    ("https://calendar.google.com/calendar/u/0/r", false),
    ("https://chat.google.com/", true),
    ("https://mail.google.com/?authuser=0", true),
    ("https://drive.google.com", true),
    ("https://accounts.google.com/v3/signin/identifier", true),
    ("https://workspace.google.com/intl/ko/products/chat/", true),
    ("https://www.google.com/intl/en/gmail/about/", true),
    ("https://www.google.com/chat/", true),
    ("https://www.google.com/drive/", true),
    ("https://chat.google.com/u/0/", false),
    ("https://mail.google.com/mail/u/0/", false),
    ("https://drive.google.com/drive/u/0/", false),
    ("https://workspace.google.com/products/chatbot/", false),
    ("https://www.google.com/gmail/about-us/", false),
    ("https://accounts.google.com.evil.example/", false),
    ("https://accounts.google.com:8443/", false),
    ("https://person@accounts.google.com/", false),
    ("http://chat.google.com/", false)
]
for (address, expected) in entryURLs {
    check(NativeNavigationPolicy.isEntryPage(url(address)) == expected, "Entry page for \(address)")
}

let notificationURLs: [(String, NativeService?)] = [
    ("https://calendar.google.com/calendar/u/0/r", nil),
    ("https://chat.google.com/u/0/", .chat),
    ("https://mail.google.com/mail/u/0/", .gmail),
    ("https://CHAT.GOOGLE.COM:443/", .chat),
    ("https://mail.google.com:443/", .gmail),
    ("https://drive.google.com/drive/u/0/", nil),
    ("https://accounts.google.com/", nil),
    ("https://chat.google.com.evil.example/", nil),
    ("https://chat.google.com:444/", nil),
    ("https://mail.google.com:80/", nil),
    ("http://chat.google.com:443/", nil),
    ("https://person:secret@chat.google.com/", nil),
    ("file:///chat.google.com", nil)
]
for (address, expected) in notificationURLs {
    check(NativeNavigationPolicy.notificationService(for: url(address)) == expected,
          "Notification origin for \(address)")
}

let downloadURLs: [(String, String, Bool)] = [
    ("https://calendar.google.com/calendar/u/0/r", "https://calendar.google.com/calendar/exporticalzip", true),
    ("https://calendar.google.com/calendar/u/0/r", "blob:https://calendar.google.com/calendar-export", true),
    ("https://calendar.google.com.evil.example/", "https://files.example.com/export.zip", false),
    ("https://calendar.google.com:8443/", "https://files.example.com/export.zip", false),
    ("https://chat.google.com/u/0/", "https://files.example.com/document.pdf", true),
    ("https://mail.google.com/mail/u/0/", "https://mail.google.com/mail/u/0/?view=att", true),
    ("https://drive.google.com/drive/u/0/", "https://drive.usercontent.google.com/download?id=example", true),
    ("https://mail.google.com:443/mail/u/0/", "blob:https://mail.google.com/attachment-id", true),
    ("https://drive.google.com/drive/u/0/", "blob:https://drive.google.com:443/download-id", true),
    ("https://CHAT.GOOGLE.COM/u/0/", "blob:https://chat.google.com/attachment-id", true),
    ("https://chat.google.com/u/0/", "blob:https://mail.google.com/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "blob:https://mail.google.com:8443/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "blob:https://person@mail.google.com/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "blob:https://mail.google.com.evil.example/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "blob:https://mail.google.com/", false),
    ("https://mail.google.com/mail/u/0/", "blob:null/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "blob:http://mail.google.com/attachment-id", false),
    ("https://mail.google.com/mail/u/0/", "https://person:secret@files.example.com/private", false),
    ("https://mail.google.com/mail/u/0/", "http://files.example.com/document.pdf", false),
    ("https://mail.google.com/mail/u/0/", "file:///tmp/document.pdf", false),
    ("https://mail.google.com/mail/u/0/", "data:text/plain,document", false),
    ("https://mail.google.com/mail/u/0/", "javascript:alert(1)", false),
    ("https://mail.google.com/mail/u/0/", "mailto:person@example.com", false),
    ("https://accounts.google.com/", "https://files.example.com/document.pdf", false),
    ("https://mail.google.com.evil.example/", "https://files.example.com/document.pdf", false),
    ("https://mail.google.com:8443/", "https://files.example.com/document.pdf", false),
    ("https://person@mail.google.com/", "https://files.example.com/document.pdf", false),
    ("http://mail.google.com/", "https://files.example.com/document.pdf", false)
]
for (source, destination, expected) in downloadURLs {
    check(NativeNavigationPolicy.allowsDownload(url(destination), from: url(source)) == expected,
          "Download from \(source) to \(destination)")
}

let unknownOrigin = "Web page with an unknown origin"
let dialogOrigins: [(String, String, Int, String)] = [
    ("https", "chat.google.com", 443, "https://chat.google.com"),
    ("https", "mail.google.com", 0, "https://mail.google.com"),
    ("HTTPS", "SSO.EXAMPLE.COM", 8443, "https://sso.example.com:8443"),
    ("http", "example.com", 80, "http://example.com"),
    ("http", "example.com", 8080, "http://example.com:8080"),
    ("https", "127.0.0.1", 8443, "https://127.0.0.1:8443"),
    ("https", "[::1]", 443, "https://[::1]"),
    ("https", "::1", 8443, "https://[::1]:8443"),
    ("https", "chat.google.com.evil.example", 443, "https://chat.google.com.evil.example"),
    ("https", "", 443, unknownOrigin),
    ("", "", 0, unknownOrigin),
    ("null", "", 0, unknownOrigin),
    ("file", "localhost", 0, unknownOrigin),
    ("data", "chat.google.com", 0, unknownOrigin),
    ("https", "person@chat.google.com", 443, unknownOrigin),
    ("https", "chat.google.com/evil", 443, unknownOrigin),
    ("https", "chat.google.com\nTrusted", 443, unknownOrigin),
    ("https", "chat.google.com", -1, unknownOrigin),
    ("https", "chat.google.com", 65536, unknownOrigin)
]
for (scheme, host, port, expected) in dialogOrigins {
    check(NativeNavigationPolicy.dialogOrigin(scheme: scheme, host: host, port: port) == expected,
          "Dialog origin for \(scheme), \(host), \(port)")
}

let assertionCount = 1 + destinations.count * 3 + routes.count + applicationURLs.count
    + entryURLs.count + notificationURLs.count + downloadURLs.count + dialogOrigins.count
print("Native navigation policy: \(assertionCount) assertions passed.")
