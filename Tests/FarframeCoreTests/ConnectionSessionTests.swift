import XCTest
@testable import FarframeCore

final class ConnectionSessionTests: XCTestCase {
    func testEndpointTrimsMetadataAndAllowsEmptyDomain() throws {
        let endpoint = try ConnectionEndpoint(
            host: "  example.test  ",
            port: 3389,
            username: "  user  ",
            domain: " "
        )

        XCTAssertEqual(endpoint.host, "example.test")
        XCTAssertEqual(endpoint.port, 3389)
        XCTAssertEqual(endpoint.username, "user")
        XCTAssertEqual(endpoint.domain, "")
    }

    func testEndpointRejectsInvalidInputs() {
        XCTAssertThrowsError(try ConnectionEndpoint(host: "", port: 3389, username: "user", domain: ""))
        XCTAssertThrowsError(try ConnectionEndpoint(host: "host", port: 0, username: "user", domain: ""))
        XCTAssertThrowsError(try ConnectionEndpoint(host: "host", port: 65_536, username: "user", domain: ""))
        XCTAssertThrowsError(try ConnectionEndpoint(host: "host", port: 3389, username: "", domain: ""))
    }

    func testStateMachineAcceptsConnectionLifecycle() {
        let id = UUID()
        var machine = SessionStateMachine()

        XCTAssertTrue(machine.begin(sessionID: id))
        XCTAssertTrue(machine.transition(sessionID: id, to: .connecting))
        XCTAssertTrue(machine.transition(sessionID: id, to: .authenticating))
        XCTAssertTrue(machine.transition(sessionID: id, to: .connected))
        XCTAssertTrue(machine.transition(sessionID: id, to: .disconnecting))
        XCTAssertTrue(machine.transition(sessionID: id, to: .disconnected))
    }

    func testStateMachineAcceptsReconnectLifecycle() {
        let id = UUID()
        var machine = SessionStateMachine()

        XCTAssertTrue(machine.begin(sessionID: id))
        XCTAssertTrue(machine.transition(sessionID: id, to: .connecting))
        XCTAssertTrue(machine.transition(sessionID: id, to: .connected))
        XCTAssertTrue(machine.transition(sessionID: id, to: .reconnecting))
        XCTAssertFalse(machine.transition(sessionID: id, to: .resolving))
        XCTAssertTrue(machine.transition(sessionID: id, to: .connected))
        XCTAssertTrue(machine.transition(sessionID: id, to: .disconnecting))
        XCTAssertTrue(machine.transition(sessionID: id, to: .disconnected))
    }

    func testStaleSessionAndInvalidTransitionsAreRejected() {
        let active = UUID()
        var machine = SessionStateMachine()

        XCTAssertTrue(machine.begin(sessionID: active))
        XCTAssertFalse(machine.transition(sessionID: UUID(), to: .connecting))
        XCTAssertFalse(machine.transition(sessionID: active, to: .connected))
        XCTAssertEqual(machine.phase, .resolving)
    }

    func testTerminalStateCanStartNewSessionWithoutAcceptingOldCallbacks() {
        let old = UUID()
        let new = UUID()
        var machine = SessionStateMachine()

        XCTAssertTrue(machine.begin(sessionID: old))
        XCTAssertTrue(machine.transition(sessionID: old, to: .failed))
        XCTAssertTrue(machine.begin(sessionID: new))
        XCTAssertFalse(machine.transition(sessionID: old, to: .connecting))
        XCTAssertTrue(machine.transition(sessionID: new, to: .connecting))
    }

    func testFinishConvergesActiveSessionToDisconnectedAndRejectsStaleSession() {
        let active = UUID()
        var machine = SessionStateMachine()

        XCTAssertTrue(machine.begin(sessionID: active))
        XCTAssertFalse(machine.finish(sessionID: UUID()))
        XCTAssertTrue(machine.transition(sessionID: active, to: .connecting))
        XCTAssertTrue(machine.transition(sessionID: active, to: .connected))
        XCTAssertTrue(machine.finish(sessionID: active))
        XCTAssertEqual(machine.phase, .disconnected)
        XCTAssertFalse(machine.finish(sessionID: active))
    }
}
