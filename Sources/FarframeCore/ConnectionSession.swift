import Foundation

public enum ConnectionConfigurationError: Error, Equatable, Sendable {
    case emptyHost
    case invalidPort
    case emptyUsername
    case valueTooLong
}

public struct ConnectionEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let domain: String

    public init(host: String, port: Int, username: String, domain: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else {
            throw ConnectionConfigurationError.emptyHost
        }
        guard let port = UInt16(exactly: port), port > 0 else {
            throw ConnectionConfigurationError.invalidPort
        }
        guard !username.isEmpty else {
            throw ConnectionConfigurationError.emptyUsername
        }
        guard host.utf8.count <= 255,
              username.utf8.count <= 512,
              domain.utf8.count <= 512 else {
            throw ConnectionConfigurationError.valueTooLong
        }

        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
    }
}

public enum SessionPhase: String, Equatable, Sendable {
    case idle
    case resolving
    case connecting
    case authenticating
    case connected
    case reconnecting
    case disconnecting
    case disconnected
    case failed
}

public struct SessionStateMachine: Equatable, Sendable {
    public private(set) var sessionID: UUID?
    public private(set) var phase: SessionPhase = .idle

    public init() {}

    @discardableResult
    public mutating func begin(sessionID: UUID) -> Bool {
        guard phase == .idle || phase == .disconnected || phase == .failed else {
            return false
        }
        self.sessionID = sessionID
        phase = .resolving
        return true
    }

    @discardableResult
    public mutating func transition(sessionID: UUID, to next: SessionPhase) -> Bool {
        guard self.sessionID == sessionID, Self.allowedTransitions[phase, default: []].contains(next) else {
            return false
        }
        phase = next
        return true
    }

    @discardableResult
    public mutating func finish(sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID else {
            return false
        }
        switch phase {
        case .idle, .disconnected, .failed:
            return false
        case .resolving, .connecting, .authenticating, .connected, .reconnecting:
            guard transition(sessionID: sessionID, to: .disconnecting) else {
                return false
            }
        case .disconnecting:
            break
        }
        return transition(sessionID: sessionID, to: .disconnected)
    }

    private static let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [],
        .resolving: [.connecting, .disconnecting, .failed],
        .connecting: [.authenticating, .connected, .disconnecting, .failed],
        .authenticating: [.connected, .disconnecting, .failed],
        .connected: [.reconnecting, .disconnecting, .failed],
        .reconnecting: [.connected, .disconnecting, .failed],
        .disconnecting: [.disconnected, .failed],
        .disconnected: [],
        .failed: [],
    ]
}
