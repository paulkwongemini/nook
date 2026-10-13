import Foundation
import Security

@main
struct CameraSettingsTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func rejected(host: String = "192.0.2.54", username: String = "camera", password: String = "secret") -> Bool {
            do { _ = try CameraSettings(host: host, username: username, password: password); return false }
            catch { return true }
        }
        for host in ["", "camera.local", "192.0.2", "192.0.2.256", "-1.0.2.54", "192.0.2.54:554", "192.0.2.54/stream1", "192.0.2.54@other", "192.0.2.54?x=1", "１９２.0.2.54", "192..2.54"] {
            expect(rejected(host: host), "An invalid IPv4 address must be rejected")
        }
        expect(rejected(username: ""), "An empty account must be rejected")
        expect(rejected(username: "   "), "A blank account must be rejected")
        expect(rejected(username: "cam\nname"), "Control characters must be rejected")
        expect(rejected(password: ""), "An empty password must be rejected")
        expect(rejected(password: "password\u{0}"), "Embedded NUL must be rejected")

        let username = "cam:name@?#/%+"
        let password = "p@ss:/?#[]%+ word"
        let settings = try CameraSettings(host: " 192.0.2.54\n", username: username, password: password)
        let url = try settings.streamURL()
        let parsed = try unwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        expect(settings.host == "192.0.2.54", "Host whitespace is normalized")
        expect(parsed.scheme == "rtsp" && parsed.host == "192.0.2.54" && parsed.port == 554, "Credentials cannot alter the destination")
        expect(parsed.path == "/stream1" && parsed.query == nil && parsed.fragment == nil, "Credentials cannot alter the stream path")
        expect(parsed.user == username && parsed.password == password, "Special characters round-trip without corruption")
        expect(!url.absoluteString.contains("@?#/"), "Credentials must be encoded in the URL")
        print("\(checks) camera settings checks passed")
        if CommandLine.arguments.contains("--keychain") { try checkKeychain() }
    }

    private static func checkKeychain() throws {
        let service = "local.nook.tests.camera." + UUID().uuidString
        let store = CameraCredentialStore(service: service)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "camera"]
        // Cleanup also runs if a store operation or assertion throws.
        defer { SecItemDelete(query as CFDictionary) }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "CameraSettingsTests", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try require(try store.load() == nil, "The isolated Keychain item should not exist")
        let initial = try CameraSettings(host: "192.0.2.54", username: "test-camera", password: "test-secret@?#")
        try store.save(initial)
        let saved = try store.load()
        try require(saved?.username == initial.username && saved?.password == initial.password,
                    "The saved camera account should round-trip through Keychain")
        let updated = try CameraSettings(host: "192.0.2.54", username: "updated-camera", password: "updated-secret:/%")
        try store.save(updated)
        let reloaded = try store.load()
        try require(reloaded?.username == updated.username && reloaded?.password == updated.password,
                    "Saving again should update both camera account fields")
        try require(SecItemDelete(query as CFDictionary) == errSecSuccess, "The isolated Keychain item should be deleted")
        try require(try store.load() == nil, "The isolated Keychain item should be absent after cleanup")
        print("5 isolated Keychain checks passed; test item removed")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "CameraSettingsTests", code: 1) }
        return value
    }
}
