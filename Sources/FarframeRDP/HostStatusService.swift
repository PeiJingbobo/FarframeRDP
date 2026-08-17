import Foundation
import Network

enum HostReachabilityState: Equatable, Sendable {
    case unchecked
    case checking
    case possiblyOnline
    case unreachable
    case recentlyConnected

    var title: String {
        switch self {
        case .unchecked:
            String(localized: "未检查")
        case .checking:
            String(localized: "正在检查…")
        case .possiblyOnline:
            String(localized: "在线")
        case .unreachable:
            String(localized: "暂时不可达")
        case .recentlyConnected:
            String(localized: "最近连接成功")
        }
    }

    var symbolName: String {
        switch self {
        case .unchecked:
            "circle.dotted"
        case .checking:
            "hourglass"
        case .possiblyOnline, .recentlyConnected:
            "circle.fill"
        case .unreachable:
            "exclamationmark.circle"
        }
    }
}

struct HostProbeTarget: Equatable, Sendable {
    let profileID: UUID
    let host: String
    let port: UInt16
}

protocol HostStatusChecking: Sendable {
    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool
}

struct HostStatusService: HostStatusChecking, Sendable {
    func isReachable(
        host: String,
        port: UInt16,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        guard !host.isEmpty, let networkPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }
        let probe = ConnectionProbe(
            connection: NWConnection(
                host: NWEndpoint.Host(host),
                port: networkPort,
                using: .tcp
            )
        )
        return await withTaskCancellationHandler {
            await probe.run(timeout: timeout)
        } onCancel: {
            probe.cancel()
        }
    }
}

private final class ConnectionProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.farframe.rdp.host-status")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func run(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finish(true)
                case .failed, .cancelled:
                    self?.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            let timeoutSeconds = max(0.1, Double(timeout.components.seconds) +
                Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(false)
            }
        }
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ result: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: result)
    }
}

enum CredentialAvailability: Equatable, Sendable {
    case unknown
    case checking
    case saved
    case missing
    case unavailable
}

@MainActor
final class ProfileLibraryController: ObservableObject {
    @Published private(set) var reachability: [UUID: HostReachabilityState] = [:]
    @Published private(set) var credentialAvailability: [UUID: CredentialAvailability] = [:]

    let vault: any CredentialVaultProtocol
    private let hostStatusService: any HostStatusChecking
    private var refreshTask: Task<Void, Never>?

    init(
        vault: any CredentialVaultProtocol = KeychainCredentialVault(),
        hostStatusService: any HostStatusChecking = HostStatusService()
    ) {
        self.vault = vault
        self.hostStatusService = hostStatusService
    }

    deinit {
        refreshTask?.cancel()
    }

    @discardableResult
    func refresh(
        profiles: [ConnectionProfile],
        automaticReachability: Bool
    ) -> Task<Void, Never> {
        refreshTask?.cancel()
        if !automaticReachability {
            reachability.removeAll()
        }
        let snapshots = profiles.compactMap { profile -> HostProbeTarget? in
            guard let port = UInt16(exactly: profile.port) else { return nil }
            credentialAvailability[profile.id] = .checking
            if automaticReachability {
                reachability[profile.id] = .checking
            }
            return HostProbeTarget(profileID: profile.id, host: profile.host, port: port)
        }
        let vault = vault
        let hostStatusService = hostStatusService

        let task = Task { [weak self] in
            await withTaskGroup(of: (UUID, CredentialAvailability, HostReachabilityState?).self) { group in
                for snapshot in snapshots {
                    group.addTask {
                        let credential: CredentialAvailability
                        do {
                            credential = try await vault.containsPassword(for: snapshot.profileID)
                                ? .saved
                                : .missing
                        } catch {
                            credential = .unavailable
                        }

                        let status: HostReachabilityState?
                        if automaticReachability {
                            status = await hostStatusService.isReachable(
                                host: snapshot.host,
                                port: snapshot.port,
                                timeout: .seconds(2)
                            ) ? .possiblyOnline : .unreachable
                        } else {
                            status = nil
                        }
                        return (snapshot.profileID, credential, status)
                    }
                }

                for await (profileID, credential, status) in group {
                    guard !Task.isCancelled else { return }
                    self?.credentialAvailability[profileID] = credential
                    if let status {
                        self?.reachability[profileID] = status
                    }
                }
            }
        }
        refreshTask = task
        return task
    }

    func markCredential(_ availability: CredentialAvailability, for profileID: UUID) {
        credentialAvailability[profileID] = availability
    }

    func markConnected(profileID: UUID) {
        reachability[profileID] = .recentlyConnected
    }

    func remove(profileID: UUID) {
        credentialAvailability[profileID] = nil
        reachability[profileID] = nil
    }
}
