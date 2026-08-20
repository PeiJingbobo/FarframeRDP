import FarframeCore
import Foundation
import QuartzCore
import SwiftData

enum ConnectionProfileValidationError: Error, Equatable, Sendable {
    case emptyDisplayName
    case displayNameTooLong
    case invalidRemoteAppConfiguration
    case invalidMicrophoneConfiguration
    case invalidEndpoint(ConnectionConfigurationError)
}

enum RemoteResolutionOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case fitWindow
    case size1280x720
    case size1280x800
    case size1366x768
    case size1440x900
    case size1600x900
    case size1920x1080
    case size1920x1200
    case size2560x1440
    case size3840x2160

    var id: Self { self }

    var title: String {
        guard let desktopSize else { return String(localized: "适应窗口") }
        return "\(desktopSize.width) × \(desktopSize.height)"
    }

    var desktopSize: RemoteDesktopSize? {
        switch self {
        case .fitWindow: nil
        case .size1280x720: RemoteDesktopSize(width: 1280, height: 720)
        case .size1280x800: RemoteDesktopSize(width: 1280, height: 800)
        case .size1366x768: RemoteDesktopSize(width: 1366, height: 768)
        case .size1440x900: RemoteDesktopSize(width: 1440, height: 900)
        case .size1600x900: RemoteDesktopSize(width: 1600, height: 900)
        case .size1920x1080: RemoteDesktopSize(width: 1920, height: 1080)
        case .size1920x1200: RemoteDesktopSize(width: 1920, height: 1200)
        case .size2560x1440: RemoteDesktopSize(width: 2560, height: 1440)
        case .size3840x2160: RemoteDesktopSize(width: 3840, height: 2160)
        }
    }
}

enum RemotePresentationRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case adaptive
    case fps30
    case fps60

    var id: Self { self }

    var title: String {
        switch self {
        case .adaptive: String(localized: "自适应")
        case .fps30: "30 FPS"
        case .fps60: "60 FPS"
        }
    }

    var frameRateRange: CAFrameRateRange {
        switch self {
        case .adaptive:
            .default
        case .fps30:
            CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        case .fps60:
            CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        }
    }
}

struct ProfileDesktopOptions: Codable, Equatable, Sendable {
    var monitorSelection: RemoteMonitorSelection
    var resolution: RemoteResolutionOption
    var presentationRate: RemotePresentationRate

    private enum CodingKeys: String, CodingKey {
        case monitorSelection
        case resolution
        case presentationRate
    }

    init(
        monitorSelection: RemoteMonitorSelection = .window,
        resolution: RemoteResolutionOption = .fitWindow,
        presentationRate: RemotePresentationRate = .adaptive
    ) {
        self.monitorSelection = monitorSelection
        self.resolution = resolution
        self.presentationRate = presentationRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorSelection = try container.decodeIfPresent(RemoteMonitorSelection.self, forKey: .monitorSelection) ?? .window
        resolution = try container.decodeIfPresent(RemoteResolutionOption.self, forKey: .resolution) ?? .fitWindow
        presentationRate = try container.decodeIfPresent(RemotePresentationRate.self, forKey: .presentationRate) ?? .adaptive
    }
}

struct ProfileGatewayOptions: Codable, Equatable, Sendable {
    var enabled: Bool
    var host: String
    var port: Int
    var useSameCredentials: Bool
    var username: String
    var domain: String

    init(
        enabled: Bool = false,
        host: String = "",
        port: Int = 443,
        useSameCredentials: Bool = true,
        username: String = "",
        domain: String = ""
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.useSameCredentials = useSameCredentials
        self.username = username
        self.domain = domain
    }
}

struct ProfileRemoteAppOptions: Codable, Equatable, Sendable {
    var enabled: Bool
    var program: String
    var arguments: String
    var workingDirectory: String

    init(
        enabled: Bool = false,
        program: String = "",
        arguments: String = "",
        workingDirectory: String = ""
    ) {
        self.enabled = enabled
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

struct ProfileReconnectOptions: Codable, Equatable, Sendable {
    var enabled: Bool
    var maximumAttempts: Int

    init(
        enabled: Bool = false,
        maximumAttempts: Int = 3
    ) {
        self.enabled = enabled
        self.maximumAttempts = maximumAttempts
    }

    var policy: ConnectionReconnectPolicy {
        ConnectionReconnectPolicy(
            enabled: enabled,
            maximumAttempts: maximumAttempts
        )
    }
}

enum ClipboardTransferDirection: String, Codable, CaseIterable, Sendable {
    case bidirectional
    case macToWindows
    case windowsToMac

    var allowsLocalToRemote: Bool { self != .windowsToMac }
    var allowsRemoteToLocal: Bool { self != .macToWindows }
}

struct ProfileRedirectOptions: Codable, Equatable, Sendable {
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
    var directoryRedirectionEnabled: Bool
    var redirectedDirectoryPath: String

    init(
        clipboardEnabled: Bool = true,
        clipboardText: Bool = true,
        clipboardFormattedText: Bool = false,
        clipboardImages: Bool = false,
        clipboardFiles: Bool = false,
        clipboardDirection: ClipboardTransferDirection = .bidirectional,
        confirmClipboardFiles: Bool = true,
        audioPlayback: Bool = true,
        microphoneRedirection: Bool = false,
        microphoneDeviceName: String = "",
        directoryRedirectionEnabled: Bool = false,
        redirectedDirectoryPath: String = ""
    ) {
        self.clipboardEnabled = clipboardEnabled
        self.clipboardText = clipboardText
        self.clipboardFormattedText = clipboardFormattedText
        self.clipboardImages = clipboardImages
        self.clipboardFiles = clipboardFiles
        self.clipboardDirection = clipboardDirection
        self.confirmClipboardFiles = confirmClipboardFiles
        self.audioPlayback = audioPlayback
        self.microphoneRedirection = microphoneRedirection
        self.microphoneDeviceName = microphoneDeviceName
        self.directoryRedirectionEnabled = directoryRedirectionEnabled
        self.redirectedDirectoryPath = redirectedDirectoryPath
    }

    private enum CodingKeys: String, CodingKey {
        case clipboardEnabled
        case clipboardText
        case clipboardFormattedText
        case clipboardImages
        case clipboardFiles
        case clipboardDirection
        case confirmClipboardFiles
        case audioPlayback
        case microphoneRedirection
        case microphoneDeviceName
        case directoryRedirectionEnabled
        case redirectedDirectoryPath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clipboardText = try values.decodeIfPresent(Bool.self, forKey: .clipboardText) ?? true
        clipboardEnabled = try values.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? clipboardText
        // Existing profiles must remain text-only after upgrading.
        clipboardFormattedText = try values.decodeIfPresent(Bool.self, forKey: .clipboardFormattedText) ?? false
        clipboardImages = try values.decodeIfPresent(Bool.self, forKey: .clipboardImages) ?? false
        clipboardFiles = try values.decodeIfPresent(Bool.self, forKey: .clipboardFiles) ?? false
        clipboardDirection = try values.decodeIfPresent(
            ClipboardTransferDirection.self,
            forKey: .clipboardDirection
        ) ?? .bidirectional
        confirmClipboardFiles = try values.decodeIfPresent(Bool.self, forKey: .confirmClipboardFiles) ?? true
        audioPlayback = try values.decodeIfPresent(Bool.self, forKey: .audioPlayback) ?? true
        microphoneRedirection = try values.decodeIfPresent(Bool.self, forKey: .microphoneRedirection) ?? false
        microphoneDeviceName = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceName) ?? ""
        directoryRedirectionEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .directoryRedirectionEnabled
        ) ?? false
        redirectedDirectoryPath = try values.decodeIfPresent(String.self, forKey: .redirectedDirectoryPath) ?? ""
    }

    var enabledDirectoryPath: String? {
        guard directoryRedirectionEnabled, !redirectedDirectoryPath.isEmpty else { return nil }
        return redirectedDirectoryPath
    }
}

private enum ProfileOptionsCodec {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?, default defaultValue: T) -> T {
        guard let data else { return defaultValue }
        return (try? JSONDecoder().decode(type, from: data)) ?? defaultValue
    }
}

struct ConnectionProfileDraft: Equatable, Sendable {
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var gatewayProfileID: UUID?
    var gatewayOptions: ProfileGatewayOptions
    var remoteAppOptions: ProfileRemoteAppOptions
    var reconnectOptions: ProfileReconnectOptions
    var desktopOptions: ProfileDesktopOptions
    var redirectOptions: ProfileRedirectOptions
    var shortcutProfileID: String?

    init(
        displayName: String = "",
        host: String = "",
        port: Int = 3389,
        username: String = "",
        domain: String = "",
        gatewayProfileID: UUID? = nil,
        gatewayOptions: ProfileGatewayOptions = ProfileGatewayOptions(),
        remoteAppOptions: ProfileRemoteAppOptions = ProfileRemoteAppOptions(),
        reconnectOptions: ProfileReconnectOptions = ProfileReconnectOptions(),
        desktopOptions: ProfileDesktopOptions = ProfileDesktopOptions(),
        redirectOptions: ProfileRedirectOptions = ProfileRedirectOptions(),
        shortcutProfileID: String? = nil
    ) {
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.gatewayProfileID = gatewayProfileID
        self.gatewayOptions = gatewayOptions
        self.remoteAppOptions = remoteAppOptions
        self.reconnectOptions = reconnectOptions
        self.desktopOptions = desktopOptions
        self.redirectOptions = redirectOptions
        self.shortcutProfileID = shortcutProfileID
    }

    init(profile: ConnectionProfile) {
        self.init(
            displayName: profile.displayName,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            domain: profile.domain,
            gatewayProfileID: profile.gatewayProfileID,
            gatewayOptions: ProfileOptionsCodec.decode(
                ProfileGatewayOptions.self,
                from: profile.gatewayOptions,
                default: ProfileGatewayOptions()
            ),
            remoteAppOptions: ProfileOptionsCodec.decode(
                ProfileRemoteAppOptions.self,
                from: profile.remoteAppOptions,
                default: ProfileRemoteAppOptions()
            ),
            reconnectOptions: ProfileOptionsCodec.decode(
                ProfileReconnectOptions.self,
                from: profile.reconnectOptions,
                default: ProfileReconnectOptions()
            ),
            desktopOptions: ProfileOptionsCodec.decode(
                ProfileDesktopOptions.self,
                from: profile.desktopOptions,
                default: ProfileDesktopOptions()
            ),
            redirectOptions: ProfileOptionsCodec.decode(
                ProfileRedirectOptions.self,
                from: profile.redirectOptions,
                default: ProfileRedirectOptions()
            ),
            shortcutProfileID: profile.shortcutProfileID
        )
    }

    func validated() throws -> (draft: ConnectionProfileDraft, endpoint: ConnectionEndpoint) {
        var value = self
        value.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        value.gatewayOptions.host = gatewayOptions.host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.gatewayOptions.username = gatewayOptions.username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.gatewayOptions.domain = gatewayOptions.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        value.remoteAppOptions.program = remoteAppOptions.program.trimmingCharacters(in: .whitespacesAndNewlines)
        value.remoteAppOptions.arguments = remoteAppOptions.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        value.remoteAppOptions.workingDirectory = remoteAppOptions.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        value.redirectOptions.microphoneDeviceName = redirectOptions.microphoneDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.displayName.isEmpty else {
            throw ConnectionProfileValidationError.emptyDisplayName
        }
        guard value.displayName.utf8.count <= 128 else {
            throw ConnectionProfileValidationError.displayNameTooLong
        }
        do {
            let endpoint = try ConnectionEndpoint(
                host: value.host,
                port: value.port,
                username: value.username,
                domain: value.domain
            )
            if value.gatewayOptions.enabled {
                _ = try ConnectionEndpoint(
                    host: value.gatewayOptions.host,
                    port: value.gatewayOptions.port,
                    username: value.gatewayOptions.useSameCredentials
                        ? value.username
                        : value.gatewayOptions.username,
                    domain: value.gatewayOptions.useSameCredentials
                        ? value.domain
                        : value.gatewayOptions.domain
                )
            }
            if value.remoteAppOptions.enabled &&
                (value.remoteAppOptions.program.isEmpty ||
                 value.remoteAppOptions.program.utf8.count > 4096 ||
                 value.remoteAppOptions.arguments.utf8.count > 4096 ||
                 value.remoteAppOptions.workingDirectory.utf8.count > 4096) {
                throw ConnectionProfileValidationError.invalidRemoteAppConfiguration
            }
            if value.redirectOptions.microphoneDeviceName.utf8.count > 512 {
                throw ConnectionProfileValidationError.invalidMicrophoneConfiguration
            }
            value.reconnectOptions.maximumAttempts = min(
                5,
                max(1, value.reconnectOptions.maximumAttempts)
            )
            return (value, endpoint)
        } catch let error as ConnectionConfigurationError {
            throw ConnectionProfileValidationError.invalidEndpoint(error)
        }
    }

    var channelOptions: ConnectionChannelOptions {
        ConnectionChannelOptions(
            // Display Control remains available for both fit-window updates and
            // toolbar changes between fixed resolutions.
            dynamicResolution: true,
            monitorSelection: desktopOptions.monitorSelection,
            clipboardEnabled: redirectOptions.clipboardEnabled,
            clipboardText: redirectOptions.clipboardText,
            clipboardFormattedText: redirectOptions.clipboardFormattedText,
            clipboardImages: redirectOptions.clipboardImages,
            clipboardFiles: redirectOptions.clipboardFiles,
            clipboardDirection: redirectOptions.clipboardDirection,
            confirmClipboardFiles: redirectOptions.confirmClipboardFiles,
            audioPlayback: redirectOptions.audioPlayback,
            microphoneRedirection: redirectOptions.microphoneRedirection,
            microphoneDeviceName: redirectOptions.microphoneDeviceName,
            redirectedDirectoryPath: redirectOptions.enabledDirectoryPath,
            gateway: gatewayOptions.enabled ? ConnectionGatewayOptions(
                host: gatewayOptions.host,
                port: UInt16(exactly: gatewayOptions.port) ?? 0,
                useSameCredentials: gatewayOptions.useSameCredentials,
                username: gatewayOptions.useSameCredentials ? username : gatewayOptions.username,
                domain: gatewayOptions.useSameCredentials ? domain : gatewayOptions.domain
            ) : nil,
            remoteApp: remoteAppOptions.enabled ? ConnectionRemoteAppOptions(
                program: remoteAppOptions.program,
                arguments: remoteAppOptions.arguments,
                workingDirectory: remoteAppOptions.workingDirectory
            ) : nil
        )
    }
}

@Model
final class ConnectionProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var gatewayProfileID: UUID?
    var gatewayOptions: Data?
    var remoteAppOptions: Data?
    var reconnectOptions: Data?
    var desktopOptions: Data?
    var redirectOptions: Data?
    var shortcutProfileID: String?
    var certificateTrustReference: String?
    var lastSuccessfulConnection: Date?
    var lastConnectionWarning: String?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        draft: ConnectionProfileDraft,
        certificateTrustReference: String? = nil,
        lastSuccessfulConnection: Date? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.displayName = draft.displayName
        self.host = draft.host
        self.port = draft.port
        self.username = draft.username
        self.domain = draft.domain
        self.gatewayProfileID = draft.gatewayProfileID
        self.gatewayOptions = ProfileOptionsCodec.encode(draft.gatewayOptions)
        self.remoteAppOptions = ProfileOptionsCodec.encode(draft.remoteAppOptions)
        self.reconnectOptions = ProfileOptionsCodec.encode(draft.reconnectOptions)
        self.desktopOptions = ProfileOptionsCodec.encode(draft.desktopOptions)
        self.redirectOptions = ProfileOptionsCodec.encode(draft.redirectOptions)
        self.shortcutProfileID = draft.shortcutProfileID
        self.certificateTrustReference = certificateTrustReference
        self.lastSuccessfulConnection = lastSuccessfulConnection
        self.lastConnectionWarning = nil
        self.createdAt = now
        self.modifiedAt = now
    }

    func endpoint() throws -> ConnectionEndpoint {
        try ConnectionEndpoint(host: host, port: port, username: username, domain: domain)
    }

    func apply(_ draft: ConnectionProfileDraft, now: Date = Date()) {
        displayName = draft.displayName
        host = draft.host
        port = draft.port
        username = draft.username
        domain = draft.domain
        gatewayProfileID = draft.gatewayProfileID
        gatewayOptions = ProfileOptionsCodec.encode(draft.gatewayOptions)
        remoteAppOptions = ProfileOptionsCodec.encode(draft.remoteAppOptions)
        reconnectOptions = ProfileOptionsCodec.encode(draft.reconnectOptions)
        desktopOptions = ProfileOptionsCodec.encode(draft.desktopOptions)
        redirectOptions = ProfileOptionsCodec.encode(draft.redirectOptions)
        shortcutProfileID = draft.shortcutProfileID
        modifiedAt = now
    }

    var accountSummary: String {
        domain.isEmpty ? username : "\(domain)\\\(username)"
    }

    var addressSummary: String {
        port == 3389 ? host : "\(host):\(port)"
    }
}

@MainActor
enum ConnectionProfilePersistence {
    static func create(
        draft: ConnectionProfileDraft,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> ConnectionProfile {
        let validated = try draft.validated().draft
        let profile = ConnectionProfile(draft: validated, now: now)
        context.insert(profile)
        try context.save()
        return profile
    }
}

enum FarframeSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ConnectionProfile.self]
    }
}

enum FarframeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FarframeSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
