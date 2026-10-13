import Foundation
import CryptoKit

private let soap = "http://www.w3.org/2003/05/soap-envelope"
private let schema = "http://www.onvif.org/ver10/schema"
private let device = "http://www.onvif.org/ver10/device/wsdl"
private let media = "http://www.onvif.org/ver10/media/wsdl"
private let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
private let velocitySpace = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"

private func envelope(_ body: String) -> String {
    "<s:Envelope xmlns:s=\"\(soap)\" xmlns:d=\"\(device)\" xmlns:m=\"\(media)\" xmlns:p=\"\(ptz)\" xmlns:t=\"\(schema)\"><s:Body>\(body)</s:Body></s:Envelope>"
}

private struct Reply {
    var status = 200
    var xml: String
    var delay: TimeInterval = 0
    var redirect: URL? = nil
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var mediaAddress = "http://192.0.2.54:2020/onvif/media_service"
    var ptzAddress = "http://192.0.2.54:2020/onvif/ptz_service"
    var timeoutMin = "PT0.1S"
    var timeoutMax = "PT10S"
    var profilesOverride: String?
    var override: ((String) -> Reply?)?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }

    func respond(_ request: URLRequest) -> Reply {
        lock.lock(); captured.append(request); lock.unlock()
        let xml = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        if let custom = override?(xml) { return custom }
        if xml.contains("GetSystemDateAndTime") {
            return Reply(xml: envelope("<d:GetSystemDateAndTimeResponse><d:SystemDateAndTime><t:UTCDateTime><t:Time><t:Hour>12</t:Hour><t:Minute>34</t:Minute><t:Second>56</t:Second></t:Time><t:Date><t:Year>2025</t:Year><t:Month>6</t:Month><t:Day>7</t:Day></t:Date></t:UTCDateTime></d:SystemDateAndTime></d:GetSystemDateAndTimeResponse>"))
        }
        if xml.contains("GetCapabilities") {
            return Reply(xml: envelope("<d:GetCapabilitiesResponse><d:Capabilities><t:Media><t:XAddr>\(mediaAddress)</t:XAddr></t:Media><t:PTZ><t:XAddr>\(ptzAddress)</t:XAddr></t:PTZ></d:Capabilities></d:GetCapabilitiesResponse>"))
        }
        if xml.contains("GetProfiles") {
            return Reply(xml: profilesOverride ?? envelope("<m:GetProfilesResponse><m:Profiles token=\"video-only\"/><fake:Profiles xmlns:fake=\"urn:fake\" token=\"wrong-namespace\"><t:PTZConfiguration token=\"wrong-config\"/></fake:Profiles><m:Profiles token=\"profile&lt;&amp;&quot;\"><t:PTZConfiguration token=\"config&lt;&amp;&quot;\"/></m:Profiles></m:GetProfilesResponse>"))
        }
        if xml.contains("GetConfigurationOptions") {
            return Reply(xml: envelope("<p:GetConfigurationOptionsResponse><p:PTZConfigurationOptions><t:Spaces><t:ContinuousPanTiltVelocitySpace><t:URI>\(velocitySpace)</t:URI><t:XRange><t:Min>-1</t:Min><t:Max>1</t:Max></t:XRange><t:YRange><t:Min>-1</t:Min><t:Max>1</t:Max></t:YRange></t:ContinuousPanTiltVelocitySpace></t:Spaces><t:PTZTimeout><t:Min>\(timeoutMin)</t:Min><t:Max>\(timeoutMax)</t:Max></t:PTZTimeout></p:PTZConfigurationOptions></p:GetConfigurationOptionsResponse>"))
        }
        if xml.contains("ContinuousMove") {
            // The C210 rejects decimal durations, including PT1.000S, with a malformed HTTP body.
            guard xml.contains("<p:Timeout>PT1S</p:Timeout>") else {
                return Reply(xml: "POST /onvif/service\0HTTP/1.1 500 Internal Server Error\0private-device-detail")
            }
            return Reply(xml: envelope("<p:ContinuousMoveResponse/>"))
        }
        if xml.contains("<p:Stop") { return Reply(xml: envelope("<p:StopResponse/>")) }
        return Reply(status: 500, xml: envelope("<s:Fault/>"))
    }
}

private final class CameraProtocol: URLProtocol, @unchecked Sendable {
    static var fixture = Fixture()
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = data
        }
        let reply = Self.fixture.respond(captured)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let headers = reply.redirect.map { ["Location": $0.absoluteString] }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            if let redirect = reply.redirect {
                var next = self.request
                next.url = redirect
                self.client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            } else {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(reply.xml.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        delivery = work
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
    }
    override func stopLoading() { delivery?.cancel() }
}

@main
@MainActor
struct CameraPTZTests {
    static let username = "camera<&\" user"
    static let password = "fixture-secret<&\""
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "CameraPTZTests", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func body(_ request: URLRequest) -> String { String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "" }
    static func values(_ xml: String, _ xpath: String) throws -> [String] {
        try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]).nodes(forXPath: xpath).compactMap(\.stringValue)
    }
    private static func make(_ fixture: Fixture) throws -> CameraPTZ {
        CameraProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CameraProtocol.self]
        return CameraPTZ(settings: try CameraSettings(host: "192.0.2.54", username: username, password: password),
                         session: URLSession(configuration: config))
    }
    static func assertFailure(_ operation: () async throws -> Void, _ message: String) async throws {
        do { try await operation() }
        catch {
            try expect(!error.localizedDescription.contains(password) && !error.localizedDescription.contains("private-device-detail"),
                       "Errors must not echo camera data or credentials")
            return
        }
        try expect(false, message)
    }
    private static func waitForRequest(_ action: String, in fixture: Fixture) async throws {
        for _ in 0..<100 {
            if fixture.requests.contains(where: { body($0).contains("<p:\(action)>") }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(false, "\(action) request was never sent")
    }
    static func main() async {
        do {
            try await testDiscoveryAuthenticationAndMovement()
            try await testSlowResponseStillStopsPromptly()
            try await testUntrustedEndpointsAndResponses()
            try await testMovementFailuresAndCancellation()
            try await testCancellationDuringStopKeepsMovementLocked()
            print("Camera PTZ: discovery, digest authentication, bounded movement, faults, endpoint validation, and cancellation passed")
        } catch {
            fputs("Camera PTZ test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func testDiscoveryAuthenticationAndMovement() async throws {
        let fixture = Fixture()
        let camera = try make(fixture)
        try await camera.prepare()
        try await camera.prepare()
        try expect(fixture.requests.count == 4, "Preparation must discover capabilities, profiles, and supported bounds once")
        let requests = fixture.requests
        try expect(requests[0].url?.absoluteString == "http://192.0.2.54:2020/onvif/device_service", "Use the configured camera's ONVIF port")
        try expect(!body(requests[0]).contains("UsernameToken"), "Clock lookup must work before authentication")
        for request in requests.dropFirst() {
            let xml = body(request)
            try expect(!xml.contains(password), "Never transmit the raw password")
            try expect(try values(xml, "//*[local-name()='Username']") == [username], "Username XML escaping must round-trip")
            let nonce = try values(xml, "//*[local-name()='Nonce']").first!
            let created = try values(xml, "//*[local-name()='Created']").first!
            try expect(created.hasPrefix("2025-06-07T12:34:"), "Authentication must account for the camera's UTC clock")
            let digest = Data(Insecure.SHA1.hash(data: Data(base64Encoded: nonce)! + Data((created + password).utf8))).base64EncodedString()
            try expect(try values(xml, "//*[local-name()='Password']") == [digest], "Digest must hash decoded nonce, created, and password")
        }
        try expect(try values(body(requests[3]), "//*[local-name()='ConfigurationToken']") == ["config<&\""], "Discover and XML-escape the PTZ configuration token")
        for (direction, expected) in [(CameraDirection.up, ["0.0", "0.25"]), (.down, ["0.0", "-0.25"]), (.left, ["-0.25", "0.0"]), (.right, ["0.25", "0.0"])] {
            try await camera.move(direction)
            let move = body(fixture.requests[fixture.requests.count - 2])
            let stop = body(fixture.requests.last!)
            try expect(try values(move, "//*[local-name()='ProfileToken']") == ["profile<&\""], "Use the PTZ-capable profile from the correct namespace")
            try expect(try values(move, "//*[local-name()='PanTilt']/@x") + values(move, "//*[local-name()='PanTilt']/@y") == expected, "Send the correct axis and direction")
            try expect(try values(move, "//*[local-name()='Timeout']") == ["PT1S"], "Every movement must carry a whole-second device-enforced timeout")
            try expect(stop.contains("<p:Stop>") && stop.contains("<p:PanTilt>true</p:PanTilt>"), "Stop pan and tilt after every movement")
        }
    }
    static func testUntrustedEndpointsAndResponses() async throws {
        for address in ["http://192.0.2.55:2020/onvif/media", "http://user:secret@192.0.2.54:2020/onvif/media", "file:///onvif/media", "http://192.0.2.54:2020/onvif/media#fragment"] {
            let fixture = Fixture(); fixture.mediaAddress = address
            let camera = try make(fixture)
            try await assertFailure({ try await camera.prepare() }, "Reject an unsafe service endpoint")
            try expect(fixture.requests.count == 2, "Do not send credentials to an unsafe endpoint")
        }
        for (minimum, maximum) in [("PT2S", "PT10S"), ("PT-1S", "PT10S"), ("nonsense", "PT10S"),
                                   ("PT0S", "PT0.999S"), ("PT0S", "PT0S"), ("PT0S", "nonsense")] {
            let fixture = Fixture(); fixture.timeoutMin = minimum; fixture.timeoutMax = maximum
            let camera = try make(fixture)
            try await assertFailure({ try await camera.prepare() }, "Reject unsupported movement timeout bounds")
            try expect(!fixture.requests.contains { body($0).contains("ContinuousMove") }, "Never move when the camera does not support a one-second timeout")
        }
        for minimum in ["PT0S", "PT1S"] {
            let fixture = Fixture(); fixture.timeoutMin = minimum; fixture.timeoutMax = "PT1S"
            let camera = try make(fixture)
            try await camera.move(.up)
        }
        for response in [envelope("<s:Fault><s:Reason><s:Text>private-device-detail</s:Text></s:Reason></s:Fault>"),
                         envelope("<m:GetProfilesResponse><x:Profiles xmlns:x=\"urn:fake\" token=\"spoof\"><t:PTZConfiguration token=\"spoof\"/></x:Profiles></m:GetProfilesResponse>"),
                         "<!DOCTYPE x [<!ENTITY private SYSTEM 'file:///etc/passwd'>]><x>&private;</x>"] {
            let fixture = Fixture(); fixture.profilesOverride = response
            let camera = try make(fixture)
            try await assertFailure({ try await camera.prepare() }, "Reject faults, incorrect namespaces, and entity declarations")
        }
        let fixture = Fixture()
        fixture.override = { xml in xml.contains("GetCapabilities") ? Reply(status: 302, xml: "", redirect: URL(string: "http://192.0.2.55:2020/steal")) : nil }
        let camera = try make(fixture)
        try await assertFailure({ try await camera.prepare() }, "Never follow authenticated HTTP redirects")
        try expect(fixture.requests.allSatisfy { $0.url?.host == "192.0.2.54" }, "Redirects must never forward credentials")
    }
    static func testMovementFailuresAndCancellation() async throws {
        let faultFixture = Fixture()
        faultFixture.override = { xml in xml.contains("ContinuousMove") ? Reply(status: 500, xml: envelope("<s:Fault><s:Reason><s:Text>private-device-detail</s:Text></s:Reason></s:Fault>")) : nil }
        let faultCamera = try make(faultFixture)
        try await faultCamera.prepare()
        try await assertFailure({ try await faultCamera.move(.up) }, "Report movement failures")
        try expect(body(faultFixture.requests.last!).contains("<p:Stop>"), "Stop even when movement returns a fault")

        let stopFixture = Fixture(); stopFixture.timeoutMin = "PT1S"
        stopFixture.override = { xml in xml.contains("<p:Stop>") ? Reply(status: 500, xml: envelope("<s:Fault/>")) : nil }
        let stopCamera = try make(stopFixture)
        try await stopCamera.prepare()
        let started = ContinuousClock.now
        try await assertFailure({ try await stopCamera.move(.down) }, "Report an unconfirmed Stop")
        try expect(started.duration(to: .now) >= .seconds(1), "Keep movement locked until the device timeout expires when Stop fails")

        for cancelClient in [false, true] {
            let fixture = Fixture()
            fixture.override = { xml in xml.contains("ContinuousMove") ? Reply(xml: envelope("<p:ContinuousMoveResponse/>"), delay: 0.4) : nil }
            let camera = try make(fixture)
            try await camera.prepare()
            let movement = Task { try await camera.move(.right) }
            try await waitForRequest("ContinuousMove", in: fixture)
            try await assertFailure({ try await camera.move(.left) }, "Reject overlapping moves")
            if cancelClient { camera.cancel() } else { movement.cancel() }
            try await assertFailure({ try await movement.value }, "Cancelled movement must not report success")
            try expect(body(fixture.requests.last!).contains("<p:Stop>"), "Cancellation must still send an uncancelled Stop")
            try expect(fixture.requests.filter { body($0).contains("ContinuousMove") }.count == 1, "Never queue overlapping movement")
        }
    }
    static func testCancellationDuringStopKeepsMovementLocked() async throws {
        for (stopFails, cancelClient) in [(false, false), (false, true), (true, false), (true, true)] {
            let fixture = Fixture()
            fixture.override = { xml in
                guard xml.contains("<p:Stop>") else { return nil }
                return Reply(status: stopFails ? 500 : 200,
                             xml: envelope(stopFails ? "<s:Fault/>" : "<p:StopResponse/>"), delay: 0.3)
            }
            let camera = try make(fixture)
            try await camera.prepare()
            var completed = false
            let movement = Task { defer { completed = true }; try await camera.move(.right) }
            // ContinuousMove responds immediately; cancel while the independent Stop is pending.
            try await waitForRequest("Stop", in: fixture)
            if cancelClient { camera.cancel() } else { movement.cancel() }
            try await Task.sleep(nanoseconds: 20_000_000)
            try expect(!completed, "Cancellation must wait for the pending Stop")
            try await assertFailure({ try await camera.move(.left) }, "Keep movement locked while Stop is pending")
            if stopFails {
                try await Task.sleep(nanoseconds: 400_000_000)
                try expect(!completed, "Cancellation must not skip the failed Stop fallback interval")
                try await assertFailure({ try await camera.move(.left) }, "Keep movement locked after Stop fails")
            }
            try await assertFailure({ try await movement.value }, "Cancelled movement must not report success")
            try expect(fixture.requests.filter { body($0).contains("ContinuousMove") }.count == 1,
                       "Cancellation must never allow another movement before Stop cleanup finishes")
            fixture.override = nil
            try await camera.move(.left)
            try expect(fixture.requests.filter { body($0).contains("ContinuousMove") }.count == 2,
                       "Release the movement lock after Stop cleanup finishes")
        }
    }
    static func testSlowResponseStillStopsPromptly() async throws {
        let fixture = Fixture()
        fixture.timeoutMin = "PT1S"
        fixture.timeoutMax = "PT1M"
        fixture.override = { xml in xml.contains("ContinuousMove") ? Reply(xml: envelope("<p:ContinuousMoveResponse/>"), delay: 0.6) : nil }
        let camera = try make(fixture)
        try await camera.prepare()
        var completed = false
        let movement = Task { defer { completed = true }; try await camera.move(.up) }
        try await waitForRequest("ContinuousMove", in: fixture)
        try await Task.sleep(nanoseconds: 350_000_000)
        try expect(!completed && fixture.requests.contains { body($0).contains("<p:Stop>") }, "Send Stop promptly without waiting for the movement response")
        let move = fixture.requests.first { body($0).contains("ContinuousMove") }!
        try expect(try values(body(move), "//*[local-name()='Timeout']") == ["PT1S"], "Honor the camera's minimum timeout without decimals while retaining a short local Stop timer")
        try await movement.value
        try expect(fixture.requests.filter { body($0).contains("<p:Stop>") }.count == 2,
                   "Confirm Stop again after a late movement response to cover delayed acceptance")
    }
}
