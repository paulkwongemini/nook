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
        try checkEnvironmentAccount()
        print("\(checks) camera settings checks passed")
        if CommandLine.arguments.contains("--keychain") { try checkKeychain() }
    }

    private static func checkEnvironmentAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".env")
        let store = CameraCredentialStore(service: "local.nook.tests.camera." + UUID().uuidString, environmentFile: file)
        let missing = try store.loadEnvironmentAccount()
        precondition(missing == nil, "A missing file allows Keychain fallback")
        let contents = "# Camera account\r\nNOOK_CAMERA_USERNAME='fixture camera'\r\nNOOK_CAMERA_PASSWORD=\" fixture#=$()\\secret \"\r\nNOOK_TP_LINK_PASSWORD=ignored\r\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let account = try unwrap(store.load())
        precondition(account.username == "fixture camera" && account.password == " fixture#=$()\\secret ",
                     "File credentials load without Keychain and preserve literal special characters and quoted spaces")
        try "NOOK_CAMERA_USERNAME=updated\nNOOK_CAMERA_PASSWORD=new=value#literal\n".write(to: file, atomically: true, encoding: .utf8)
        let updated = try unwrap(store.load())
        precondition(updated.username == "updated" && updated.password == "new=value#literal", "Each load reads current file values")
        for content in ["# No account\n", "NOOK_CAMERA_USERNAME=partial\n", "NOOK_CAMERA_USERNAME=fixture\nNOOK_CAMERA_PASSWORD=\n"] {
            try content.write(to: file, atomically: true, encoding: .utf8)
            let incomplete = try store.loadEnvironmentAccount()
            precondition(incomplete == nil, "Incomplete accounts fall back as a pair")
        }
        for data in [Data([0xff]), Data("NOOK_CAMERA_USERNAME=fixture\nNOOK_CAMERA_PASSWORD=\"unterminated\n".utf8),
                     Data("NOOK_CAMERA_USERNAME=fixture\nNOOK_CAMERA_PASSWORD=invalid\u{0}secret\n".utf8)] {
            try data.write(to: file)
            do {
                _ = try store.loadEnvironmentAccount()
                preconditionFailure("Invalid files must report a safe error")
            } catch {
                precondition(error.localizedDescription == CameraSettingsError.environmentFile.errorDescription,
                             "File errors must not include credentials or raw file contents")
            }
        }
        print("Camera .env: literal parsing, reload, incomplete accounts, and safe errors passed")
    }

    private static func checkKeychain() throws {
        let service = "local.nook.tests.camera." + UUID().uuidString
        let store = CameraCredentialStore(service: service, environmentFile: nil)
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".env")
        defer { try? FileManager.default.removeItem(at: file) }
        let preferred = CameraCredentialStore(service: service, environmentFile: file)
        try "NOOK_CAMERA_USERNAME=file-camera\nNOOK_CAMERA_PASSWORD=file-secret\n".write(to: file, atomically: true, encoding: .utf8)
        let fromFile = try preferred.load()
        try require(fromFile?.username == "file-camera" && fromFile?.password == "file-secret", "The file account takes precedence over a saved Keychain account")
        try FileManager.default.removeItem(at: file)
        let fallback = try preferred.load()
        try require(fallback?.username == updated.username && fallback?.password == updated.password, "Removing the file restores the existing Keychain account")
        try "NOOK_CAMERA_USERNAME=partial\n".write(to: file, atomically: true, encoding: .utf8)
        let incomplete = try preferred.load()
        try require(incomplete?.username == updated.username && incomplete?.password == updated.password, "An incomplete file never mixes credentials with Keychain")
        try require(SecItemDelete(query as CFDictionary) == errSecSuccess, "The isolated Keychain item should be deleted")
        try require(try store.load() == nil, "The isolated Keychain item should be absent after cleanup")
        print("8 isolated Keychain and fallback checks passed; test item removed")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "CameraSettingsTests", code: 1) }
        return value
    }
}
