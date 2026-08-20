import Darwin
import SwiftData
import XCTest
@testable import FarframeRDP

private actor HostStatusSpy: HostStatusChecking {
    private(set) var callCount = 0
    let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        callCount += 1
        return result
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

@MainActor
final class Phase7Tests: XCTestCase {
    func testRememberedCertificateAutoTrustsExactFingerprintIncludingHostnameMismatch() {
        XCTAssertTrue(RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: "AA:BB:CC",
            challengeFingerprint: "AA:BB:CC"
        ))
        XCTAssertFalse(RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: "AA:BB:CC",
            challengeFingerprint: "DD:EE:FF"
        ))
        XCTAssertTrue(RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: "AA:BB:CC",
            challengeFingerprint: "AA:BB:CC"
        ))
        XCTAssertFalse(RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: nil,
            challengeFingerprint: "AA:BB:CC"
        ))
    }

    func testProfileValidationNormalizesFieldsAndRejectsSecretsFromSchema() throws {
        let draft = ConnectionProfileDraft(
            displayName: "  办公室电脑  ",
            host: "  workstation.example  ",
            port: 3390,
            username: "  user  ",
            domain: "  CORP  "
        )

        let validated = try draft.validated()

        XCTAssertEqual(validated.draft.displayName, "办公室电脑")
        XCTAssertEqual(validated.endpoint.host, "workstation.example")
        XCTAssertEqual(validated.endpoint.port, 3390)
        XCTAssertEqual(validated.endpoint.username, "user")
        XCTAssertEqual(validated.endpoint.domain, "CORP")

        let profile = ConnectionProfile(draft: validated.draft)
        let storedProperties = Set(Mirror(reflecting: profile).children.compactMap(\.label))
        XCTAssertFalse(storedProperties.contains("password"))
        XCTAssertFalse(storedProperties.contains("token"))
        XCTAssertFalse(storedProperties.contains("hash"))
        XCTAssertFalse(storedProperties.contains("privateKey"))
    }

    func testProfileRejectsMissingNameAndInvalidEndpoint() {
        XCTAssertThrowsError(try ConnectionProfileDraft(
            displayName: " ",
            host: "host",
            username: "user"
        ).validated()) { error in
            XCTAssertEqual(error as? ConnectionProfileValidationError, .emptyDisplayName)
        }

        XCTAssertThrowsError(try ConnectionProfileDraft(
            displayName: "Computer",
            host: "host",
            port: 0,
            username: "user"
        ).validated()) { error in
            XCTAssertEqual(
                error as? ConnectionProfileValidationError,
                .invalidEndpoint(.invalidPort)
            )
        }
    }

    func testSwiftDataProfileRoundTripKeepsStableIdentityAndNonSecretFields() throws {
        let schema = Schema(versionedSchema: FarframeSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: FarframeMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let id = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let profile = ConnectionProfile(
            id: id,
            draft: ConnectionProfileDraft(
                displayName: "Development PC",
                host: "rdp.example",
                username: "developer",
                domain: "LAB"
            ),
            certificateTrustReference: "AA:BB:CC",
            lastSuccessfulConnection: now,
            now: now
        )
        context.insert(profile)
        try context.save()

        let records = try context.fetch(FetchDescriptor<ConnectionProfile>())

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, id)
        XCTAssertEqual(records[0].addressSummary, "rdp.example")
        XCTAssertEqual(records[0].accountSummary, "LAB\\developer")
        XCTAssertEqual(records[0].certificateTrustReference, "AA:BB:CC")
        XCTAssertEqual(records[0].lastSuccessfulConnection, now)
    }

    func testNewProfileIsPersistedBeforeAConnectionCanSucceed() throws {
        let schema = Schema(versionedSchema: FarframeSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: FarframeMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        let profile = try ConnectionProfilePersistence.create(
            draft: ConnectionProfileDraft(
                displayName: "  Pending PC  ",
                host: "rdp.example",
                username: "developer"
            ),
            in: context,
            now: now
        )

        let records = try context.fetch(FetchDescriptor<ConnectionProfile>())
        XCTAssertEqual(records.map(\.id), [profile.id])
        XCTAssertEqual(records[0].displayName, "Pending PC")
        XCTAssertNil(records[0].lastSuccessfulConnection)
        XCTAssertNil(records[0].certificateTrustReference)
    }

    func testSessionCertificateStoreExistsWithPrivatePermissionsAndCanBeRemoved() throws {
        let directory = try SessionCertificateStore.prepare(sessionID: UUID())
        defer { SessionCertificateStore.remove(directory) }

        var status = stat()
        XCTAssertEqual(lstat(directory.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)

        SessionCertificateStore.remove(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProfileRoundTripKeepsIndependentDesktopAndRedirectionOptions() throws {
        let firstDraft = ConnectionProfileDraft(
            displayName: "First",
            host: "first.example",
            username: "user",
            gatewayOptions: ProfileGatewayOptions(
                enabled: true,
                host: "gateway.example",
                port: 443,
                useSameCredentials: true
            ),
            remoteAppOptions: ProfileRemoteAppOptions(
                enabled: true,
                program: "||notepad",
                arguments: "readme.txt",
                workingDirectory: "C:\\Temp"
            ),
            reconnectOptions: ProfileReconnectOptions(
                enabled: true,
                maximumAttempts: 4
            ),
            desktopOptions: ProfileDesktopOptions(
                monitorSelection: .allDisplays,
                resolution: .size1920x1080,
                presentationRate: .fps60
            ),
            redirectOptions: ProfileRedirectOptions(
                clipboardText: false,
                audioPlayback: true,
                microphoneRedirection: true,
                microphoneDeviceName: "Built-in Microphone",
                directoryRedirectionEnabled: true,
                redirectedDirectoryPath: "/tmp/first"
            )
        )
        let secondDraft = ConnectionProfileDraft(
            displayName: "Second",
            host: "second.example",
            username: "user",
            desktopOptions: ProfileDesktopOptions(),
            redirectOptions: ProfileRedirectOptions(
                clipboardText: true,
                audioPlayback: false
            )
        )

        let first = ConnectionProfileDraft(profile: ConnectionProfile(draft: firstDraft))
        let second = ConnectionProfileDraft(profile: ConnectionProfile(draft: secondDraft))

        XCTAssertEqual(first.desktopOptions, firstDraft.desktopOptions)
        XCTAssertEqual(first.gatewayOptions, firstDraft.gatewayOptions)
        XCTAssertEqual(first.remoteAppOptions, firstDraft.remoteAppOptions)
        XCTAssertEqual(first.reconnectOptions, firstDraft.reconnectOptions)
        XCTAssertEqual(first.redirectOptions, firstDraft.redirectOptions)
        let transientFailure = ConnectionFailure(
            message: "network",
            nativeCode: 1,
            retriableAfterEstablishedSession: true
        )
        XCTAssertTrue(first.reconnectOptions.policy.canRetry(
            failure: transientFailure,
            afterConnected: true,
            completedRetries: 3
        ))
        XCTAssertFalse(first.reconnectOptions.policy.canRetry(
            failure: transientFailure,
            afterConnected: true,
            completedRetries: 4
        ))
        XCTAssertEqual(first.redirectOptions.enabledDirectoryPath, "/tmp/first")
        XCTAssertTrue(first.channelOptions.dynamicResolution)
        XCTAssertFalse(first.channelOptions.clipboardText)
        XCTAssertTrue(first.channelOptions.audioPlayback)
        XCTAssertTrue(first.channelOptions.microphoneRedirection)
        XCTAssertEqual(first.channelOptions.microphoneDeviceName, "Built-in Microphone")
        XCTAssertEqual(first.channelOptions.redirectedDirectoryPath, "/tmp/first")
        XCTAssertEqual(first.channelOptions.monitorSelection, .allDisplays)
        XCTAssertEqual(first.channelOptions.gateway?.host, "gateway.example")
        XCTAssertEqual(first.channelOptions.gateway?.port, 443)
        XCTAssertTrue(first.channelOptions.gateway?.useSameCredentials == true)
        XCTAssertEqual(first.channelOptions.remoteApp?.program, "||notepad")
        XCTAssertEqual(first.channelOptions.remoteApp?.arguments, "readme.txt")
        XCTAssertEqual(first.channelOptions.remoteApp?.workingDirectory, "C:\\Temp")
        XCTAssertEqual(second.desktopOptions, secondDraft.desktopOptions)
        XCTAssertEqual(second.gatewayOptions, secondDraft.gatewayOptions)
        XCTAssertEqual(second.remoteAppOptions, secondDraft.remoteAppOptions)
        XCTAssertEqual(second.reconnectOptions, secondDraft.reconnectOptions)
        XCTAssertEqual(second.redirectOptions, secondDraft.redirectOptions)
        XCTAssertNil(second.redirectOptions.enabledDirectoryPath)
        XCTAssertTrue(second.channelOptions.dynamicResolution)
        XCTAssertEqual(second.channelOptions.monitorSelection, .window)
        XCTAssertTrue(second.channelOptions.clipboardText)
        XCTAssertFalse(second.channelOptions.audioPlayback)
        XCTAssertFalse(second.channelOptions.microphoneRedirection)
        XCTAssertEqual(second.channelOptions.microphoneDeviceName, "")
        XCTAssertNil(second.channelOptions.redirectedDirectoryPath)
        XCTAssertNil(second.channelOptions.remoteApp)
        XCTAssertNotEqual(first.redirectOptions, second.redirectOptions)
        XCTAssertEqual(first.desktopOptions.resolution.desktopSize, RemoteDesktopSize(
            width: 1920,
            height: 1080
        ))
    }

    func testLegacyProfileWithoutEncodedOptionsUsesSafeFeatureDefaults() {
        let profile = ConnectionProfile(
            draft: ConnectionProfileDraft(
                displayName: "Legacy",
                host: "legacy.example",
                username: "user"
            )
        )
        profile.desktopOptions = nil
        profile.gatewayOptions = nil
        profile.remoteAppOptions = nil
        profile.reconnectOptions = nil
        profile.redirectOptions = nil

        let draft = ConnectionProfileDraft(profile: profile)

        XCTAssertEqual(draft.desktopOptions.monitorSelection, .window)
        XCTAssertEqual(draft.desktopOptions.resolution, .fitWindow)
        XCTAssertEqual(draft.desktopOptions.presentationRate, .adaptive)
        XCTAssertFalse(draft.gatewayOptions.enabled)
        XCTAssertFalse(draft.remoteAppOptions.enabled)
        XCTAssertFalse(draft.reconnectOptions.enabled)
        XCTAssertEqual(draft.reconnectOptions.maximumAttempts, 3)
        XCTAssertTrue(draft.redirectOptions.clipboardText)
        XCTAssertTrue(draft.redirectOptions.audioPlayback)
        XCTAssertFalse(draft.redirectOptions.microphoneRedirection)
        XCTAssertEqual(draft.redirectOptions.microphoneDeviceName, "")
        XCTAssertFalse(draft.redirectOptions.directoryRedirectionEnabled)
        XCTAssertNil(draft.redirectOptions.enabledDirectoryPath)
    }

    func testProfileValidationClampsReconnectAttemptsToFiniteRange() throws {
        let tooMany = ConnectionProfileDraft(
            displayName: "Reconnect",
            host: "rdp.example",
            username: "user",
            reconnectOptions: ProfileReconnectOptions(
                enabled: true,
                maximumAttempts: 99
            )
        )
        let tooFew = ConnectionProfileDraft(
            displayName: "Reconnect",
            host: "rdp.example",
            username: "user",
            reconnectOptions: ProfileReconnectOptions(
                enabled: true,
                maximumAttempts: 0
            )
        )

        XCTAssertEqual(try tooMany.validated().draft.reconnectOptions.maximumAttempts, 5)
        XCTAssertEqual(try tooFew.validated().draft.reconnectOptions.maximumAttempts, 1)
    }

    func testLegacyDesktopOptionsDefaultsToFitWindowResolution() throws {
        let profile = ConnectionProfile(
            draft: ConnectionProfileDraft(
                displayName: "Legacy Display",
                host: "legacy-display.example",
                username: "user"
            )
        )
        profile.desktopOptions = #"{"dynamicResolution":false}"#.data(using: .utf8)

        let draft = ConnectionProfileDraft(profile: profile)

        XCTAssertEqual(draft.desktopOptions.monitorSelection, .window)
        XCTAssertEqual(draft.desktopOptions.resolution, .fitWindow)
        XCTAssertEqual(draft.desktopOptions.presentationRate, .adaptive)
    }

    func testEditingHostKeepsProfileIdentity() throws {
        let profile = ConnectionProfile(
            id: UUID(),
            draft: ConnectionProfileDraft(
                displayName: "Original",
                host: "old.example",
                username: "user"
            )
        )
        let originalID = profile.id
        let updated = try ConnectionProfileDraft(
            displayName: "Renamed",
            host: "new.example",
            username: "user"
        ).validated().draft

        profile.apply(updated)

        XCTAssertEqual(profile.id, originalID)
        XCTAssertEqual(profile.displayName, "Renamed")
        XCTAssertEqual(profile.host, "new.example")
    }

    func testInMemoryVaultSupportsCreateReadUpdateDeleteAndFailure() async throws {
        let vault = InMemoryCredentialVault()
        let id = UUID()

        let initiallyContainsPassword = try await vault.containsPassword(for: id)
        let initialPassword = try await vault.password(for: id)
        XCTAssertFalse(initiallyContainsPassword)
        XCTAssertNil(initialPassword)

        let initialValue = UUID().uuidString
        try await vault.save(password: initialValue, for: id)
        let containsFirstPassword = try await vault.containsPassword(for: id)
        let firstPassword = try await vault.password(for: id)
        XCTAssertTrue(containsFirstPassword)
        XCTAssertEqual(firstPassword, initialValue)

        let replacementValue = UUID().uuidString
        try await vault.save(password: replacementValue, for: id)
        let replacementPassword = try await vault.password(for: id)
        XCTAssertEqual(replacementPassword, replacementValue)

        try await vault.deletePassword(for: id)
        let deletedPassword = try await vault.password(for: id)
        XCTAssertNil(deletedPassword)
        try await vault.deletePassword(for: id)

        await vault.setInjectedError(.interactionNotAllowed)
        do {
            _ = try await vault.password(for: id)
            XCTFail("Expected the injected Keychain failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .interactionNotAllowed)
        }
    }

    func testKeychainVaultUsesTestScopedServiceAndStableProfileUUID() async throws {
        let service = "com.farframe.rdp.tests.\(UUID().uuidString)"
        let vault = KeychainCredentialVault(service: service)
        let profileID = UUID()

        try await vault.deletePassword(for: profileID)
        let initiallyContainsPassword = try await vault.containsPassword(for: profileID)
        XCTAssertFalse(initiallyContainsPassword)

        let initialValue = UUID().uuidString
        try await vault.save(password: initialValue, for: profileID)
        let containsPassword = try await vault.containsPassword(for: profileID)
        let firstPassword = try await vault.password(for: profileID)
        XCTAssertTrue(containsPassword)
        XCTAssertEqual(firstPassword, initialValue)

        let replacementValue = UUID().uuidString
        try await vault.save(password: replacementValue, for: profileID)
        let updatedPassword = try await vault.password(for: profileID)
        XCTAssertEqual(updatedPassword, replacementValue)

        try await vault.deletePassword(for: profileID)
        let deletedPassword = try await vault.password(for: profileID)
        XCTAssertNil(deletedPassword)
    }

    func testHostStatusRejectsInvalidTargetWithoutNetworkAccess() async {
        let service = HostStatusService()

        let reachable = await service.isReachable(host: "", port: 3389, timeout: .milliseconds(10))

        XCTAssertFalse(reachable)
    }

    func testReachabilityTitlesDistinguishReachableAndUnavailableTargets() {
        XCTAssertEqual(HostReachabilityState.possiblyOnline.title, "在线")
        XCTAssertEqual(HostReachabilityState.unreachable.title, "暂时不可达")
        XCTAssertEqual(HostReachabilityState.recentlyConnected.title, "最近连接成功")
    }

    func testDisabledAutomaticReachabilityClearsStatusAndDoesNotProbe() async {
        let hostStatus = HostStatusSpy(result: true)
        let controller = ProfileLibraryController(
            vault: InMemoryCredentialVault(),
            hostStatusService: hostStatus
        )
        let profile = ConnectionProfile(
            draft: ConnectionProfileDraft(
                displayName: "Computer",
                host: "rdp.example",
                username: "user"
            )
        )

        await controller.refresh(
            profiles: [profile],
            automaticReachability: true
        ).value
        XCTAssertEqual(controller.reachability[profile.id], .possiblyOnline)

        await controller.refresh(
            profiles: [profile],
            automaticReachability: false
        ).value
        let callCount = await hostStatus.numberOfCalls()

        XCTAssertTrue(controller.reachability.isEmpty)
        XCTAssertEqual(controller.credentialAvailability[profile.id], .missing)
        XCTAssertEqual(callCount, 1, "Disabling automatic checks must not start another probe")
    }

    func testEnabledAutomaticReachabilityPublishesProbeResult() async {
        let hostStatus = HostStatusSpy(result: false)
        let controller = ProfileLibraryController(
            vault: InMemoryCredentialVault(),
            hostStatusService: hostStatus
        )
        let profile = ConnectionProfile(
            draft: ConnectionProfileDraft(
                displayName: "Computer",
                host: "rdp.example",
                username: "user"
            )
        )

        await controller.refresh(
            profiles: [profile],
            automaticReachability: true
        ).value
        let callCount = await hostStatus.numberOfCalls()

        XCTAssertEqual(controller.reachability[profile.id], .unreachable)
        XCTAssertEqual(callCount, 1)
    }
}
