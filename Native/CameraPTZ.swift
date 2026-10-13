import Foundation
import CryptoKit
import Security

enum CameraDirection: CaseIterable { case up, down, left, right }

@MainActor
final class CameraPTZ {
    private static let device = "http://www.onvif.org/ver10/device/wsdl"
    private static let media = "http://www.onvif.org/ver10/media/wsdl"
    private static let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
    private static let schema = "http://www.onvif.org/ver10/schema"
    private static let soap = "http://www.w3.org/2003/05/soap-envelope"
    private static let velocitySpace = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"
    private let settings: CameraSettings
    private let session: URLSession
    private var profile: Profile?
    private var clockOffset: TimeInterval = 0
    private var preparation: Task<Void, Error>?
    private var movement: Task<Void, Error>?
    private var generation = 0

    private struct Profile {
        let endpoint: URL
        let token: String
        let xSpeed: Double
        let ySpeed: Double
    }

    init(settings: CameraSettings, session: URLSession? = nil) {
        self.settings = settings
        let config = session?.configuration ?? .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: config, delegate: CameraPTZTransport(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func prepare() async throws {
        try Task.checkCancellation()
        if profile != nil { return }
        guard preparation == nil else { throw CameraPTZError.busy }
        let current = generation
        let task = Task {
            let discovered = try await discover()
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            profile = discovered
        }
        preparation = task
        defer { if current == generation { preparation = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func move(_ direction: CameraDirection) async throws {
        guard movement == nil else { throw CameraPTZError.busy }
        try await prepare()
        try Task.checkCancellation()
        guard movement == nil, let profile else { throw CameraPTZError.busy }
        let task = Task { try await performMove(direction, profile: profile) }
        movement = task
        defer { movement = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func cancel() {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        movement?.cancel()
        profile = nil
    }

    private func discover() async throws -> Profile {
        let endpoint = URL(string: "http://\(settings.host):2020/onvif/device_service")!
        // ONVIF exposes this operation before authentication so clock drift does not break the digest.
        if let time = try? await request(endpoint, namespace: Self.device, action: "GetSystemDateAndTime", content: "", authenticated: false),
           let utc = time.child("SystemDateAndTime", Self.device)?.child("UTCDateTime", Self.schema),
           let date = utc.child("Date", Self.schema), let clock = utc.child("Time", Self.schema),
           let year = Int(date.value("Year", Self.schema)), let month = Int(date.value("Month", Self.schema)),
           let day = Int(date.value("Day", Self.schema)), let hour = Int(clock.value("Hour", Self.schema)),
           let minute = Int(clock.value("Minute", Self.schema)), let second = Int(clock.value("Second", Self.schema)) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            if components.isValidDate(in: calendar), let value = calendar.date(from: components) {
                clockOffset = value.timeIntervalSinceNow
            }
        }
        try Task.checkCancellation()
        let response = try await request(endpoint, namespace: Self.device, action: "GetCapabilities", content: "<p:Category>All</p:Category>")
        guard let capabilities = response.child("Capabilities", Self.device),
              let media = capabilities.child("Media", Self.schema), let ptz = capabilities.child("PTZ", Self.schema) else {
            throw CameraPTZError.unsupported
        }
        let mediaURL = try serviceURL(media.value("XAddr", Self.schema))
        let ptzURL = try serviceURL(ptz.value("XAddr", Self.schema))
        let profiles = try await request(mediaURL, namespace: Self.media, action: "GetProfiles", content: "")
        guard let selected = profiles.children.first(where: {
            $0.name == "Profiles" && $0.namespace == Self.media &&
            !$0.attributes["token", default: ""].isEmpty && $0.child("PTZConfiguration", Self.schema) != nil
        }), let token = selected.attributes["token"],
           let configuration = selected.child("PTZConfiguration", Self.schema)?.attributes["token"], !configuration.isEmpty else {
            throw CameraPTZError.unsupported
        }
        let optionsResponse = try await request(ptzURL, namespace: Self.ptz, action: "GetConfigurationOptions",
                                                content: "<p:ConfigurationToken>\(escape(configuration))</p:ConfigurationToken>")
        guard let options = optionsResponse.child("PTZConfigurationOptions", Self.ptz),
              let spaces = options.child("Spaces", Self.schema),
              let space = spaces.children.first(where: {
                  $0.name == "ContinuousPanTiltVelocitySpace" && $0.namespace == Self.schema && $0.value("URI", Self.schema) == Self.velocitySpace
              }), let x = speedRange(space.child("XRange", Self.schema)),
              let y = speedRange(space.child("YRange", Self.schema)),
              let bounds = options.child("PTZTimeout", Self.schema),
              let minimum = duration(bounds.value("Min", Self.schema)),
              let maximum = duration(bounds.value("Max", Self.schema)),
              minimum >= 0, minimum <= 1, maximum >= 1 else {
            throw CameraPTZError.unsupported
        }
        return Profile(endpoint: ptzURL, token: token, xSpeed: x, ySpeed: y)
    }

    private func performMove(_ direction: CameraDirection, profile: Profile) async throws {
        try Task.checkCancellation()
        let x = direction == .left ? -profile.xSpeed : direction == .right ? profile.xSpeed : 0
        let y = direction == .down ? -profile.ySpeed : direction == .up ? profile.ySpeed : 0
        let token = "<p:ProfileToken>\(escape(profile.token))</p:ProfileToken>"
        // This independent timer also runs while ContinuousMove is still awaiting its HTTP response.
        // Unstructured work does not inherit cancellation, so Stop survives a dismissed view.
        let stop = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            let started = ContinuousClock.now
            _ = try await request(profile.endpoint, namespace: Self.ptz, action: "Stop",
                                  content: token + "<p:PanTilt>true</p:PanTilt><p:Zoom>false</p:Zoom>")
            return started
        }
        var failure: Error?
        do {
            // C210 firmware rejects decimal durations, so use the validated one-second fallback.
            _ = try await request(profile.endpoint, namespace: Self.ptz, action: "ContinuousMove",
                                  content: token + "<p:Velocity><t:PanTilt x=\"\(x)\" y=\"\(y)\" space=\"\(Self.velocitySpace)\"/></p:Velocity><p:Timeout>PT1S</p:Timeout>")
        } catch { failure = error }
        let responseTime = ContinuousClock.now
        do {
            let stopTime = try await stop.value
            if responseTime > stopTime {
                // A delayed move may have been accepted after the timed Stop reached the camera.
                let confirmedStop = Task {
                    _ = try await request(profile.endpoint, namespace: Self.ptz, action: "Stop",
                                          content: token + "<p:PanTilt>true</p:PanTilt><p:Zoom>false</p:Zoom>")
                }
                try await confirmedStop.value
            }
        } catch {
            // Keep the overlap guard held through the device's full fallback interval, even on cancellation.
            let expiry = Task { try await Task.sleep(nanoseconds: 1_000_000_000) }
            try? await expiry.value
            if failure == nil { failure = CameraPTZError.stopFailed }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    private func serviceURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host == settings.host, parts.user == nil, parts.password == nil, parts.fragment == nil,
              !parts.path.isEmpty, let url = parts.url else { throw CameraPTZError.invalidResponse }
        return url
    }

    private func speedRange(_ node: CameraXMLElement?) -> Double? {
        guard let node, let lower = Double(node.value("Min", Self.schema)), let upper = Double(node.value("Max", Self.schema)),
              lower.isFinite, upper.isFinite, lower < 0, upper > 0 else { return nil }
        return min(0.25, min(-lower, upper))
    }

    private func duration(_ value: String) -> Double? {
        // Years and months cannot express fixed movement intervals; accept day/time durations.
        let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        var seconds = 0.0
        var hasComponent = false
        for (index, scale) in [(1, 86400.0), (2, 3600.0), (3, 60.0), (4, 1.0)] {
            if let range = Range(match.range(at: index), in: value), let number = Double(value[range]) {
                hasComponent = true
                seconds += number * scale
            }
        }
        return hasComponent && seconds.isFinite ? seconds : nil
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func securityHeader() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CameraPTZError.connection }
        let nonce = Data(bytes)
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(clockOffset))
        let digest = Data(Insecure.SHA1.hash(data: nonce + Data((created + settings.password).utf8))).base64EncodedString()
        let base = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-"
        return """
        <s:Header><wsse:Security s:mustUnderstand="1" xmlns:wsse="\(base)wssecurity-secext-1.0.xsd" xmlns:wsu="\(base)wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>\(escape(settings.username))</wsse:Username><wsse:Password Type="\(base)username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password><wsse:Nonce EncodingType="\(base)soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce><wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>
        """
    }

    private func request(_ endpoint: URL, namespace: String, action: String, content: String,
                         authenticated: Bool = true) async throws -> CameraXMLElement {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(namespace)/\(action)\"", forHTTPHeaderField: "Content-Type")
        let header = authenticated ? try securityHeader() : ""
        request.httpBody = Data("<s:Envelope xmlns:s=\"\(Self.soap)\" xmlns:p=\"\(namespace)\" xmlns:t=\"\(Self.schema)\">\(header)<s:Body><p:\(action)>\(content)</p:\(action)></s:Body></s:Envelope>".utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw CameraPTZError.connection
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CameraPTZError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw CameraPTZError.authentication }
        guard (200...299).contains(http.statusCode) else { throw CameraPTZError.rejected }
        let root = try CameraXMLParser.parse(data)
        guard root.name == "Envelope", [Self.soap, "http://schemas.xmlsoap.org/soap/envelope/"].contains(root.namespace),
              let body = root.child("Body", root.namespace) else { throw CameraPTZError.invalidResponse }
        if body.child("Fault", root.namespace) != nil { throw CameraPTZError.rejected }
        guard let result = body.child(action + "Response", namespace) else { throw CameraPTZError.invalidResponse }
        return result
    }
}

private enum CameraPTZError: LocalizedError {
    case busy, unsupported, connection, authentication, invalidResponse, rejected, stopFailed
    var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current camera movement to finish."
        case .unsupported: return "This camera does not report support for short pan and tilt movements."
        case .connection: return "Could not reach the camera's movement controls. Check the camera and VPN connection."
        case .authentication: return "Camera login failed. Check the camera username and password."
        case .invalidResponse: return "The camera returned an invalid response to the movement request."
        case .rejected: return "The camera could not complete the movement request."
        case .stopFailed: return "The camera did not confirm Stop. The movement timeout will end this step."
        }
    }
}

private final class CameraPTZTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS trust uses the system policy; never draw credentials from another session or account.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

private final class CameraXMLElement {
    let name: String
    let namespace: String
    let attributes: [String: String]
    var children: [CameraXMLElement] = []
    var text = ""
    init(_ name: String, _ namespace: String, _ attributes: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func child(_ name: String, _ namespace: String) -> CameraXMLElement? {
        children.first { $0.name == name && $0.namespace == namespace }
    }
    func value(_ name: String, _ namespace: String) -> String {
        child(name, namespace)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class CameraXMLParser: NSObject, XMLParserDelegate {
    private var root: CameraXMLElement?
    private var stack: [CameraXMLElement] = []
    static func parse(_ data: Data) throws -> CameraXMLElement {
        guard data.count <= 1_048_576 else { throw CameraPTZError.invalidResponse }
        let delegate = CameraXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw CameraPTZError.invalidResponse }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 40 else { parser.abortParsing(); return }
        let node = CameraXMLElement(elementName, namespaceURI ?? "", attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { stack.last?.text += value }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
}
