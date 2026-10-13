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
    case invalidAddress, invalidUsername, invalidPassword, keychain
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the camera's IPv4 address, such as 192.168.1.100."
        case .invalidUsername: return "Enter a valid camera username."
        case .invalidPassword: return "Enter a valid camera password."
        case .keychain: return "Could not access the camera account in Keychain. Please try again."
        }
    }
}

struct CameraAccount: Codable {
    let username: String
    let password: String
}

struct CameraCredentialStore {
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "local.nook.native") + ".camera") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "camera"]
    }
    func load() throws -> CameraAccount? {
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
