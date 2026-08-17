import Foundation
import Security

enum CredentialVaultError: Error, Equatable, Sendable {
    case interactionNotAllowed
    case accessDenied
    case invalidData
    case unexpectedStatus(Int32)
}

extension CredentialVaultError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .interactionNotAllowed:
            String(localized: "钥匙串当前已锁定或不允许交互。")
        case .accessDenied:
            String(localized: "无法访问钥匙串中的凭据。")
        case .invalidData:
            String(localized: "钥匙串中的凭据格式无效。")
        case let .unexpectedStatus(status):
            String(localized: "钥匙串操作失败（状态 \(status)）。")
        }
    }
}

protocol CredentialVaultProtocol: Sendable {
    func containsPassword(for profileID: UUID) async throws -> Bool
    func password(for profileID: UUID) async throws -> String?
    func save(password: String, for profileID: UUID) async throws
    func deletePassword(for profileID: UUID) async throws
    func deleteAllPasswords() async throws
}

struct KeychainCredentialVault: CredentialVaultProtocol, Sendable {
    static let productionService = "com.farframe.rdp.credentials"

    let service: String

    init(service: String = Self.productionService) {
        self.service = service
    }

    func containsPassword(for profileID: UUID) async throws -> Bool {
        let service = service
        return try await Task.detached(priority: .userInitiated) {
            var result: CFTypeRef?
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: profileID.uuidString,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnAttributes: true,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                return true
            case errSecItemNotFound:
                return false
            default:
                throw Self.error(for: status)
            }
        }.value
    }

    func password(for profileID: UUID) async throws -> String? {
        let service = service
        return try await Task.detached(priority: .userInitiated) {
            var result: CFTypeRef?
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: profileID.uuidString,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnData: true,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess else {
                throw Self.error(for: status)
            }
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.invalidData
            }
            return password
        }.value
    }

    func save(password: String, for profileID: UUID) async throws {
        let service = service
        try await Task.detached(priority: .userInitiated) {
            let data = Data(password.utf8)
            let lookup: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: profileID.uuidString,
            ]
            let attributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrLabel: "Farframe RDP · \(profileID.uuidString)",
            ]

            let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw Self.error(for: updateStatus)
            }

            var item = lookup
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Farframe RDP · \(profileID.uuidString)"
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw Self.error(for: retryStatus)
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw Self.error(for: addStatus)
            }
        }.value
    }

    func deletePassword(for profileID: UUID) async throws {
        let service = service
        try await Task.detached(priority: .userInitiated) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: profileID.uuidString,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Self.error(for: status)
            }
        }.value
    }

    func deleteAllPasswords() async throws {
        let service = service
        try await Task.detached(priority: .userInitiated) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Self.error(for: status)
            }
        }.value
    }

    private static func error(for status: OSStatus) -> CredentialVaultError {
        switch status {
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied
        default:
            .unexpectedStatus(status)
        }
    }
}

actor InMemoryCredentialVault: CredentialVaultProtocol {
    private var passwords: [UUID: String] = [:]
    private var injectedError: CredentialVaultError?

    func containsPassword(for profileID: UUID) throws -> Bool {
        if let injectedError { throw injectedError }
        return passwords[profileID] != nil
    }

    func password(for profileID: UUID) throws -> String? {
        if let injectedError { throw injectedError }
        return passwords[profileID]
    }

    func save(password: String, for profileID: UUID) throws {
        if let injectedError { throw injectedError }
        passwords[profileID] = password
    }

    func deletePassword(for profileID: UUID) throws {
        if let injectedError { throw injectedError }
        passwords[profileID] = nil
    }

    func deleteAllPasswords() throws {
        if let injectedError { throw injectedError }
        passwords.removeAll(keepingCapacity: false)
    }

    func setInjectedError(_ error: CredentialVaultError?) {
        injectedError = error
    }
}
