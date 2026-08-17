import AppKit
import Combine
import Foundation

enum ShortcutCaptureScope: String, CaseIterable, Identifiable, Sendable {
    case windowed
    case fullscreen
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .windowed: String(localized: "仅窗口模式")
        case .fullscreen: String(localized: "仅全屏模式")
        case .both: String(localized: "窗口和全屏模式")
        }
    }

    func includes(isFullScreen: Bool) -> Bool {
        switch self {
        case .windowed: !isFullScreen
        case .fullscreen: isFullScreen
        case .both: true
        }
    }
}

struct MacShortcutChord: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard self.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return modifierFlags.intersection(relevant) == modifiers.intersection(relevant)
    }
}

struct RemoteShortcutChord: Equatable, Sendable {
    let displayName: String
    let modifiers: [UInt32]
    let key: UInt32

    var commands: [RemoteInputCommand] {
        var result = modifiers.map {
            RemoteInputCommand.scanCode($0, down: true, repeatKey: false)
        }
        result.append(.scanCode(key, down: true, repeatKey: false))
        result.append(.scanCode(key, down: false, repeatKey: false))
        result.append(contentsOf: modifiers.reversed().map {
            RemoteInputCommand.scanCode($0, down: false, repeatKey: false)
        })
        return result
    }
}

struct ShortcutPolicy: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let macChord: MacShortcutChord
    var captureWhenRemoteFocused: Bool
    let remoteChord: RemoteShortcutChord?
    var scope: ShortcutCaptureScope
    let requiresEnhancedCapture: Bool
    let isSystemReserved: Bool

    var macChordDisplayName: String {
        var parts: [String] = []
        if macChord.modifiers.contains(.control) { parts.append("Control") }
        if macChord.modifiers.contains(.option) { parts.append("Option") }
        if macChord.modifiers.contains(.shift) { parts.append("Shift") }
        if macChord.modifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.keyDisplayNames[macChord.keyCode] ?? "Key \(macChord.keyCode)")
        return parts.joined(separator: "-")
    }

    var remoteChordDisplayName: String {
        remoteChord?.displayName ?? String(localized: "仅阻止本地操作")
    }

    private static let keyDisplayNames: [UInt16: String] = [
        0: "A", 1: "S", 3: "F", 6: "Z", 7: "X", 8: "C", 9: "V",
        12: "Q", 13: "W", 17: "T", 35: "P", 45: "N", 48: "Tab",
        49: String(localized: "空格"), 53: "Escape",
        123: String(localized: "左"), 124: String(localized: "右"),
        125: String(localized: "下"), 126: String(localized: "上"),
    ]
}

extension ShortcutPolicy {
    static let defaults: [ShortcutPolicy] = [
        command("copy", String(localized: "复制"), keyCode: 8, remoteName: "Ctrl-C", remoteKey: WindowsScanCode.c),
        command("paste", String(localized: "粘贴"), keyCode: 9, remoteName: "Ctrl-V", remoteKey: WindowsScanCode.v),
        command("cut", String(localized: "剪切"), keyCode: 7, remoteName: "Ctrl-X", remoteKey: WindowsScanCode.x),
        command("select-all", String(localized: "全选"), keyCode: 0, remoteName: "Ctrl-A", remoteKey: WindowsScanCode.a),
        command("undo", String(localized: "撤销"), keyCode: 6, remoteName: "Ctrl-Z", remoteKey: WindowsScanCode.z),
        ShortcutPolicy(
            id: "redo",
            displayName: String(localized: "重做"),
            macChord: MacShortcutChord(keyCode: 6, modifiers: [.command, .shift]),
            captureWhenRemoteFocused: true,
            remoteChord: RemoteShortcutChord(
                displayName: "Ctrl-Y",
                modifiers: [WindowsScanCode.leftControl],
                key: WindowsScanCode.y
            ),
            scope: .both,
            requiresEnhancedCapture: false,
            isSystemReserved: false
        ),
        command("save", String(localized: "保存"), keyCode: 1, remoteName: "Ctrl-S", remoteKey: WindowsScanCode.s),
        command("find", String(localized: "查找"), keyCode: 3, remoteName: "Ctrl-F", remoteKey: WindowsScanCode.f),
        command("print", String(localized: "打印"), keyCode: 35, remoteName: "Ctrl-P", remoteKey: WindowsScanCode.p),
        command("new", String(localized: "新建"), keyCode: 45, remoteName: "Ctrl-N", remoteKey: WindowsScanCode.n),
        command("new-tab", String(localized: "新建标签页"), keyCode: 17, remoteName: "Ctrl-T", remoteKey: WindowsScanCode.t),
        command("close", String(localized: "关闭远程标签页或窗口"), keyCode: 13, remoteName: "Ctrl-W", remoteKey: WindowsScanCode.w),
        ShortcutPolicy(
            id: "quit-protection",
            displayName: String(localized: "防止本地退出"),
            macChord: MacShortcutChord(keyCode: 12, modifiers: [.command]),
            captureWhenRemoteFocused: true,
            remoteChord: nil,
            scope: .both,
            requiresEnhancedCapture: false,
            isSystemReserved: false
        ),
        enhanced(
            "app-switcher",
            String(localized: "Windows 任务视图"),
            keyCode: 48,
            modifiers: [.command],
            remoteName: "Win-Tab",
            remoteModifiers: [WindowsScanCode.leftWindows],
            remoteKey: WindowsScanCode.tab,
            captureWhenRemoteFocused: true,
            scope: .both
        ),
        enhanced(
            "windows-search",
            String(localized: "Windows 搜索"),
            keyCode: 49,
            modifiers: [.command],
            remoteName: "Win-S",
            remoteModifiers: [WindowsScanCode.leftWindows],
            remoteKey: WindowsScanCode.s
        ),
        enhanced(
            "space-left",
            String(localized: "切换到左侧 Windows 虚拟桌面"),
            keyCode: 123,
            modifiers: [.control, .command],
            remoteName: "Ctrl-Win-Left",
            remoteModifiers: [WindowsScanCode.leftControl, WindowsScanCode.leftWindows],
            remoteKey: WindowsScanCode.left,
            captureWhenRemoteFocused: true,
            scope: .both
        ),
        enhanced(
            "space-right",
            String(localized: "切换到右侧 Windows 虚拟桌面"),
            keyCode: 124,
            modifiers: [.control, .command],
            remoteName: "Ctrl-Win-Right",
            remoteModifiers: [WindowsScanCode.leftControl, WindowsScanCode.leftWindows],
            remoteKey: WindowsScanCode.right,
            captureWhenRemoteFocused: true,
            scope: .both
        ),
        enhanced(
            "mission-control-up",
            String(localized: "Mission Control 向上"),
            keyCode: 126,
            modifiers: [.control],
            remoteName: "Ctrl-Up",
            remoteModifiers: [WindowsScanCode.leftControl],
            remoteKey: WindowsScanCode.up
        ),
        enhanced(
            "mission-control-down",
            String(localized: "Mission Control 向下"),
            keyCode: 125,
            modifiers: [.control],
            remoteName: "Ctrl-Down",
            remoteModifiers: [WindowsScanCode.leftControl],
            remoteKey: WindowsScanCode.down
        ),
    ]

    private static func command(
        _ id: String,
        _ displayName: String,
        keyCode: UInt16,
        remoteName: String,
        remoteKey: UInt32
    ) -> ShortcutPolicy {
        ShortcutPolicy(
            id: id,
            displayName: displayName,
            macChord: MacShortcutChord(keyCode: keyCode, modifiers: [.command]),
            captureWhenRemoteFocused: true,
            remoteChord: RemoteShortcutChord(
                displayName: remoteName,
                modifiers: [WindowsScanCode.leftControl],
                key: remoteKey
            ),
            scope: .both,
            requiresEnhancedCapture: false,
            isSystemReserved: false
        )
    }

    private static func enhanced(
        _ id: String,
        _ displayName: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        remoteName: String,
        remoteModifiers: [UInt32],
        remoteKey: UInt32,
        captureWhenRemoteFocused: Bool = false,
        scope: ShortcutCaptureScope = .fullscreen
    ) -> ShortcutPolicy {
        ShortcutPolicy(
            id: id,
            displayName: displayName,
            macChord: MacShortcutChord(keyCode: keyCode, modifiers: modifiers),
            captureWhenRemoteFocused: captureWhenRemoteFocused,
            remoteChord: RemoteShortcutChord(
                displayName: remoteName,
                modifiers: remoteModifiers,
                key: remoteKey
            ),
            scope: scope,
            requiresEnhancedCapture: true,
            isSystemReserved: true
        )
    }
}

@MainActor
final class ShortcutSettingsStore: ObservableObject {
    @Published var policies: [ShortcutPolicy]

    init(policies: [ShortcutPolicy] = ShortcutPolicy.defaults) {
        self.policies = policies
    }

    func restoreDefaults() {
        policies = ShortcutPolicy.defaults
    }
}

enum ShortcutRoute: Equatable {
    case passThrough
    case captured(policyID: String, remoteCommands: [RemoteInputCommand])
    case releaseCapture
}

struct ShortcutRouter {
    static let emergencyChord = MacShortcutChord(
        keyCode: 53,
        modifiers: [.control, .option, .command]
    )

    static func isAlwaysLocalSecurityChord(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let lockScreen = MacShortcutChord(
            keyCode: 12,
            modifiers: [.control, .command]
        )
        let forceQuit = MacShortcutChord(
            keyCode: 53,
            modifiers: [.option, .command]
        )
        return lockScreen.matches(keyCode: keyCode, modifierFlags: modifierFlags) ||
            forceQuit.matches(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    var policies: [ShortcutPolicy]
    private(set) var suppressedKeyUps: Set<UInt16> = []

    mutating func routeKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isFullScreen: Bool
    ) -> ShortcutRoute {
        routeKeyDown(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isFullScreen: isFullScreen,
            enhancedCaptureAvailable: false
        )
    }

    mutating func routeKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isFullScreen: Bool,
        enhancedCaptureAvailable: Bool
    ) -> ShortcutRoute {
        if Self.emergencyChord.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            suppressedKeyUps.insert(keyCode)
            return .releaseCapture
        }
        guard let policy = policies.first(where: {
            $0.captureWhenRemoteFocused &&
                (enhancedCaptureAvailable || !$0.requiresEnhancedCapture) &&
                $0.scope.includes(isFullScreen: isFullScreen) &&
                $0.macChord.matches(keyCode: keyCode, modifierFlags: modifierFlags)
        }) else {
            return .passThrough
        }
        suppressedKeyUps.insert(keyCode)
        return .captured(
            policyID: policy.id,
            remoteCommands: policy.remoteChord?.commands ?? []
        )
    }

    mutating func routeEnhancedKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isFullScreen: Bool
    ) -> ShortcutRoute {
        routeKeyDown(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            isFullScreen: isFullScreen,
            enhancedCaptureAvailable: true
        )
    }

    mutating func shouldSuppressKeyUp(keyCode: UInt16) -> Bool {
        suppressedKeyUps.remove(keyCode) != nil
    }

    mutating func resetTransientState() {
        suppressedKeyUps.removeAll(keepingCapacity: true)
    }
}

enum ShortcutCaptureStatus: Equatable, Sendable {
    case inactive
    case basic
    case enhanced
    case degraded
    case released
}
