import Foundation
import SwiftData

extension Notification.Name {
    static let farframeWillClearLocalData = Notification.Name("FarframeWillClearLocalData")
}

enum LocalDataCategory: String, CaseIterable, Equatable, Sendable {
    case credentials
    case profilesAndCertificateTrust
    case preferences
}

struct LocalDataClearFailure: Equatable, Sendable {
    let category: LocalDataCategory
    let message: String
}

struct LocalDataClearResult: Equatable, Sendable {
    let failures: [LocalDataClearFailure]

    var succeeded: Bool { failures.isEmpty }
}

@MainActor
struct LocalDataClearService {
    let vault: any CredentialVaultProtocol
    let preferences: UserDefaults
    let preferenceDomain: String
    let notificationCenter: NotificationCenter

    init(
        vault: any CredentialVaultProtocol = KeychainCredentialVault(),
        preferences: UserDefaults = .standard,
        preferenceDomain: String = Bundle.main.bundleIdentifier ?? "com.farframe.rdp",
        notificationCenter: NotificationCenter = .default
    ) {
        self.vault = vault
        self.preferences = preferences
        self.preferenceDomain = preferenceDomain
        self.notificationCenter = notificationCenter
    }

    func clearAll(modelContext: ModelContext) async -> LocalDataClearResult {
        notificationCenter.post(name: .farframeWillClearLocalData, object: nil)
        var failures: [LocalDataClearFailure] = []

        do {
            try await vault.deleteAllPasswords()
        } catch {
            failures.append(.init(category: .credentials, message: error.localizedDescription))
        }

        do {
            let profiles = try modelContext.fetch(FetchDescriptor<ConnectionProfile>())
            profiles.forEach(modelContext.delete)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            failures.append(.init(category: .profilesAndCertificateTrust, message: error.localizedDescription))
        }

        preferences.removePersistentDomain(forName: preferenceDomain)
        if preferences.persistentDomain(forName: preferenceDomain) != nil {
            failures.append(.init(
                category: .preferences,
                message: String(localized: "应用偏好设置未能完全清除。")
            ))
        }

        return LocalDataClearResult(failures: failures)
    }
}
