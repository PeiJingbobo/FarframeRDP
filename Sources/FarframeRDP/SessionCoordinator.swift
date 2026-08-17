import FarframeCore
import FarframeRDPBridge
import Foundation

struct CertificateChallenge: Equatable, Sendable {
    let hostname: String
    let port: UInt16
    let commonName: String
    let subject: String
    let issuer: String
    let fingerprint: String
    let oldSubject: String?
    let oldIssuer: String?
    let oldFingerprint: String?
    let hostnameMismatch: Bool
    let changed: Bool
}

enum RememberedCertificateTrustPolicy {
    static func canAutomaticallyTrust(
        storedFingerprint: String?,
        challengeFingerprint: String
    ) -> Bool {
        guard let storedFingerprint else {
            return false
        }
        return storedFingerprint == challengeFingerprint
    }
}

struct ConnectionFailure: Equatable, Sendable {
    let message: String
    let nativeCode: UInt32
    let retriableAfterEstablishedSession: Bool

    init(
        message: String,
        nativeCode: UInt32,
        retriableAfterEstablishedSession: Bool = false
    ) {
        self.message = message
        self.nativeCode = nativeCode
        self.retriableAfterEstablishedSession = retriableAfterEstablishedSession
    }
}

struct ConnectionReconnectPolicy: Equatable, Sendable {
    var enabled: Bool
    var maximumAttempts: Int

    static let disabled = ConnectionReconnectPolicy(enabled: false, maximumAttempts: 0)
    static let defaults = ConnectionReconnectPolicy(enabled: false, maximumAttempts: 3)

    func canRetry(failure: ConnectionFailure, afterConnected connected: Bool, completedRetries: Int) -> Bool {
        enabled &&
            connected &&
            failure.retriableAfterEstablishedSession &&
            completedRetries < maximumAttempts
    }

    func delayNanoseconds(forCompletedRetries completedRetries: Int) -> UInt64 {
        let seconds = min(8, 1 << min(completedRetries, 3))
        return UInt64(seconds) * 1_000_000_000
    }
}

private enum ConnectionWorkerEvent: Sendable {
    case phase(SessionPhase)
    case certificate(CertificateChallenge)
    case desktopSize(RemoteDesktopSize)
    case frameAvailable
    case cursor(RemoteCursorUpdate)
    case clipboardReady
    case clipboardText(String)
    case displayControlReady
    case failed(ConnectionFailure)
    case finished
}

struct ConnectionChannelOptions: Equatable, Sendable {
    var dynamicResolution: Bool
    var monitorSelection: RemoteMonitorSelection
    var clipboardText: Bool
    var audioPlayback: Bool
    var microphoneRedirection: Bool
    var microphoneDeviceName: String
    var redirectedDirectoryPath: String?
    var gateway: ConnectionGatewayOptions?
    var remoteApp: ConnectionRemoteAppOptions?

    static let defaults = ConnectionChannelOptions(
        dynamicResolution: true,
        monitorSelection: .window,
        clipboardText: true,
        audioPlayback: true,
        microphoneRedirection: false,
        microphoneDeviceName: "",
        redirectedDirectoryPath: nil,
        gateway: nil,
        remoteApp: nil
    )
}

struct ConnectionGatewayOptions: Equatable, Sendable {
    var host: String
    var port: UInt16
    var useSameCredentials: Bool
    var username: String
    var domain: String
}

struct ConnectionRemoteAppOptions: Equatable, Sendable {
    var program: String
    var arguments: String
    var workingDirectory: String
}

private func copiedString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else {
        return ""
    }
    return String(cString: pointer)
}

private func localizedConnectionFailure(_ failure: FFRConnectionFailure) -> String {
    switch failure {
    case FFR_CONNECTION_FAILURE_DNS:
        String(localized: "无法解析主机名。")
    case FFR_CONNECTION_FAILURE_NETWORK:
        String(localized: "无法访问远程桌面服务。")
    case FFR_CONNECTION_FAILURE_TLS:
        String(localized: "TLS 连接失败。")
    case FFR_CONNECTION_FAILURE_CERTIFICATE_REJECTED:
        String(localized: "远程证书已被拒绝。")
    case FFR_CONNECTION_FAILURE_CERTIFICATE_CHANGED:
        String(localized: "远程证书已更改。")
    case FFR_CONNECTION_FAILURE_AUTHENTICATION:
        String(localized: "身份认证失败。")
    case FFR_CONNECTION_FAILURE_SERVER_REFUSED:
        String(localized: "服务器拒绝了连接。")
    case FFR_CONNECTION_FAILURE_PROTOCOL:
        String(localized: "RDP 协议协商失败。")
    case FFR_CONNECTION_FAILURE_CANCELLED:
        String(localized: "连接已取消。")
    case FFR_CONNECTION_FAILURE_SECURITY_NEGOTIATION:
        String(localized: "TLS/NLA 安全协商失败。")
    case FFR_CONNECTION_FAILURE_GATEWAY_AUTHENTICATION:
        String(localized: "RD Gateway 身份认证失败。")
    case FFR_CONNECTION_FAILURE_GATEWAY_ACCESS_DENIED:
        String(localized: "RD Gateway 拒绝访问目标电脑。")
    default:
        String(localized: "发生未知连接错误。")
    }
}

private func localizedBridgeResult(_ result: FFRResult) -> String {
    switch result {
    case FFR_RESULT_INVALID_ARGUMENT:
        String(localized: "内部调用参数无效。")
    case FFR_RESULT_ALLOCATION_FAILED:
        String(localized: "无法分配连接所需的内存。")
    case FFR_RESULT_CONTEXT_CREATION_FAILED:
        String(localized: "无法创建 FreeRDP 上下文。")
    case FFR_RESULT_THREAD_VIOLATION:
        String(localized: "连接操作发生在线程错误的位置。")
    case FFR_RESULT_INVALID_STATE:
        String(localized: "当前会话状态不允许此操作。")
    case FFR_RESULT_SETTINGS_FAILED:
        String(localized: "无法应用 RDP 连接设置。")
    case FFR_RESULT_CONNECTION_FAILED:
        String(localized: "RDP 连接失败。")
    case FFR_RESULT_CANCELLED:
        String(localized: "连接已取消。")
    case FFR_RESULT_INPUT_QUEUE_FULL:
        String(localized: "远程输入队列已满。")
    default:
        String(localized: "发生未知的 Bridge 错误。")
    }
}

private let connectionEventCallback: FFREventCallback = { _, event, context in
    guard let event, let context else {
        return
    }
    let worker = Unmanaged<ConnectionWorker>.fromOpaque(context).takeUnretainedValue()
    worker.receive(event: event.pointee)
}

private let graphicsEventCallback: FFRGraphicsEventCallback = { _, event, context in
    guard let event, let context else {
        return
    }
    let worker = Unmanaged<ConnectionWorker>.fromOpaque(context).takeUnretainedValue()
    worker.receive(graphicsEvent: event.pointee)
}

private let clipboardEventCallback: FFRClipboardEventCallback = { _, event, context in
    guard let event, let context else {
        return
    }
    let worker = Unmanaged<ConnectionWorker>.fromOpaque(context).takeUnretainedValue()
    worker.receive(clipboardEvent: event.pointee)
}

private final class ConnectionWorker: @unchecked Sendable {
    private let id: UUID
    private let endpoint: ConnectionEndpoint
    private let channelOptions: ConnectionChannelOptions
    private let reconnectPolicy: ConnectionReconnectPolicy
    private var password: String
    private let handler: @Sendable (UUID, ConnectionWorkerEvent) -> Void
    private let lock = NSLock()
    private let frameMailbox = RemoteFrameMailbox()
    private var session: OpaquePointer?
    private var cancellationRequested = false
    private var attemptConnected = false
    private var connectionWasEstablished = false
    private var attemptFailure: ConnectionFailure?

    init(
        id: UUID,
        endpoint: ConnectionEndpoint,
        channelOptions: ConnectionChannelOptions,
        reconnectPolicy: ConnectionReconnectPolicy,
        password: String,
        handler: @escaping @Sendable (UUID, ConnectionWorkerEvent) -> Void
    ) {
        self.id = id
        self.endpoint = endpoint
        self.channelOptions = channelOptions
        self.reconnectPolicy = reconnectPolicy
        self.password = password
        self.handler = handler
    }

    func start() {
        DispatchQueue(label: "com.farframe.rdp.connection.\(id.uuidString)").async { [self] in
            run()
        }
    }

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let current = session
        if let current {
            _ = FFRSessionRequestCancellation(current)
        }
        lock.unlock()
    }

    func resolveCertificate(_ decision: FFRCertificateDecision) {
        lock.lock()
        let current = session
        if let current {
            _ = FFRSessionResolveCertificate(current, decision)
        }
        lock.unlock()
    }

    func sendInput(_ command: RemoteInputCommand) {
        lock.lock()
        guard let current = session else {
            lock.unlock()
            return
        }
        let result: FFRResult
        switch command {
        case let .scanCode(scanCode, down, repeatKey):
            result = FFRSessionSendScanCode(current, scanCode, down, repeatKey)
        case let .pointerMove(position):
            result = FFRSessionSendPointerMove(current, position.x, position.y)
        case let .pointerButton(button, down, position):
            let nativeButton: FFRPointerButton
            switch button {
            case .left: nativeButton = FFR_POINTER_BUTTON_LEFT
            case .right: nativeButton = FFR_POINTER_BUTTON_RIGHT
            case .middle: nativeButton = FFR_POINTER_BUTTON_MIDDLE
            case .x1: nativeButton = FFR_POINTER_BUTTON_X1
            case .x2: nativeButton = FFR_POINTER_BUTTON_X2
            }
            result = FFRSessionSendPointerButton(
                current,
                nativeButton,
                down,
                position.x,
                position.y
            )
        case let .wheel(delta, horizontal, position):
            result = FFRSessionSendPointerWheel(
                current,
                delta,
                horizontal,
                position.x,
                position.y
            )
        case let .synchronizeLocks(capsLock, numLock, scrollLock):
            result = FFRSessionSynchronizeLocks(
                current,
                capsLock,
                numLock,
                scrollLock
            )
        case .releaseAll:
            result = FFRSessionReleaseAllInput(current)
        case let .resize(size):
            result = FFRSessionRequestResize(
                current,
                UInt32(size.width),
                UInt32(size.height)
            )
        case let .monitorLayout(layouts):
            let nativeLayouts = layouts.map { layout in
                FFRMonitorLayout(
                    left: layout.left,
                    top: layout.top,
                    width: UInt32(layout.width),
                    height: UInt32(layout.height),
                    desktopScaleFactor: UInt32(layout.desktopScaleFactor),
                    deviceScaleFactor: UInt32(layout.deviceScaleFactor),
                    primary: layout.primary
                )
            }
            result = nativeLayouts.withUnsafeBufferPointer { buffer in
                FFRSessionRequestMonitorLayout(
                    current,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        if result == FFR_RESULT_INPUT_QUEUE_FULL {
            _ = FFRSessionReleaseAllInput(current)
        }
        lock.unlock()
    }

    func releaseAllInput() {
        lock.lock()
        if let current = session {
            _ = FFRSessionReleaseAllInput(current)
        }
        lock.unlock()
    }

    func publishClipboardText(_ text: String?) {
        guard channelOptions.clipboardText else { return }
        let utf16 = text.map { Array($0.utf16) } ?? []
        lock.lock()
        guard let current = session else {
            lock.unlock()
            return
        }
        if utf16.isEmpty {
            _ = FFRSessionPublishClipboardText(current, nil, 0)
        } else {
            utf16.withUnsafeBufferPointer { buffer in
                _ = FFRSessionPublishClipboardText(current, buffer.baseAddress, buffer.count)
            }
        }
        lock.unlock()
    }

    fileprivate func receive(event: FFREvent) {
        switch event.type {
        case FFR_EVENT_RESOLVING:
            handler(id, .phase(.resolving))
        case FFR_EVENT_CONNECTING:
            handler(id, .phase(.connecting))
        case FFR_EVENT_AUTHENTICATING:
            handler(id, .phase(.authenticating))
        case FFR_EVENT_CERTIFICATE_REQUESTED:
            guard let info = event.certificate else {
                return
            }
            let value = info.pointee
            handler(
                id,
                .certificate(
                    CertificateChallenge(
                        hostname: copiedString(value.hostname),
                        port: value.port,
                        commonName: copiedString(value.commonName),
                        subject: copiedString(value.subject),
                        issuer: copiedString(value.issuer),
                        fingerprint: copiedString(value.fingerprint),
                        oldSubject: value.oldSubject.map { String(cString: $0) },
                        oldIssuer: value.oldIssuer.map { String(cString: $0) },
                        oldFingerprint: value.oldFingerprint.map { String(cString: $0) },
                        hostnameMismatch: value.hostnameMismatch,
                        changed: value.changed
                    )
                )
            )
        case FFR_EVENT_CONNECTED:
            lock.lock()
            attemptConnected = true
            connectionWasEstablished = true
            lock.unlock()
            handler(id, .phase(.connected))
        case FFR_EVENT_DISCONNECTING:
            break
        case FFR_EVENT_DISCONNECTED:
            break
        case FFR_EVENT_DISPLAY_CONTROL_READY:
            handler(id, .displayControlReady)
        case FFR_EVENT_FAILED:
            lock.lock()
            attemptFailure = ConnectionFailure(
                message: localizedConnectionFailure(event.failure),
                nativeCode: event.nativeErrorCode,
                retriableAfterEstablishedSession: event.failure == FFR_CONNECTION_FAILURE_NETWORK
            )
            lock.unlock()
        default:
            break
        }
    }

    fileprivate func receive(graphicsEvent event: FFRGraphicsEvent) {
        switch event.type {
        case FFR_GRAPHICS_EVENT_DESKTOP_SIZE:
            if let size = RemoteDesktopSize(
                width: Int(event.desktopWidth),
                height: Int(event.desktopHeight)
            ) {
                handler(id, .desktopSize(size))
            }
        case FFR_GRAPHICS_EVENT_FRAME:
            guard let pixels = event.pixels,
                  let bufferLength = Int(exactly: event.bufferLength) else {
                return
            }
            let shouldNotify = frameMailbox.ingest(
                desktopWidth: Int(event.desktopWidth),
                desktopHeight: Int(event.desktopHeight),
                sourceStride: Int(event.sourceStride),
                pixels: pixels,
                bufferLength: bufferLength,
                dirtyX: Int(event.dirtyRect.x),
                dirtyY: Int(event.dirtyRect.y),
                dirtyWidth: Int(event.dirtyRect.width),
                dirtyHeight: Int(event.dirtyRect.height),
                sequenceNumber: event.sequenceNumber
            )
            if shouldNotify {
                handler(id, .frameAvailable)
            }
        case FFR_GRAPHICS_EVENT_CURSOR_SHAPE:
            guard let pixels = event.pixels,
                  let bufferLength = Int(exactly: event.bufferLength),
                  let shape = RemoteCursorShape(
                    width: Int(event.cursorWidth),
                    height: Int(event.cursorHeight),
                    hotspotX: Int(event.cursorHotspotX),
                    hotspotY: Int(event.cursorHotspotY),
                    pixels: Data(bytes: pixels, count: bufferLength)
                  ) else {
                return
            }
            handler(id, .cursor(.shape(shape)))
        case FFR_GRAPHICS_EVENT_CURSOR_POSITION:
            handler(id, .cursor(.position(
                x: Int(event.cursorX),
                y: Int(event.cursorY)
            )))
        case FFR_GRAPHICS_EVENT_CURSOR_HIDDEN:
            handler(id, .cursor(.hidden))
        case FFR_GRAPHICS_EVENT_CURSOR_DEFAULT:
            handler(id, .cursor(.defaultCursor))
        default:
            break
        }
    }

    fileprivate func receive(clipboardEvent event: FFRClipboardEvent) {
        switch event.type {
        case FFR_CLIPBOARD_EVENT_READY:
            handler(id, .clipboardReady)
        case FFR_CLIPBOARD_EVENT_REMOTE_TEXT:
            guard let baseAddress = event.utf16CodeUnits,
                  let count = Int(exactly: event.length) else {
                return
            }
            let buffer = UnsafeBufferPointer(start: baseAddress, count: count)
            handler(id, .clipboardText(String(decoding: buffer, as: UTF16.self)))
        default:
            break
        }
    }

    fileprivate func consumePendingFrame(
        _ consumer: (
            RemoteDesktopSize,
            RemoteFrameRect,
            UnsafeRawBufferPointer,
            Int,
            UInt64
        ) -> Void
    ) {
        frameMailbox.consumePendingFrame(consumer)
    }

    private func run() {
        var completedRetries = 0
        var finalFailure: ConnectionFailure?

        while true {
            let outcome = runAttempt()
            switch outcome {
            case .disconnected:
                finalFailure = nil
                break
            case let .failed(failure, connectedBeforeFailure):
                if shouldRetry(
                    failure: failure,
                    connectedBeforeFailure: connectedBeforeFailure,
                    completedRetries: completedRetries
                ) {
                    completedRetries += 1
                    handler(id, .phase(.reconnecting))
                    guard waitBeforeReconnect(completedRetries: completedRetries) else {
                        finalFailure = nil
                        break
                    }
                    continue
                }
                finalFailure = failure
            }
            break
        }

        password.removeAll(keepingCapacity: false)
        if let finalFailure {
            handler(id, .failed(finalFailure))
        }
        handler(id, .finished)
    }

    private enum AttemptOutcome {
        case disconnected
        case failed(ConnectionFailure, connectedBeforeFailure: Bool)
    }

    private func runAttempt() -> AttemptOutcome {
        lock.lock()
        attemptConnected = false
        attemptFailure = nil
        lock.unlock()

        var ownedSession: OpaquePointer?
        let createResult = FFRSessionCreate(
            connectionEventCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &ownedSession
        )
        guard createResult == FFR_RESULT_OK, let createdSession = ownedSession else {
            return .failed(ConnectionFailure(
                message: localizedBridgeResult(createResult),
                nativeCode: 0
            ), connectedBeforeFailure: false)
        }

        lock.lock()
        session = createdSession
        lock.unlock()
        defer {
            lock.lock()
            session = nil
            lock.unlock()
            _ = FFRSessionDestroy(&ownedSession)
        }

        let certificateStorePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarframeRDP-CertificateChecks", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .path
        let endpointPort = endpoint.port
        let dynamicResolution = channelOptions.dynamicResolution
        let clipboardText = channelOptions.clipboardText
        let audioPlayback = channelOptions.audioPlayback
        let microphoneRedirection = channelOptions.microphoneRedirection
        let microphoneDeviceName = microphoneRedirection
            ? MicrophoneDeviceMenuOption.resolvedDeviceName(
                savedSelection: channelOptions.microphoneDeviceName,
                availableDevices: MicrophoneInputDeviceSource.availableDevices()
            )
            : ""
        let redirectedDirectoryPath = channelOptions.redirectedDirectoryPath
        let gateway = channelOptions.gateway
        let remoteApp = channelOptions.remoteApp
        let configureResult = certificateStorePath.withCString { storePath in
            endpoint.host.withCString { host in
                endpoint.username.withCString { username in
                    endpoint.domain.withCString { domain in
                        password.withCString { passwordCString in
                            microphoneDeviceName.withCString { microphoneDeviceNameCString in
                                let configureWithGatewayPassword: (
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UInt16,
                                    Bool,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?
                                ) -> FFRResult = { directoryPath, gatewayHost, gatewayPort, gatewayUseSameCredentials, gatewayUsername, gatewayDomain, gatewayPassword, remoteAppProgram, remoteAppArguments, remoteAppWorkingDirectory in
                                    var settings = FFRConnectionSettings(
                                        hostname: host,
                                        port: endpointPort,
                                        username: username,
                                        domain: domain,
                                        password: passwordCString,
                                        certificateStorePath: storePath,
                                        dynamicResolution: dynamicResolution,
                                        clipboardText: clipboardText,
                                        audioPlayback: audioPlayback,
                                        microphoneRedirection: microphoneRedirection,
                                        microphoneDeviceName: microphoneDeviceName.isEmpty
                                            ? nil
                                            : microphoneDeviceNameCString,
                                        redirectedDirectoryPath: directoryPath,
                                        gatewayHostname: gatewayHost,
                                        gatewayPort: gatewayPort,
                                        gatewayUseSameCredentials: gatewayUseSameCredentials,
                                        gatewayUsername: gatewayUsername,
                                        gatewayDomain: gatewayDomain,
                                        gatewayPassword: gatewayPassword,
                                        remoteAppProgram: remoteAppProgram,
                                        remoteAppArguments: remoteAppArguments,
                                        remoteAppWorkingDirectory: remoteAppWorkingDirectory
                                    )
                                    return FFRSessionConfigure(createdSession, &settings)
                                }
                                let configureWithRemoteApp: (
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?,
                                    UnsafePointer<CChar>?
                                ) -> FFRResult = { directoryPath, remoteAppProgram, remoteAppArguments, remoteAppWorkingDirectory in
                                    guard let gateway else {
                                        return configureWithGatewayPassword(
                                            directoryPath,
                                            nil,
                                            0,
                                            true,
                                            nil,
                                            nil,
                                            nil,
                                            remoteAppProgram,
                                            remoteAppArguments,
                                            remoteAppWorkingDirectory
                                        )
                                    }
                                    return gateway.host.withCString { gatewayHost in
                                        gateway.username.withCString { gatewayUsername in
                                            gateway.domain.withCString { gatewayDomain in
                                                configureWithGatewayPassword(
                                                    directoryPath,
                                                    gatewayHost,
                                                    gateway.port,
                                                    gateway.useSameCredentials,
                                                    gatewayUsername,
                                                    gatewayDomain,
                                                    passwordCString,
                                                    remoteAppProgram,
                                                    remoteAppArguments,
                                                    remoteAppWorkingDirectory
                                                )
                                            }
                                        }
                                    }
                                }
                                let configureWithDirectory: (UnsafePointer<CChar>?) -> FFRResult = { directoryPath in
                                    guard let remoteApp else {
                                        return configureWithRemoteApp(directoryPath, nil, nil, nil)
                                    }
                                    return remoteApp.program.withCString { program in
                                        remoteApp.arguments.withCString { arguments in
                                            remoteApp.workingDirectory.withCString { workingDirectory in
                                                configureWithRemoteApp(
                                                    directoryPath,
                                                    program,
                                                    arguments,
                                                    workingDirectory
                                                )
                                            }
                                        }
                                    }
                                }
                                if let redirectedDirectoryPath {
                                    return redirectedDirectoryPath.withCString(configureWithDirectory)
                                }
                                return configureWithDirectory(nil)
                            }
                        }
                    }
                }
            }
        }

        if configureResult == FFR_RESULT_OK {
            let graphicsResult = FFRSessionSetGraphicsEventCallback(
                createdSession,
                graphicsEventCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            let clipboardResult = channelOptions.clipboardText
                ? FFRSessionSetClipboardEventCallback(
                    createdSession,
                    clipboardEventCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                : FFR_RESULT_OK
            if graphicsResult == FFR_RESULT_OK && clipboardResult == FFR_RESULT_OK {
                _ = FFRSessionConnect(createdSession)
            } else {
                let callbackResult = graphicsResult == FFR_RESULT_OK
                    ? clipboardResult
                    : graphicsResult
                return .failed(ConnectionFailure(
                    message: localizedBridgeResult(callbackResult),
                    nativeCode: 0
                ), connectedBeforeFailure: false)
            }
        } else {
            return .failed(ConnectionFailure(
                message: localizedBridgeResult(configureResult),
                nativeCode: 0
            ), connectedBeforeFailure: false)
        }

        lock.lock()
        let connectedBeforeFailure = connectionWasEstablished
        let failure = attemptFailure
        lock.unlock()

        if let failure {
            return .failed(failure, connectedBeforeFailure: connectedBeforeFailure)
        }
        return .disconnected
    }

    private func shouldRetry(
        failure: ConnectionFailure,
        connectedBeforeFailure: Bool,
        completedRetries: Int
    ) -> Bool {
        lock.lock()
        let cancelled = cancellationRequested
        lock.unlock()
        return !cancelled && reconnectPolicy.canRetry(
            failure: failure,
            afterConnected: connectedBeforeFailure,
            completedRetries: completedRetries
        )
    }

    private func waitBeforeReconnect(completedRetries: Int) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds +
            reconnectPolicy.delayNanoseconds(forCompletedRetries: completedRetries)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            lock.lock()
            let cancelled = cancellationRequested
            lock.unlock()
            if cancelled {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}

@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var certificateChallenge: CertificateChallenge?
    @Published private(set) var failure: ConnectionFailure?

    var onDesktopSizeChange: (@MainActor (RemoteDesktopSize) -> Void)?
    var onFrameUpdate: (@MainActor (
        RemoteDesktopSize,
        RemoteFrameRect,
        UnsafeRawBufferPointer,
        Int,
        UInt64
    ) -> Void)?
    var onCursorUpdate: (@MainActor (RemoteCursorUpdate) -> Void)?
    var onClipboardTextReceived: (@MainActor (String) -> Void)?
    var onDynamicResolutionReady: (@MainActor () -> Void)?
    var localClipboardTextProvider: (@MainActor () -> String?)?

    private var stateMachine = SessionStateMachine()
    private var worker: ConnectionWorker?
    private var displayControlReady = false

    var isActive: Bool {
        switch phase {
        case .resolving, .connecting, .authenticating, .connected, .reconnecting, .disconnecting:
            true
        case .idle, .disconnected, .failed:
            false
        }
    }

    func connect(
        endpoint: ConnectionEndpoint,
        password: String,
        channelOptions: ConnectionChannelOptions = .defaults,
        reconnectPolicy: ConnectionReconnectPolicy = .disabled
    ) {
        guard password.utf8.count <= 4096 else {
            failure = ConnectionFailure(
                message: String(localized: "密码长度超过支持的限制。"),
                nativeCode: 0
            )
            phase = .failed
            return
        }

        let id = UUID()
        guard stateMachine.begin(sessionID: id) else {
            return
        }

        phase = stateMachine.phase
        certificateChallenge = nil
        failure = nil
        displayControlReady = false

        let worker = ConnectionWorker(
            id: id,
            endpoint: endpoint,
            channelOptions: channelOptions,
            reconnectPolicy: reconnectPolicy,
            password: password
        ) { [weak self] id, event in
            Task { @MainActor [weak self] in
                self?.handle(id: id, event: event)
            }
        }
        self.worker = worker
        worker.start()
    }

    func cancel() {
        guard let id = stateMachine.sessionID, isActive else {
            return
        }
        if phase != .disconnecting {
            _ = stateMachine.transition(sessionID: id, to: .disconnecting)
            phase = stateMachine.phase
        }
        certificateChallenge = nil
        worker?.releaseAllInput()
        worker?.requestCancellation()
    }

    func resolveCertificate(_ decision: FFRCertificateDecision) {
        certificateChallenge = nil
        worker?.resolveCertificate(decision)
    }

    func sendInput(_ command: RemoteInputCommand) {
        guard phase == .connected else { return }
        worker?.sendInput(command)
    }

    func requestResize(_ size: RemoteDesktopSize) {
        guard phase == .connected else { return }
        FarframeLog.logger(for: .session).info(
            "Requesting remote desktop size \(size.width, privacy: .public)x\(size.height, privacy: .public)"
        )
        worker?.sendInput(.resize(size))
    }

    func requestMonitorLayout(_ layouts: [RemoteMonitorLayout]) {
        guard phase == .connected, !layouts.isEmpty else { return }
        FarframeLog.logger(for: .session).info(
            "Requesting remote monitor layout count=\(layouts.count, privacy: .public)"
        )
        worker?.sendInput(.monitorLayout(layouts))
    }

    func publishClipboardText(_ text: String?) {
        guard phase == .connected else { return }
        worker?.publishClipboardText(text)
    }

    private func handle(id: UUID, event: ConnectionWorkerEvent) {
        guard stateMachine.sessionID == id else {
            return
        }

        switch event {
        case let .phase(next):
            transition(id: id, to: next)
            if next == .connected, displayControlReady {
                onDynamicResolutionReady?()
            }
        case let .certificate(challenge):
            if phase == .connecting {
                transition(id: id, to: .authenticating)
            }
            certificateChallenge = challenge
        case let .desktopSize(size):
            FarframeLog.logger(for: .session).info(
                "Remote desktop reported size \(size.width, privacy: .public)x\(size.height, privacy: .public)"
            )
            onDesktopSizeChange?(size)
        case .frameAvailable:
            worker?.consumePendingFrame { size, rect, pixels, bytesPerRow, sequenceNumber in
                onFrameUpdate?(size, rect, pixels, bytesPerRow, sequenceNumber)
            }
        case let .cursor(update):
            onCursorUpdate?(update)
        case .clipboardReady:
            worker?.publishClipboardText(localClipboardTextProvider?())
        case let .clipboardText(text):
            onClipboardTextReceived?(text)
        case .displayControlReady:
            displayControlReady = true
            FarframeLog.logger(for: .session).info(
                "Display-control channel is ready; connected=\(self.phase == .connected, privacy: .public)"
            )
            if phase == .connected {
                onDynamicResolutionReady?()
            }
        case let .failed(failure):
            self.failure = failure
            transition(id: id, to: .failed)
        case .finished:
            worker = nil
            certificateChallenge = nil
            displayControlReady = false
            if stateMachine.finish(sessionID: id) {
                phase = stateMachine.phase
            }
        }
    }

    private func transition(id: UUID, to next: SessionPhase) {
        if next == phase {
            return
        }
        if next == .disconnected && phase != .disconnecting {
            _ = stateMachine.transition(sessionID: id, to: .disconnecting)
        }
        if next == .authenticating && phase == .resolving {
            _ = stateMachine.transition(sessionID: id, to: .connecting)
        }
        if stateMachine.transition(sessionID: id, to: next) {
            phase = stateMachine.phase
        }
    }
}
