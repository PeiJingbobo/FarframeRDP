import SwiftData
import XCTest
@testable import FarframeRDP

private actor FailingBulkDeleteVault: CredentialVaultProtocol {
    func containsPassword(for profileID: UUID) throws -> Bool { false }
    func password(for profileID: UUID) throws -> String? { nil }
    func save(password: String, for profileID: UUID) throws {}
    func deletePassword(for profileID: UUID) throws {}
    func deleteAllPasswords() throws { throw CredentialVaultError.interactionNotAllowed }
}

@MainActor
final class Phase10LocalDataClearTests: XCTestCase {
    func testInMemoryVaultBulkDeleteRemovesEveryCredentialAndIsIdempotent() async throws {
        let vault = InMemoryCredentialVault()
        let first = UUID()
        let orphaned = UUID()
        try await vault.save(password: "first-secret", for: first)
        try await vault.save(password: "orphan-secret", for: orphaned)

        try await vault.deleteAllPasswords()
        try await vault.deleteAllPasswords()

        let firstPassword = try await vault.password(for: first)
        let orphanedPassword = try await vault.password(for: orphaned)
        XCTAssertNil(firstPassword)
        XCTAssertNil(orphanedPassword)
    }

    func testClearAllRemovesProfilesTrustCredentialsAndPreferences() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let profileID = UUID()
        context.insert(ConnectionProfile(
            id: profileID,
            draft: ConnectionProfileDraft(
                displayName: "Disposable",
                host: "example.invalid",
                username: "tester"
            ),
            certificateTrustReference: "AA:BB:CC"
        ))
        try context.save()

        let vault = InMemoryCredentialVault()
        let orphanedCredentialID = UUID()
        try await vault.save(password: "profile-secret", for: profileID)
        try await vault.save(password: "orphan-secret", for: orphanedCredentialID)

        let domain = "FarframeRDPTests.LocalDataClear.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        preferences.set(false, forKey: ApplicationPreferenceKeys.automaticHostStatusChecks)
        preferences.set(true, forKey: ApplicationPreferenceKeys.enhancedShortcutCapture)
        defer { preferences.removePersistentDomain(forName: domain) }

        let result = await LocalDataClearService(
            vault: vault,
            preferences: preferences,
            preferenceDomain: domain,
            notificationCenter: NotificationCenter()
        ).clearAll(modelContext: context)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConnectionProfile>()).isEmpty)
        let profilePassword = try await vault.password(for: profileID)
        let orphanedPassword = try await vault.password(for: orphanedCredentialID)
        XCTAssertNil(profilePassword)
        XCTAssertNil(orphanedPassword)
        XCTAssertNil(preferences.persistentDomain(forName: domain))
    }

    func testCredentialFailureDoesNotPreventProfileTrustOrPreferenceRemoval() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(ConnectionProfile(
            draft: ConnectionProfileDraft(
                displayName: "Disposable",
                host: "example.invalid",
                username: "tester"
            ),
            certificateTrustReference: "AA:BB:CC"
        ))
        try context.save()

        let domain = "FarframeRDPTests.LocalDataClearFailure.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        preferences.set(true, forKey: "temporary")
        defer { preferences.removePersistentDomain(forName: domain) }

        let result = await LocalDataClearService(
            vault: FailingBulkDeleteVault(),
            preferences: preferences,
            preferenceDomain: domain,
            notificationCenter: NotificationCenter()
        ).clearAll(modelContext: context)

        XCTAssertEqual(result.failures.map(\.category), [.credentials])
        XCTAssertTrue(try context.fetch(FetchDescriptor<ConnectionProfile>()).isEmpty)
        XCTAssertNil(preferences.persistentDomain(forName: domain))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: FarframeSchemaV1.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: FarframeMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }
}
