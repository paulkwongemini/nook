import Foundation
import Security

struct CameraSettings {
    let host: String
    let username: String
    let password: String

    init(host: String, username: String, password: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ part in
            !part.isEmpty && part.count <= 3 && part.utf8.allSatisfy({ (48...57).contains($0) }) &&
                Int(part).map { (0...255).contains($0) } == true
        }) else { throw CameraSettingsError.invalidAddress }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.rangeOfCharacter(from: .controlCharacters) == nil else { throw CameraSettingsError.invalidUsername }
        guard !password.isEmpty, password.rangeOfCharacter(from: .controlCharacters) == nil else { throw CameraSettingsError.invalidPassword }
        self.host = octets.map { String(Int($0)!) }.joined(separator: ".")
        self.username = username
        self.password = password
    }

    func streamURL() throws -> URL {
        var parts = URLComponents()
        parts.scheme = "rtsp"
        parts.host = host
        parts.port = 554
        parts.user = username
        parts.password = password
        parts.path = "/stream1"
        guard let url = parts.url else { throw CameraSettingsError.invalidAddress }
        return url
    }
}

enum CameraSettingsError: LocalizedError {
    case invalidAddress, invalidUsername, invalidPassword, keychain, environmentFile
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the camera's IPv4 address, such as 192.168.1.100."
        case .invalidUsername: return "Enter a valid camera username."
        case .invalidPassword: return "Enter a valid camera password."
        case .keychain: return "Could not access the camera account in Keychain. Please try again."
        case .environmentFile: return "Could not read the camera account from .env. Check the file's permissions and format."
        }
    }
}

struct CameraAccount: Codable {
    let username: String
    let password: String
}

struct CameraCredentialStore {
    let service: String
    let environmentFile: URL?
    static var defaultEnvironmentFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.nook.native", isDirectory: true)
            .appendingPathComponent(".env")
    }
    init(service: String = (Bundle.main.bundleIdentifier ?? "local.nook.native") + ".camera",
         environmentFile: URL? = Self.defaultEnvironmentFile) {
        self.service = service
        self.environmentFile = environmentFile
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "camera"]
    }
    func load() throws -> CameraAccount? {
        if let account = try loadEnvironmentAccount() { return account }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let account = try? JSONDecoder().decode(CameraAccount.self, from: data) else { throw CameraSettingsError.keychain }
        return account
    }
    func loadEnvironmentAccount() throws -> CameraAccount? {
        guard let environmentFile else { return nil }
        let contents: String
        do { contents = try String(contentsOf: environmentFile, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw CameraSettingsError.environmentFile }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "NOOK_CAMERA_USERNAME" || key == "NOOK_CAMERA_PASSWORD" else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            // Values are literal, with optional matching quotes; never expand or execute shell expressions.
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard value.count >= 2, value.last == quote else { throw CameraSettingsError.environmentFile }
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let username = values["NOOK_CAMERA_USERNAME"], !username.trimmingCharacters(in: .whitespaces).isEmpty,
              let password = values["NOOK_CAMERA_PASSWORD"], !password.isEmpty else { return nil }
        guard username.rangeOfCharacter(from: .controlCharacters) == nil,
              password.rangeOfCharacter(from: .controlCharacters) == nil else { throw CameraSettingsError.environmentFile }
        return CameraAccount(username: username, password: password)
    }
    func save(_ settings: CameraSettings) throws {
        let account = CameraAccount(username: settings.username, password: settings.password)
        let data = try JSONEncoder().encode(account)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Nook camera account"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CameraSettingsError.keychain }
    }
}
