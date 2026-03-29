import Foundation
import Security

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return String(localized: "Keychain item not found")
        case .unexpectedStatus(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
            return String(localized: "Keychain error: \(msg) (\(status))")
        case .invalidData:
            return String(localized: "Keychain returned invalid data")
        }
    }
}

enum KeychainService {
    /// Read a generic password from the Keychain by service name.
    static func readGenericPassword(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Save (or update) a generic password in the Keychain by service name.
    static func saveGenericPassword(_ data: Data, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        let existing = SecItemCopyMatching(query as CFDictionary, nil)

        if existing == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }
        } else {
            var attrs = query
            attrs[kSecValueData as String] = data
            let status = SecItemAdd(attrs as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }
}
