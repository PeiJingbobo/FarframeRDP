import XCTest
@testable import FarframeCore

final class FarframeCoreTests: XCTestCase {
    func testStableApplicationIdentifiers() {
        XCTAssertEqual(AppEnvironment.bundleIdentifier, "com.farframe.rdp")
        XCTAssertEqual(AppEnvironment.keychainService, "com.farframe.rdp.credentials")
    }

    func testAllRequiredLogCategoriesExist() {
        XCTAssertEqual(
            Set(LogCategory.allCases),
            Set([.app, .session, .input, .render, .security, .channel])
        )
    }

    func testDiagnosticRedactionDoesNotExposeSecret() {
        let canary = "farframe-secret-canary"
        let redacted = DiagnosticRedaction.privateValue(canary)

        XCTAssertEqual(redacted, "<private>")
        XCTAssertFalse(redacted.contains(canary))
        XCTAssertEqual(DiagnosticRedaction.privateValue(nil), "<none>")
    }

    func testDiagnosticArtifactBuilderRedactsSecretCanariesAndCrashDetails() throws {
        let password = "canary-password-7F0D"
        let host = "private-host-7F0D.invalid"
        let username = "private-user-7F0D"
        let fingerprint = "AA:7F:0D:BB"
        let artifact = try DiagnosticArtifactBuilder.build(
            sections: [
                "application": "Farframe RDP",
                "connection": "host=\(host) username=\(username) password=\(password)",
                "crash": "failure at /Users/private-account/Library/db token=\(password)",
                "certificate": "fingerprint=\(fingerprint)",
            ],
            sensitiveValues: [password, host, username, fingerprint]
        )
        let text = try XCTUnwrap(String(data: artifact, encoding: .utf8))

        for canary in [password, host, username, fingerprint, "private-account"] {
            XCTAssertFalse(text.contains(canary))
        }
        XCTAssertTrue(DiagnosticArtifactScanner.findings(
            in: text,
            secretCanaries: [password, host, username, fingerprint]
        ).isEmpty)
    }

    func testDiagnosticArtifactScannerRejectsCommonSecretShapes() {
        let raw = """
        password=canary
        Authorization: Bearer abc.def
        /Users/private-account/Library/Application Support/Farframe
        -----BEGIN PRIVATE KEY-----
        canary-key
        -----END PRIVATE KEY-----
        """
        XCTAssertEqual(
            DiagnosticArtifactScanner.findings(in: raw, secretCanaries: ["canary-key"]),
            [.secretCanary, .credentialAssignment, .authorizationHeader, .privateKey, .userHomePath]
        )
    }

    func testDiagnosticArtifactBuilderKeepsAllowlistedNonPrivateMetadata() throws {
        let artifact = try DiagnosticArtifactBuilder.build(sections: [
            "architecture": "arm64",
            "failure-code": "authentication_failed",
            "os-version": "macOS 26.0",
        ])
        let text = try XCTUnwrap(String(data: artifact, encoding: .utf8))
        XCTAssertEqual(
            text,
            "architecture: arm64\nfailure-code: authentication_failed\nos-version: macOS 26.0\n"
        )
    }

    func testErrorsHaveUserFacingDescriptions() {
        XCTAssertEqual(
            FarframeError.invalidConfiguration.errorDescription,
            "The application configuration is invalid."
        )
        XCTAssertNotNil(FarframeError.featureUnavailable(.remoteDesktop).errorDescription)
    }
}
