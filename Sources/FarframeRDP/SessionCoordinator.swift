import FarframeCore
import FarframeRDPBridge
import Darwin
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

enum SessionCertificateStore {
    static func prepare(sessionID: UUID, fileManager: FileManager = .default) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("FarframeRDP-CertificateChecks", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var status = stat()
        guard lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & S_IFMT != S_IFLNK,
              chmod(directory.path, 0o700) == 0 else {
            try? fileManager.removeItem(at: directory)
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }

    static func remove(_ directory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
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
    case clipboardOffer(UInt64, [RemoteClipboardFormat])
    case clipboardData(UInt64, ClipboardContentKind, Data?)
    case clipboardFileApprovalRequested(ClipboardFileTransferApproval)
    case clipboardFilesReady(UInt64, [URL])
    case clipboardFilesFailed(UInt64)
    case clipboardTransferProgress(UInt64?, ClipboardTransferProgress?)
    case displayControlReady
    case failed(ConnectionFailure)
    case finished
}

enum ClipboardContentKind: Int, Hashable, Sendable {
    case unicodeText = 1
    case html = 2
    case rtf = 3
    case dib = 4
    case dibV5 = 5
    case fileList = 6
    case png = 7
}

struct RemoteClipboardFormat: Equatable, Sendable {
    let kind: ClipboardContentKind
    let formatID: UInt32
}

private struct LocalClipboardFileRequest: Sendable {
    let requestID: UInt64
    let generation: UInt64
    let listIndex: UInt32
    let kind: FFRClipboardFileRequestKind
    let offset: UInt64
    let requestedBytes: UInt32
}

enum ClipboardFileTransferDirection: Equatable, Sendable {
    case macToWindows
    case windowsToMac
}

struct ClipboardFileTransferApproval: Sendable {
    let direction: ClipboardFileTransferDirection
    let fileCount: Int
    let totalBytes: UInt64
    let fileNames: [String]

    init(
        direction: ClipboardFileTransferDirection,
        fileCount: Int,
        totalBytes: UInt64,
        fileNames: [String] = []
    ) {
        self.direction = direction
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.fileNames = fileNames
    }
}

enum ClipboardDirectSaveDestination: Equatable, Sendable {
    case file(URL)
    case directory(URL)
}

enum ClipboardFileTransferConfirmationDecision: Equatable, Sendable {
    case cancel
    case confirmCopy(suppressFurtherPrompts: Bool)
    case directSave(ClipboardDirectSaveDestination, suppressFurtherPrompts: Bool)

    var approved: Bool {
        switch self {
        case .cancel:
            false
        case .confirmCopy, .directSave:
            true
        }
    }

    var suppressesFurtherPrompts: Bool {
        switch self {
        case .cancel:
            false
        case let .confirmCopy(suppress), let .directSave(_, suppress):
            suppress
        }
    }
}

struct RemoteClipboardFileConfirmationPolicy: Equatable, Sendable {
    private(set) var suppressForSession = false

    func requiresApproval(profileRequiresApproval: Bool) -> Bool {
        profileRequiresApproval && !suppressForSession
    }

    mutating func record(_ decision: ClipboardFileTransferConfirmationDecision) {
        if decision.approved, decision.suppressesFurtherPrompts {
            suppressForSession = true
        }
    }

    mutating func reset() {
        suppressForSession = false
    }
}

struct RemoteClipboardFileTransferGate: Equatable, Sendable {
    private(set) var approvalResolved: Bool
    private(set) var approved: Bool
    private(set) var transferRequested = false

    init(requiresApproval: Bool) {
        approvalResolved = !requiresApproval
        approved = !requiresApproval
    }

    mutating func resolveApproval(_ approved: Bool) -> Bool {
        guard !approvalResolved else { return false }
        approvalResolved = true
        self.approved = approved
        return true
    }

    mutating func beginTransfer() -> Bool {
        guard approvalResolved, approved, !transferRequested else { return false }
        transferRequested = true
        return true
    }
}

struct ClipboardTransferProgress: Equatable, Sendable {
    let direction: ClipboardFileTransferDirection
    let fileCount: Int
    let completedBytes: UInt64
    let totalBytes: UInt64
    let failed: Bool
}

private final class RemoteClipboardDownloadState: @unchecked Sendable {
    let generation: UInt64
    let files: [ClipboardRemoteFileDescriptor]
    let directory: URL
    let clipboardLocked: Bool
    var completedURLs: [URL] = []
    var fileIndex = 0
    var offset: UInt64 = 0
    var descriptor: Int32 = -1
    var pendingStreamID: UInt32 = 0
    var pendingKind = FFR_CLIPBOARD_FILE_REQUEST_SIZE

    init(
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        directory: URL,
        clipboardLocked: Bool
    ) {
        self.generation = generation
        self.files = files
        self.directory = directory
        self.clipboardLocked = clipboardLocked
    }
}

struct ConnectionChannelOptions: Equatable, Sendable {
    var dynamicResolution: Bool
    var monitorSelection: RemoteMonitorSelection
    var clipboardEnabled: Bool
    var clipboardText: Bool
    var clipboardFormattedText: Bool
    var clipboardImages: Bool
    var clipboardFiles: Bool
    var clipboardDirection: ClipboardTransferDirection
    var confirmClipboardFiles: Bool
    var audioPlayback: Bool
    var microphoneRedirection: Bool
    var microphoneDeviceName: String
    var redirectedDirectoryPath: String?
    var gateway: ConnectionGatewayOptions?
    var remoteApp: ConnectionRemoteAppOptions?

    static let defaults = ConnectionChannelOptions(
        dynamicResolution: true,
        monitorSelection: .window,
        clipboardEnabled: true,
        clipboardText: true,
        clipboardFormattedText: false,
        clipboardImages: false,
        clipboardFiles: false,
        clipboardDirection: .bidirectional,
        confirmClipboardFiles: true,
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
    private var localClipboardGeneration: UInt64 = 0
    private var localClipboardFiles: [ClipboardLocalFileSnapshot] = []
    private var localFileTransferApproved = false
    private var localFileTransferCancelled = false
    private var localFileApprovalRequested = false
    private var localFileProgressStarted = false
    private var localFileApprovalResetToken: UInt64 = 0
    private var pendingLocalFileRequests: [LocalClipboardFileRequest] = []
    private var localFileCompletedBytes: [UInt64] = []
    private let clipboardFileQueue = DispatchQueue(label: "com.farframe.rdp.clipboard-files")
    private var remoteDownload: RemoteClipboardDownloadState?
    private var nextRemoteFileStreamID: UInt32 = 0

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
        self.localFileTransferApproved = !channelOptions.confirmClipboardFiles
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

    func publishClipboardContent(_ content: ClipboardPayloadSet) {
        guard channelOptions.clipboardEnabled,
              channelOptions.clipboardDirection.allowsLocalToRemote else { return }
        lock.lock()
        guard let current = session else {
            lock.unlock()
            return
        }
        localClipboardGeneration &+= 1
        if localClipboardGeneration == 0 {
            localClipboardGeneration = 1
        }
        let generation = localClipboardGeneration
        let selected = content.representations
            .filter { kind, _ in
                switch kind {
                case .unicodeText:
                    channelOptions.clipboardText
                case .html, .rtf:
                    channelOptions.clipboardFormattedText
                case .dib, .dibV5, .png:
                    channelOptions.clipboardImages
                case .fileList:
                    channelOptions.clipboardFiles
                }
            }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        localClipboardFiles = selected.contains(where: { $0.key == .fileList })
            ? content.localFiles : []
        localFileTransferApproved = !channelOptions.confirmClipboardFiles
        localFileTransferCancelled = false
        localFileApprovalRequested = false
        localFileProgressStarted = false
        localFileApprovalResetToken &+= 1
        for request in pendingLocalFileRequests {
            respondToLocalFileRequest(request, data: nil, session: current)
        }
        pendingLocalFileRequests.removeAll()
        localFileCompletedBytes = Array(repeating: 0, count: localClipboardFiles.count)
        guard !selected.isEmpty else {
            _ = FFRSessionPublishClipboardOffer(current, generation, nil, 0)
            lock.unlock()
            return
        }
        var allocations: [UnsafeMutablePointer<UInt8>] = []
        var payloads: [FFRClipboardPayload] = []
        for (kind, data) in selected where !data.isEmpty {
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: storage, count: data.count)
            allocations.append(storage)
            payloads.append(FFRClipboardPayload(
                kind: FFRClipboardFormatKind(rawValue: UInt32(kind.rawValue)),
                bytes: UnsafePointer(storage),
                length: data.count
            ))
        }
        if payloads.isEmpty {
            _ = FFRSessionPublishClipboardOffer(current, generation, nil, 0)
        } else {
            payloads.withUnsafeBufferPointer { buffer in
                _ = FFRSessionPublishClipboardOffer(
                    current,
                    generation,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        for allocation in allocations { allocation.deallocate() }
        lock.unlock()
    }

    func requestClipboardData(generation: UInt64, format: RemoteClipboardFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = session else { return }
        _ = FFRSessionRequestClipboardData(
            current,
            generation,
            format.formatID,
            FFRClipboardFormatKind(rawValue: UInt32(format.kind.rawValue))
        )
    }

    func beginRemoteFileDownload(
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        destinationDirectory: URL,
        clipboardLocked: Bool = false
    ) {
        clipboardFileQueue.async { [weak self] in
            self?.startRemoteFileDownload(
                generation: generation,
                files: files,
                destinationDirectory: destinationDirectory,
                clipboardLocked: clipboardLocked
            )
        }
    }

    func lockRemoteClipboard(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = session else { return false }
        return FFRSessionLockRemoteClipboard(current, generation) == FFR_RESULT_OK
    }

    private func unlockRemoteClipboard(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = session else { return }
        _ = FFRSessionUnlockRemoteClipboard(current, generation)
    }

    func cancelRemoteFileDownload() {
        clipboardFileQueue.async { [weak self] in
            self?.finishRemoteFileDownload(success: false, cancelled: true)
        }
    }

    func cancelClipboardFileTransfer() {
        lock.lock()
        localFileTransferCancelled = true
        let pending = pendingLocalFileRequests
        pendingLocalFileRequests.removeAll()
        localFileApprovalRequested = false
        lock.unlock()
        for request in pending {
            respondToLocalFileRequest(request, data: nil)
        }
        cancelRemoteFileDownload()
        handler(id, .clipboardTransferProgress(nil, nil))
    }

    private func cancelRemoteFileDownloadSynchronously() {
        clipboardFileQueue.sync {
            finishRemoteFileDownload(success: false, cancelled: true)
        }
    }

    private func startRemoteFileDownload(
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        destinationDirectory: URL,
        clipboardLocked: Bool
    ) {
        finishRemoteFileDownload(success: false, cancelled: true)
        guard !files.isEmpty,
              files.count <= ClipboardFilePolicy.maximumFileCount else { return }
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarframeRDP-Clipboard", isDirectory: true)
        do {
            try prepareClipboardCacheRoot(root)
            cleanStaleClipboardDirectories(in: root)
            let fileSystem = try FileManager.default.attributesOfFileSystem(forPath: root.path)
            let freeBytes = (fileSystem[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            guard freeBytes > totalBytes + 256 * 1024 * 1024 else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let directory = destinationDirectory.standardizedFileURL
            try validateRemoteFilePlaceholderDirectory(
                directory,
                root: root.standardizedFileURL,
                files: files
            )
            remoteDownload = RemoteClipboardDownloadState(
                generation: generation,
                files: files,
                directory: directory,
                clipboardLocked: clipboardLocked
            )
            publishRemoteFileProgress(failed: false)
            requestCurrentRemoteFileSize()
        } catch {
            if destinationDirectory.standardizedFileURL.deletingLastPathComponent() ==
                root.standardizedFileURL {
                try? FileManager.default.removeItem(at: destinationDirectory)
            }
            if clipboardLocked {
                unlockRemoteClipboard(generation: generation)
            }
            handler(id, .clipboardFilesFailed(generation))
            handler(id, .clipboardTransferProgress(generation, ClipboardTransferProgress(
                direction: .windowsToMac,
                fileCount: files.count,
                completedBytes: 0,
                totalBytes: totalBytes,
                failed: true
            )))
        }
    }

    private func prepareClipboardCacheRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        guard lstat(root.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & S_IFMT != S_IFLNK else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard chmod(root.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func validateRemoteFilePlaceholderDirectory(
        _ directory: URL,
        root: URL,
        files: [ClipboardRemoteFileDescriptor]
    ) throws {
        guard directory.isFileURL,
              directory.deletingLastPathComponent() == root else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_mode & S_IFMT != S_IFLNK else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for file in files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_mode & S_IFMT != S_IFLNK,
                  status.st_nlink == 1,
                  status.st_size == off_t(file.size) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
    }

    private func requestCurrentRemoteFileSize() {
        guard let download = remoteDownload, download.fileIndex < download.files.count else {
            finishRemoteFileDownload(success: true, cancelled: false)
            return
        }
        nextRemoteFileStreamID &+= 1
        if nextRemoteFileStreamID == 0 { nextRemoteFileStreamID = 1 }
        download.pendingStreamID = nextRemoteFileStreamID
        download.pendingKind = FFR_CLIPBOARD_FILE_REQUEST_SIZE
        guard requestRemoteFileContents(
            generation: download.generation,
            streamID: nextRemoteFileStreamID,
            listIndex: UInt32(download.fileIndex),
            kind: FFR_CLIPBOARD_FILE_REQUEST_SIZE,
            offset: 0,
            requestedBytes: 0
        ) else {
            finishRemoteFileDownload(success: false, cancelled: false)
            return
        }
        scheduleRemoteFileTimeout(generation: download.generation, streamID: nextRemoteFileStreamID)
    }

    private func requestCurrentRemoteFileRange() {
        guard let download = remoteDownload else { return }
        let file = download.files[download.fileIndex]
        guard download.offset < file.size else {
            completeCurrentRemoteFile()
            return
        }
        let count = UInt32(min(UInt64(1024 * 1024), file.size - download.offset))
        nextRemoteFileStreamID &+= 1
        if nextRemoteFileStreamID == 0 { nextRemoteFileStreamID = 1 }
        download.pendingStreamID = nextRemoteFileStreamID
        download.pendingKind = FFR_CLIPBOARD_FILE_REQUEST_RANGE
        guard requestRemoteFileContents(
            generation: download.generation,
            streamID: nextRemoteFileStreamID,
            listIndex: UInt32(download.fileIndex),
            kind: FFR_CLIPBOARD_FILE_REQUEST_RANGE,
            offset: download.offset,
            requestedBytes: count
        ) else {
            finishRemoteFileDownload(success: false, cancelled: false)
            return
        }
        scheduleRemoteFileTimeout(generation: download.generation, streamID: nextRemoteFileStreamID)
    }

    private func scheduleRemoteFileTimeout(generation: UInt64, streamID: UInt32) {
        clipboardFileQueue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self,
                  let download = self.remoteDownload,
                  download.generation == generation,
                  download.pendingStreamID == streamID else { return }
            self.finishRemoteFileDownload(success: false, cancelled: false)
        }
    }

    private func requestRemoteFileContents(
        generation: UInt64,
        streamID: UInt32,
        listIndex: UInt32,
        kind: FFRClipboardFileRequestKind,
        offset: UInt64,
        requestedBytes: UInt32
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = session else { return false }
        return FFRSessionRequestRemoteFileContents(
            current,
            generation,
            streamID,
            listIndex,
            kind,
            offset,
            requestedBytes
        ) == FFR_RESULT_OK
    }

    private func receiveRemoteFileData(
        generation: UInt64,
        streamID: UInt32,
        success: Bool,
        data: Data
    ) {
        clipboardFileQueue.async { [weak self] in
            guard let self,
                  let download = self.remoteDownload,
                  download.generation == generation,
                  download.pendingStreamID == streamID,
                  success else {
                self?.finishRemoteFileDownload(success: false, cancelled: false)
                return
            }
            if download.pendingKind == FFR_CLIPBOARD_FILE_REQUEST_SIZE {
                guard data.count == 8 else {
                    self.finishRemoteFileDownload(success: false, cancelled: false)
                    return
                }
                let remoteSize = data.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << UInt64($1.offset * 8))
                }
                guard remoteSize == download.files[download.fileIndex].size,
                      self.openCurrentRemoteFile() else {
                    self.finishRemoteFileDownload(success: false, cancelled: false)
                    return
                }
                if remoteSize == 0 {
                    self.completeCurrentRemoteFile()
                } else {
                    self.requestCurrentRemoteFileRange()
                }
                return
            }
            let file = download.files[download.fileIndex]
            let remaining = file.size - download.offset
            guard !data.isEmpty,
                  download.descriptor >= 0,
                  data.count <= 1024 * 1024,
                  UInt64(data.count) <= remaining else {
                self.finishRemoteFileDownload(success: false, cancelled: false)
                return
            }
            let wrote = data.withUnsafeBytes { bytes in
                pwrite(download.descriptor, bytes.baseAddress, bytes.count, off_t(download.offset))
            }
            guard wrote == data.count else {
                self.finishRemoteFileDownload(success: false, cancelled: false)
                return
            }
            download.offset += UInt64(data.count)
            self.publishRemoteFileProgress(failed: false)
            self.requestCurrentRemoteFileRange()
        }
    }

    private func openCurrentRemoteFile() -> Bool {
        guard let download = remoteDownload else { return false }
        let file = download.files[download.fileIndex]
        let url = download.directory.appendingPathComponent(file.name, isDirectory: false)
        let descriptor = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              ftruncate(descriptor, 0) == 0 else {
            close(descriptor)
            return false
        }
        download.descriptor = descriptor
        download.offset = 0
        download.completedURLs.append(url)
        return true
    }

    private func completeCurrentRemoteFile() {
        guard let download = remoteDownload else { return }
        if download.descriptor >= 0 {
            close(download.descriptor)
            download.descriptor = -1
        }
        let file = download.files[download.fileIndex]
        let url = download.completedURLs[download.fileIndex]
        if let date = file.modificationDate {
            try? FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }
        download.fileIndex += 1
        download.offset = 0
        requestCurrentRemoteFileSize()
    }

    private func publishRemoteFileProgress(failed: Bool) {
        guard let download = remoteDownload else { return }
        let completed = download.files.prefix(download.fileIndex).reduce(UInt64(0)) { $0 + $1.size }
            + download.offset
        handler(id, .clipboardTransferProgress(download.generation, ClipboardTransferProgress(
            direction: .windowsToMac,
            fileCount: download.files.count,
            completedBytes: completed,
            totalBytes: download.files.reduce(0) { $0 + $1.size },
            failed: failed
        )))
    }

    private func finishRemoteFileDownload(success: Bool, cancelled: Bool) {
        guard let download = remoteDownload else { return }
        remoteDownload = nil
        if download.clipboardLocked {
            unlockRemoteClipboard(generation: download.generation)
        }
        if download.descriptor >= 0 { close(download.descriptor) }
        if success {
            handler(id, .clipboardFilesReady(download.generation, download.completedURLs))
            handler(id, .clipboardTransferProgress(download.generation, nil))
        } else {
            try? FileManager.default.removeItem(at: download.directory)
            handler(id, .clipboardFilesFailed(download.generation))
            if !cancelled {
                handler(id, .clipboardTransferProgress(download.generation, ClipboardTransferProgress(
                    direction: .windowsToMac,
                    fileCount: download.files.count,
                    completedBytes: 0,
                    totalBytes: download.files.reduce(0) { $0 + $1.size },
                    failed: true
                )))
            } else {
                handler(id, .clipboardTransferProgress(download.generation, nil))
            }
        }
    }

    private func cleanStaleClipboardDirectories(in root: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let date, date < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    private func handleLocalFileRequest(_ request: LocalClipboardFileRequest) {
        lock.lock()
        if localFileTransferCancelled {
            lock.unlock()
            respondToLocalFileRequest(request, data: nil)
            return
        }
        if !localFileTransferApproved {
            pendingLocalFileRequests.append(request)
            let shouldRequestApproval = !localFileApprovalRequested
            localFileApprovalRequested = true
            let approval = ClipboardFileTransferApproval(
                direction: .macToWindows,
                fileCount: localClipboardFiles.count,
                totalBytes: localClipboardFiles.reduce(0) { $0 + $1.size }
            )
            lock.unlock()
            if shouldRequestApproval { handler(id, .clipboardFileApprovalRequested(approval)) }
            return
        }
        localFileApprovalResetToken &+= 1
        lock.unlock()
        performLocalFileRequest(request)
    }

    func resolveLocalFileTransferApproval(_ approved: Bool) {
        lock.lock()
        localFileTransferApproved = approved && !localFileTransferCancelled
        let shouldTransfer = localFileTransferApproved
        localFileApprovalRequested = false
        let requests = pendingLocalFileRequests
        pendingLocalFileRequests.removeAll()
        lock.unlock()
        for request in requests {
            if shouldTransfer {
                performLocalFileRequest(request)
            } else {
                respondToLocalFileRequest(request, data: nil)
            }
        }
    }

    private func performLocalFileRequest(_ request: LocalClipboardFileRequest) {
        publishLocalFileProgressIfNeeded(generation: request.generation)
        clipboardFileQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.session
            let file = !self.localFileTransferCancelled &&
                request.generation == self.localClipboardGeneration &&
                Int(request.listIndex) < self.localClipboardFiles.count
                ? self.localClipboardFiles[Int(request.listIndex)] : nil
            self.lock.unlock()
            guard let current else { return }
            guard let file else {
                self.respondToLocalFileRequest(request, data: nil, session: current)
                return
            }
            guard let data = self.readLocalFile(file, request: request) else {
                self.respondToLocalFileRequest(request, data: nil, session: current)
                return
            }
            self.respondToLocalFileRequest(request, data: data, session: current)
            if request.kind == FFR_CLIPBOARD_FILE_REQUEST_RANGE {
                self.publishLocalFileProgress(request: request, deliveredBytes: data.count)
            } else if request.kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE {
                self.finishZeroByteLocalFileTransferIfNeeded(generation: request.generation)
            }
        }
    }

    private func finishZeroByteLocalFileTransferIfNeeded(generation: UInt64) {
        lock.lock()
        let isEmptyTransfer = generation == localClipboardGeneration &&
            !localClipboardFiles.isEmpty &&
            localClipboardFiles.allSatisfy { $0.size == 0 }
        lock.unlock()
        if isEmptyTransfer {
            finishLocalFileTransferIfNeeded(generation: generation)
            handler(id, .clipboardTransferProgress(nil, nil))
        }
    }

    private func publishLocalFileProgressIfNeeded(generation: UInt64) {
        lock.lock()
        guard generation == localClipboardGeneration,
              !localFileProgressStarted,
              !localClipboardFiles.isEmpty else {
            lock.unlock()
            return
        }
        localFileProgressStarted = true
        let fileCount = localClipboardFiles.count
        let total = localClipboardFiles.reduce(UInt64(0)) { $0 + $1.size }
        lock.unlock()
        handler(id, .clipboardTransferProgress(nil, ClipboardTransferProgress(
            direction: .macToWindows,
            fileCount: fileCount,
            completedBytes: 0,
            totalBytes: total,
            failed: false
        )))
    }

    private func publishLocalFileProgress(
        request: LocalClipboardFileRequest,
        deliveredBytes: Int
    ) {
        lock.lock()
        guard request.generation == localClipboardGeneration,
              Int(request.listIndex) < localClipboardFiles.count,
              Int(request.listIndex) < localFileCompletedBytes.count else {
            lock.unlock()
            return
        }
        let end = min(
            localClipboardFiles[Int(request.listIndex)].size,
            request.offset + UInt64(deliveredBytes)
        )
        localFileCompletedBytes[Int(request.listIndex)] = max(
            localFileCompletedBytes[Int(request.listIndex)],
            end
        )
        let completed = localFileCompletedBytes.reduce(0, +)
        let total = localClipboardFiles.reduce(UInt64(0)) { $0 + $1.size }
        let fileCount = localClipboardFiles.count
        lock.unlock()
        if completed >= total {
            finishLocalFileTransferIfNeeded(generation: request.generation)
        }
        handler(id, completed >= total
            ? .clipboardTransferProgress(nil, nil)
            : .clipboardTransferProgress(nil, ClipboardTransferProgress(
                direction: .macToWindows,
                fileCount: fileCount,
                completedBytes: completed,
                totalBytes: total,
                failed: false
            )))
    }

    private func finishLocalFileTransferIfNeeded(generation: UInt64) {
        guard channelOptions.confirmClipboardFiles else { return }
        lock.lock()
        localFileApprovalResetToken &+= 1
        let token = localFileApprovalResetToken
        lock.unlock()
        clipboardFileQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.localFileApprovalResetToken == token,
                  self.localClipboardGeneration == generation else {
                self.lock.unlock()
                return
            }
            self.localFileTransferApproved = false
            self.localFileProgressStarted = false
            self.localFileCompletedBytes = Array(
                repeating: 0,
                count: self.localClipboardFiles.count
            )
            self.lock.unlock()
        }
    }

    private func respondToLocalFileRequest(
        _ request: LocalClipboardFileRequest,
        data: Data?,
        session suppliedSession: OpaquePointer? = nil
    ) {
        let respond: (OpaquePointer) -> Void = { current in
            guard let data else {
                _ = FFRSessionRespondLocalFileRequest(
                    current,
                    request.requestID,
                    false,
                    nil,
                    0
                )
                return
            }
            data.withUnsafeBytes { bytes in
                _ = FFRSessionRespondLocalFileRequest(
                    current,
                    request.requestID,
                    true,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
        }
        if let suppliedSession {
            respond(suppliedSession)
            return
        }
        lock.lock()
        if let current = session { respond(current) }
        lock.unlock()
    }

    private func readLocalFile(
        _ file: ClipboardLocalFileSnapshot,
        request: LocalClipboardFileRequest
    ) -> Data? {
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              UInt64(status.st_dev) == file.deviceID,
              UInt64(status.st_ino) == file.inode,
              UInt64(status.st_size) == file.size else {
            return nil
        }
        if request.kind == FFR_CLIPBOARD_FILE_REQUEST_SIZE {
            var size = file.size.littleEndian
            return withUnsafeBytes(of: &size) { Data($0) }
        }
        guard request.kind == FFR_CLIPBOARD_FILE_REQUEST_RANGE,
              request.offset <= file.size else { return nil }
        let remaining = file.size - request.offset
        let count = min(UInt64(request.requestedBytes), remaining)
        guard let offset = off_t(exactly: request.offset),
              let byteCount = Int(exactly: count) else { return nil }
        var data = Data(count: byteCount)
        let readCount = data.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, byteCount, offset)
        }
        guard readCount >= 0, readCount == byteCount else { return nil }
        return data
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
        case FFR_CLIPBOARD_EVENT_REMOTE_OFFER:
            guard let baseAddress = event.formats,
                  let count = Int(exactly: event.formatCount),
                  count <= 16 else {
                return
            }
            let formats: [RemoteClipboardFormat] = UnsafeBufferPointer(
                start: baseAddress,
                count: count
            ).compactMap { value -> RemoteClipboardFormat? in
                guard let kind = ClipboardContentKind(rawValue: Int(value.kind.rawValue)) else {
                    return nil
                }
                return RemoteClipboardFormat(kind: kind, formatID: value.formatId)
            }
            handler(id, .clipboardOffer(event.generation, formats))
        case FFR_CLIPBOARD_EVENT_REMOTE_DATA:
            guard let kind = ClipboardContentKind(rawValue: Int(event.format.rawValue)),
                  let length = Int(exactly: event.length) else {
                return
            }
            let data = event.bytes.map { Data(bytes: $0, count: length) }
            handler(id, .clipboardData(event.generation, kind, data))
        case FFR_CLIPBOARD_EVENT_LOCAL_FILE_REQUEST:
            handleLocalFileRequest(LocalClipboardFileRequest(
                requestID: event.fileRequestId,
                generation: event.generation,
                listIndex: event.listIndex,
                kind: event.fileRequestKind,
                offset: event.fileOffset,
                requestedBytes: event.requestedBytes
            ))
        case FFR_CLIPBOARD_EVENT_REMOTE_FILE_DATA:
            let data = event.bytes.map { Data(bytes: $0, count: event.length) } ?? Data()
            receiveRemoteFileData(
                generation: event.generation,
                streamID: event.streamId,
                success: event.success,
                data: data
            )
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
            // Drain queued file I/O before destroying the session. This prevents a
            // stale range task from targeting a replacement session after reconnect.
            cancelRemoteFileDownloadSynchronously()
            lock.lock()
            session = nil
            lock.unlock()
            _ = FFRSessionDestroy(&ownedSession)
        }

        let certificateStoreDirectory: URL
        do {
            certificateStoreDirectory = try SessionCertificateStore.prepare(sessionID: id)
        } catch {
            return .failed(ConnectionFailure(
                message: String(localized: "无法准备安全的证书检查目录。"),
                nativeCode: 0
            ), connectedBeforeFailure: false)
        }
        defer {
            SessionCertificateStore.remove(certificateStoreDirectory)
        }
        let certificateStorePath = certificateStoreDirectory.path
        let endpointPort = endpoint.port
        let dynamicResolution = channelOptions.dynamicResolution
        let clipboardEnabled = channelOptions.clipboardEnabled
        let clipboardText = clipboardEnabled && channelOptions.clipboardText
        let clipboardFormattedText = clipboardEnabled && channelOptions.clipboardFormattedText
        let clipboardImages = clipboardEnabled && channelOptions.clipboardImages
        let clipboardFiles = clipboardEnabled && channelOptions.clipboardFiles
        let clipboardLocalToRemote = clipboardEnabled &&
            channelOptions.clipboardDirection.allowsLocalToRemote
        let clipboardRemoteToLocal = clipboardEnabled &&
            channelOptions.clipboardDirection.allowsRemoteToLocal
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
                                        clipboardFormattedText: clipboardFormattedText,
                                        clipboardImages: clipboardImages,
                                        clipboardFiles: clipboardFiles,
                                        clipboardLocalToRemote: clipboardLocalToRemote,
                                        clipboardRemoteToLocal: clipboardRemoteToLocal,
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
            let clipboardResult = channelOptions.clipboardEnabled
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
    @Published private(set) var clipboardTransferProgress: ClipboardTransferProgress?

    var onDesktopSizeChange: (@MainActor (RemoteDesktopSize) -> Void)?
    var onFrameUpdate: (@MainActor (
        RemoteDesktopSize,
        RemoteFrameRect,
        UnsafeRawBufferPointer,
        Int,
        UInt64
    ) -> Void)?
    var onCursorUpdate: (@MainActor (RemoteCursorUpdate) -> Void)?
    var onClipboardContentReceived: (@MainActor (ClipboardPayloadSet) -> Void)?
    var onClipboardFilesOffered: (@MainActor (
        UInt64,
        [ClipboardRemoteFileDescriptor]
    ) -> Void)?
    var onClipboardFilesDirectSaveRequested: (@MainActor (
        UInt64,
        [ClipboardRemoteFileDescriptor],
        ClipboardDirectSaveDestination
    ) -> Void)?
    var onClipboardFilesReceived: (@MainActor (UInt64, [URL]) -> Void)?
    var onClipboardFilesFailed: (@MainActor (UInt64) -> Void)?
    var onClipboardFileTransferConfirmation: (@MainActor (
        ClipboardFileTransferApproval,
        @escaping @MainActor (ClipboardFileTransferConfirmationDecision) -> Void
    ) -> Void)?
    var onClipboardFileTransferConfirmationCancellation: (@MainActor () -> Void)?
    var onDynamicResolutionReady: (@MainActor () -> Void)?
    var localClipboardContentProvider: (@MainActor () -> ClipboardPayloadSet)?

    private var stateMachine = SessionStateMachine()
    private var worker: ConnectionWorker?
    private var displayControlReady = false
    private var remoteClipboardGeneration: UInt64 = 0
    private var activeChannelOptions: ConnectionChannelOptions = .defaults
    private var pendingRemoteClipboard: (
        generation: UInt64,
        remaining: [RemoteClipboardFormat],
        payloads: ClipboardPayloadSet
    )?
    private var clipboardDataRequestToken: UInt64 = 0
    private var completedRemoteFileGeneration: UInt64?
    private var remoteFileConfirmationPolicy = RemoteClipboardFileConfirmationPolicy()
    private var pendingRemoteFiles: (
        generation: UInt64,
        files: [ClipboardRemoteFileDescriptor],
        gate: RemoteClipboardFileTransferGate
    )?

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
        remoteClipboardGeneration = 0
        activeChannelOptions = channelOptions
        pendingRemoteClipboard = nil
        pendingRemoteFiles = nil
        remoteFileConfirmationPolicy.reset()
        completedRemoteFileGeneration = nil
        clipboardDataRequestToken &+= 1
        clipboardTransferProgress = nil

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
        onClipboardFileTransferConfirmationCancellation?()
        pendingRemoteFiles = nil
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

    func publishClipboardContent(_ content: ClipboardPayloadSet) {
        guard phase == .connected else { return }
        worker?.publishClipboardContent(content)
    }

    func cancelClipboardFileTransfer() {
        worker?.cancelClipboardFileTransfer()
        clipboardTransferProgress = nil
    }

    func requestRemoteClipboardFiles(generation: UInt64, destinationDirectory: URL) {
        guard var pending = pendingRemoteFiles,
              pending.generation == generation,
              pending.gate.beginTransfer(),
              generation == remoteClipboardGeneration else { return }
        pendingRemoteFiles = pending
        let clipboardLocked = worker?.lockRemoteClipboard(generation: generation) == true
        if !clipboardLocked {
            FarframeLog.logger(for: .channel).info(
                "Remote clipboard lock unavailable; using current-generation file transfer fallback"
            )
        }
        worker?.beginRemoteFileDownload(
            generation: generation,
            files: pending.files,
            destinationDirectory: destinationDirectory,
            clipboardLocked: clipboardLocked
        )
    }

    func cancelRemoteClipboardFiles(generation: UInt64) {
        guard pendingRemoteFiles?.generation == generation else { return }
        pendingRemoteFiles = nil
        worker?.cancelRemoteFileDownload()
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
            guard activeChannelOptions.clipboardDirection.allowsLocalToRemote else { break }
            worker?.publishClipboardContent(localClipboardContentProvider?() ?? ClipboardPayloadSet())
        case let .clipboardText(text):
            // Kept for ABI compatibility. The generic data event owns delivery.
            _ = text
        case let .clipboardOffer(generation, formats):
            FarframeLog.logger(for: .channel).info(
                "Remote clipboard offer generation=\(generation, privacy: .public) recognizedFormats=\(formats.count, privacy: .public) kinds=\(formats.map { $0.kind.rawValue.description }.joined(separator: ","), privacy: .public)"
            )
            let invalidatedGeneration = remoteClipboardGeneration
            if pendingRemoteFiles != nil {
                onClipboardFileTransferConfirmationCancellation?()
            }
            if invalidatedGeneration != 0 {
                onClipboardFilesFailed?(invalidatedGeneration)
            }
            worker?.cancelRemoteFileDownload()
            clipboardDataRequestToken &+= 1
            remoteClipboardGeneration = generation
            pendingRemoteFiles = nil
            completedRemoteFileGeneration = nil
            guard activeChannelOptions.clipboardEnabled,
                  activeChannelOptions.clipboardDirection.allowsRemoteToLocal else {
                pendingRemoteClipboard = nil
                break
            }
            var selected: [RemoteClipboardFormat] = []
            if activeChannelOptions.clipboardText,
               let text = formats.first(where: { $0.kind == .unicodeText }) {
                selected.append(text)
            }
            if activeChannelOptions.clipboardFormattedText {
                if let html = formats.first(where: { $0.kind == .html }) { selected.append(html) }
                if let rtf = formats.first(where: { $0.kind == .rtf }) { selected.append(rtf) }
            }
            if activeChannelOptions.clipboardImages {
                if let image = formats.first(where: { $0.kind == .png }) ??
                    formats.first(where: { $0.kind == .dibV5 }) ??
                    formats.first(where: { $0.kind == .dib }) {
                    selected.append(image)
                }
            }
            if activeChannelOptions.clipboardFiles,
               let files = formats.first(where: { $0.kind == .fileList }) {
                selected.append(files)
            }
            pendingRemoteClipboard = (
                generation: generation,
                remaining: selected,
                payloads: ClipboardPayloadSet()
            )
            if let first = selected.first {
                worker?.requestClipboardData(generation: generation, format: first)
                scheduleClipboardDataTimeout(generation: generation, format: first)
            } else {
                pendingRemoteClipboard = nil
            }
        case let .clipboardData(generation, kind, data):
            FarframeLog.logger(for: .channel).info(
                "Remote clipboard data generation=\(generation, privacy: .public) kind=\(kind.rawValue, privacy: .public) accepted=\(data != nil, privacy: .public) bytes=\(data?.count ?? 0, privacy: .public)"
            )
            guard generation == remoteClipboardGeneration,
                  var pending = pendingRemoteClipboard,
                  pending.generation == generation,
                  pending.remaining.first?.kind == kind else {
                break
            }
            if let data {
                pending.payloads[kind] = data
            }
            clipboardDataRequestToken &+= 1
            pending.remaining.removeFirst()
            pendingRemoteClipboard = pending
            if let next = pending.remaining.first {
                worker?.requestClipboardData(generation: generation, format: next)
                scheduleClipboardDataTimeout(generation: generation, format: next)
            } else {
                pendingRemoteClipboard = nil
                var contentPayloads = pending.payloads
                if let list = pending.payloads[.fileList],
                   let files = ClipboardFileListCodec.decode(list) {
                    contentPayloads[.fileList] = nil
                    let requiresApproval = remoteFileConfirmationPolicy.requiresApproval(
                        profileRequiresApproval: activeChannelOptions.confirmClipboardFiles
                    )
                    let gate = RemoteClipboardFileTransferGate(requiresApproval: requiresApproval)
                    pendingRemoteFiles = (generation, files, gate)
                    let resolve: @MainActor (ClipboardFileTransferConfirmationDecision) -> Void = {
                        [weak self] decision in
                        guard let self,
                              var current = self.pendingRemoteFiles,
                              current.generation == generation,
                              generation == self.remoteClipboardGeneration else { return }
                        if requiresApproval {
                            guard current.gate.resolveApproval(decision.approved) else { return }
                        }
                        guard current.gate.approved else {
                            self.pendingRemoteFiles = nil
                            return
                        }
                        self.remoteFileConfirmationPolicy.record(decision)
                        self.pendingRemoteFiles = current
                        switch decision {
                        case .cancel:
                            self.pendingRemoteFiles = nil
                        case .confirmCopy:
                            self.onClipboardFilesOffered?(generation, current.files)
                        case let .directSave(destination, _):
                            self.onClipboardFilesDirectSaveRequested?(
                                generation,
                                current.files,
                                destination
                            )
                        }
                    }
                    if requiresApproval {
                        let approval = ClipboardFileTransferApproval(
                            direction: .windowsToMac,
                            fileCount: files.count,
                            totalBytes: files.reduce(0) { $0 + $1.size },
                            fileNames: files.map(\.name)
                        )
                        guard let confirmation = onClipboardFileTransferConfirmation else {
                            pendingRemoteFiles = nil
                            break
                        }
                        confirmation(approval, resolve)
                    } else {
                        resolve(.confirmCopy(suppressFurtherPrompts: false))
                    }
                }
                if !contentPayloads.isEmpty {
                    onClipboardContentReceived?(contentPayloads)
                }
            }
        case let .clipboardFileApprovalRequested(approval):
            guard let confirmation = onClipboardFileTransferConfirmation else {
                worker?.resolveLocalFileTransferApproval(false)
                break
            }
            confirmation(approval) { [weak self] decision in
                self?.worker?.resolveLocalFileTransferApproval(decision.approved)
            }
        case let .clipboardFilesReady(generation, urls):
            guard generation == remoteClipboardGeneration else { break }
            completedRemoteFileGeneration = generation
            pendingRemoteFiles = nil
            remoteFileConfirmationPolicy.reset()
            clipboardTransferProgress = nil
            onClipboardFilesReceived?(generation, urls)
        case let .clipboardFilesFailed(generation):
            guard generation == remoteClipboardGeneration else { break }
            pendingRemoteFiles = nil
            onClipboardFilesFailed?(generation)
        case let .clipboardTransferProgress(generation, progress):
            if let generation,
               generation == completedRemoteFileGeneration,
               progress != nil {
                break
            }
            clipboardTransferProgress = progress
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
            onClipboardFileTransferConfirmationCancellation?()
            worker = nil
            pendingRemoteClipboard = nil
            pendingRemoteFiles = nil
            completedRemoteFileGeneration = nil
            clipboardDataRequestToken &+= 1
            clipboardTransferProgress = nil
            certificateChallenge = nil
            displayControlReady = false
            if stateMachine.finish(sessionID: id) {
                phase = stateMachine.phase
            }
        }
    }

    private func scheduleClipboardDataTimeout(
        generation: UInt64,
        format: RemoteClipboardFormat
    ) {
        clipboardDataRequestToken &+= 1
        let token = clipboardDataRequestToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self,
                  self.clipboardDataRequestToken == token,
                  let pending = self.pendingRemoteClipboard,
                  pending.generation == generation,
                  pending.remaining.first == format else {
                return
            }
            self.pendingRemoteClipboard = nil
            self.clipboardDataRequestToken &+= 1
            FarframeLog.logger(for: .session).error(
                "Clipboard object request timed out; format=\(format.kind.rawValue, privacy: .public)"
            )
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
