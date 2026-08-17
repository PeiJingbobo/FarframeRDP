import AppKit
import Foundation

enum RemotePointerButton: Int, CaseIterable, Sendable {
    case left = 1
    case right = 2
    case middle = 3
    case x1 = 4
    case x2 = 5
}

struct RemotePointerPosition: Equatable, Sendable {
    let x: UInt16
    let y: UInt16
}

enum RemoteInputCommand: Equatable, Sendable {
    case scanCode(UInt32, down: Bool, repeatKey: Bool)
    case pointerMove(RemotePointerPosition)
    case pointerButton(RemotePointerButton, down: Bool, position: RemotePointerPosition)
    case wheel(delta: Int16, horizontal: Bool, position: RemotePointerPosition)
    case synchronizeLocks(capsLock: Bool, numLock: Bool, scrollLock: Bool)
    case releaseAll
    case resize(RemoteDesktopSize)
    case monitorLayout([RemoteMonitorLayout])
}

enum DynamicResolutionPolicy {
    static let minimumDimension = 200
    static let maximumDimension = 8192

    static func targetSize(canvasSize: CGSize, backingScale: CGFloat = 1) -> RemoteDesktopSize? {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              backingScale.isFinite, backingScale > 0 else {
            return nil
        }
        let rawWidth = Int((canvasSize.width * backingScale).rounded(.toNearestOrAwayFromZero))
        let rawHeight = Int((canvasSize.height * backingScale).rounded(.toNearestOrAwayFromZero))
        let clampedWidth = min(max(rawWidth, minimumDimension), maximumDimension)
        let clampedHeight = min(max(rawHeight, minimumDimension), maximumDimension)
        let evenWidth = max(minimumDimension, clampedWidth - clampedWidth % 2)
        let evenHeight = max(minimumDimension, clampedHeight - clampedHeight % 2)
        return RemoteDesktopSize(width: evenWidth, height: evenHeight)
    }

    static func desktopScaleFactor(backingScale: CGFloat) -> Int {
        guard backingScale.isFinite, backingScale > 0 else { return 100 }
        return min(500, max(100, Int((backingScale * 100).rounded())))
    }
}

enum RemoteMonitorSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case window
    case allDisplays

    var id: Self { self }

    var title: String {
        switch self {
        case .window:
            String(localized: "当前窗口")
        case .allDisplays:
            String(localized: "全部显示器")
        }
    }
}

struct RemoteMonitorLayout: Equatable, Sendable {
    static let maximumCount = 16
    static let maximumScaleFactor = 500

    let left: Int32
    let top: Int32
    let width: Int
    let height: Int
    let desktopScaleFactor: Int
    let deviceScaleFactor: Int
    let primary: Bool

    init?(
        left: Int,
        top: Int,
        width: Int,
        height: Int,
        desktopScaleFactor: Int = 100,
        deviceScaleFactor: Int = 100,
        primary: Bool
    ) {
        guard RemoteDesktopSize(width: width, height: height) != nil,
              (0...Self.maximumScaleFactor).contains(desktopScaleFactor),
              (0...Self.maximumScaleFactor).contains(deviceScaleFactor),
              let convertedLeft = Int32(exactly: left),
              let convertedTop = Int32(exactly: top),
              left <= Int(Int32.max) - width,
              top <= Int(Int32.max) - height else {
            return nil
        }
        self.left = convertedLeft
        self.top = convertedTop
        self.width = width
        self.height = height
        self.desktopScaleFactor = desktopScaleFactor
        self.deviceScaleFactor = deviceScaleFactor
        self.primary = primary
    }
}

enum RemoteMonitorLayoutPolicy {
    static func targetLayout(
        selection: RemoteMonitorSelection,
        canvasSize: CGSize,
        backingScale: CGFloat = 1,
        windowScreen: NSScreen?,
        screens: [NSScreen] = NSScreen.screens
    ) -> [RemoteMonitorLayout]? {
        switch selection {
        case .window:
            guard let size = DynamicResolutionPolicy.targetSize(
                canvasSize: canvasSize,
                backingScale: backingScale
            ) else {
                return nil
            }
            return [
                RemoteMonitorLayout(
                    left: 0,
                    top: 0,
                    width: size.width,
                    height: size.height,
                    desktopScaleFactor: DynamicResolutionPolicy.desktopScaleFactor(
                        backingScale: backingScale
                    ),
                    deviceScaleFactor: 100,
                    primary: true
                )
            ].compactMap { $0 }
        case .allDisplays:
            // NSScreen exposes a shared logical coordinate space. Keep the
            // existing 100% multi-display layout until mixed-DPI physical
            // monitor coordinates are modeled as one contiguous pixel space.
            let orderedScreens = screens.prefix(RemoteMonitorLayout.maximumCount)
            guard let primaryScreen = windowScreen ?? NSScreen.main ?? screens.first else {
                return nil
            }
            let primaryFrame = primaryScreen.frame
            let layouts = orderedScreens.compactMap { screen -> RemoteMonitorLayout? in
                let frame = screen.frame
                guard let size = DynamicResolutionPolicy.targetSize(
                    canvasSize: frame.size,
                    backingScale: 1
                ) else {
                    return nil
                }
                let left = Int((frame.minX - primaryFrame.minX).rounded(.toNearestOrAwayFromZero))
                let top = Int((primaryFrame.maxY - frame.maxY).rounded(.toNearestOrAwayFromZero))
                return RemoteMonitorLayout(
                    left: left,
                    top: top,
                    width: size.width,
                    height: size.height,
                    desktopScaleFactor: 100,
                    deviceScaleFactor: 100,
                    primary: screen == primaryScreen
                )
            }
            guard layouts.count == orderedScreens.count,
                  layouts.filter(\.primary).count == 1 else {
                return nil
            }
            return layouts
        }
    }
}

struct RemoteViewportGeometry: Equatable, Sendable {
    let desktopSize: RemoteDesktopSize
    let canvasSize: CGSize
    let backingScale: CGFloat
    let scalingMode: RemoteScalingMode

    var destinationRect: CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0, backingScale > 0 else {
            return .zero
        }
        let remoteWidth = CGFloat(desktopSize.width)
        let remoteHeight = CGFloat(desktopSize.height)
        let displayedSize: CGSize
        switch scalingMode {
        case .fit:
            let factor = min(canvasSize.width / remoteWidth, canvasSize.height / remoteHeight)
            displayedSize = CGSize(width: remoteWidth * factor, height: remoteHeight * factor)
        case .actualPixels:
            displayedSize = CGSize(
                width: remoteWidth / backingScale,
                height: remoteHeight / backingScale
            )
        }
        return CGRect(
            x: (canvasSize.width - displayedSize.width) / 2,
            y: (canvasSize.height - displayedSize.height) / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    /// AppKit canvas coordinates use a bottom-left origin; RDP uses top-left.
    func remotePosition(for localPoint: CGPoint) -> RemotePointerPosition? {
        let destination = destinationRect
        guard destination.width > 0, destination.height > 0,
              destination.contains(localPoint) else {
            return nil
        }
        let normalizedX = (localPoint.x - destination.minX) / destination.width
        let normalizedY = (destination.maxY - localPoint.y) / destination.height
        let x = min(desktopSize.width - 1, max(0, Int(normalizedX * CGFloat(desktopSize.width))))
        let y = min(desktopSize.height - 1, max(0, Int(normalizedY * CGFloat(desktopSize.height))))
        guard let remoteX = UInt16(exactly: x), let remoteY = UInt16(exactly: y) else {
            return nil
        }
        return RemotePointerPosition(x: remoteX, y: remoteY)
    }
}

enum WindowsScanCode {
    static let escape: UInt32 = 0x01
    static let key1: UInt32 = 0x02
    static let key2: UInt32 = 0x03
    static let key3: UInt32 = 0x04
    static let key4: UInt32 = 0x05
    static let key5: UInt32 = 0x06
    static let key6: UInt32 = 0x07
    static let key7: UInt32 = 0x08
    static let key8: UInt32 = 0x09
    static let key9: UInt32 = 0x0A
    static let key0: UInt32 = 0x0B
    static let minus: UInt32 = 0x0C
    static let equals: UInt32 = 0x0D
    static let backspace: UInt32 = 0x0E
    static let tab: UInt32 = 0x0F
    static let q: UInt32 = 0x10
    static let w: UInt32 = 0x11
    static let e: UInt32 = 0x12
    static let r: UInt32 = 0x13
    static let t: UInt32 = 0x14
    static let y: UInt32 = 0x15
    static let u: UInt32 = 0x16
    static let i: UInt32 = 0x17
    static let o: UInt32 = 0x18
    static let p: UInt32 = 0x19
    static let leftBracket: UInt32 = 0x1A
    static let rightBracket: UInt32 = 0x1B
    static let enter: UInt32 = 0x1C
    static let leftControl: UInt32 = 0x1D
    static let a: UInt32 = 0x1E
    static let s: UInt32 = 0x1F
    static let d: UInt32 = 0x20
    static let f: UInt32 = 0x21
    static let g: UInt32 = 0x22
    static let h: UInt32 = 0x23
    static let j: UInt32 = 0x24
    static let k: UInt32 = 0x25
    static let l: UInt32 = 0x26
    static let semicolon: UInt32 = 0x27
    static let quote: UInt32 = 0x28
    static let grave: UInt32 = 0x29
    static let leftShift: UInt32 = 0x2A
    static let backslash: UInt32 = 0x2B
    static let z: UInt32 = 0x2C
    static let x: UInt32 = 0x2D
    static let c: UInt32 = 0x2E
    static let v: UInt32 = 0x2F
    static let b: UInt32 = 0x30
    static let n: UInt32 = 0x31
    static let m: UInt32 = 0x32
    static let comma: UInt32 = 0x33
    static let period: UInt32 = 0x34
    static let slash: UInt32 = 0x35
    static let rightShift: UInt32 = 0x36
    static let numpadMultiply: UInt32 = 0x37
    static let leftAlt: UInt32 = 0x38
    static let space: UInt32 = 0x39
    static let capsLock: UInt32 = 0x3A
    static let f1: UInt32 = 0x3B
    static let f2: UInt32 = 0x3C
    static let f3: UInt32 = 0x3D
    static let f4: UInt32 = 0x3E
    static let f5: UInt32 = 0x3F
    static let f6: UInt32 = 0x40
    static let f7: UInt32 = 0x41
    static let f8: UInt32 = 0x42
    static let f9: UInt32 = 0x43
    static let f10: UInt32 = 0x44
    static let numLock: UInt32 = 0x45
    static let numpad7: UInt32 = 0x47
    static let numpad8: UInt32 = 0x48
    static let numpad9: UInt32 = 0x49
    static let numpadSubtract: UInt32 = 0x4A
    static let numpad4: UInt32 = 0x4B
    static let numpad5: UInt32 = 0x4C
    static let numpad6: UInt32 = 0x4D
    static let numpadAdd: UInt32 = 0x4E
    static let numpad1: UInt32 = 0x4F
    static let numpad2: UInt32 = 0x50
    static let numpad3: UInt32 = 0x51
    static let numpad0: UInt32 = 0x52
    static let numpadDecimal: UInt32 = 0x53
    static let f11: UInt32 = 0x57
    static let f12: UInt32 = 0x58
    static let extended: UInt32 = 0x100
    static let numpadEnter: UInt32 = extended | 0x1C
    static let rightControl: UInt32 = extended | 0x1D
    static let numpadDivide: UInt32 = extended | 0x35
    static let rightAlt: UInt32 = extended | 0x38
    static let home: UInt32 = extended | 0x47
    static let up: UInt32 = extended | 0x48
    static let pageUp: UInt32 = extended | 0x49
    static let left: UInt32 = extended | 0x4B
    static let right: UInt32 = extended | 0x4D
    static let end: UInt32 = extended | 0x4F
    static let down: UInt32 = extended | 0x50
    static let pageDown: UInt32 = extended | 0x51
    static let insert: UInt32 = extended | 0x52
    static let delete: UInt32 = extended | 0x53
    static let leftWindows: UInt32 = extended | 0x5B
    static let rightWindows: UInt32 = extended | 0x5C

    static let modifiers: Set<UInt32> = [
        leftControl, rightControl,
        leftAlt, rightAlt,
        leftShift, rightShift,
        leftWindows, rightWindows,
    ]
}

enum MacKeyCodeMapper {
    private static let mapping: [UInt16: UInt32] = [
        0: WindowsScanCode.a, 1: WindowsScanCode.s, 2: WindowsScanCode.d,
        3: WindowsScanCode.f, 4: WindowsScanCode.h, 5: WindowsScanCode.g,
        6: WindowsScanCode.z, 7: WindowsScanCode.x, 8: WindowsScanCode.c,
        9: WindowsScanCode.v, 11: WindowsScanCode.b, 12: WindowsScanCode.q,
        13: WindowsScanCode.w, 14: WindowsScanCode.e, 15: WindowsScanCode.r,
        16: WindowsScanCode.y, 17: WindowsScanCode.t, 18: WindowsScanCode.key1,
        19: WindowsScanCode.key2, 20: WindowsScanCode.key3, 21: WindowsScanCode.key4,
        22: WindowsScanCode.key6, 23: WindowsScanCode.key5, 24: WindowsScanCode.equals,
        25: WindowsScanCode.key9, 26: WindowsScanCode.key7, 27: WindowsScanCode.minus,
        28: WindowsScanCode.key8, 29: WindowsScanCode.key0, 30: WindowsScanCode.rightBracket,
        31: WindowsScanCode.o, 32: WindowsScanCode.u, 33: WindowsScanCode.leftBracket,
        34: WindowsScanCode.i, 35: WindowsScanCode.p, 36: WindowsScanCode.enter,
        37: WindowsScanCode.l, 38: WindowsScanCode.j, 39: WindowsScanCode.quote,
        40: WindowsScanCode.k, 41: WindowsScanCode.semicolon, 42: WindowsScanCode.backslash,
        43: WindowsScanCode.comma, 44: WindowsScanCode.slash, 45: WindowsScanCode.n,
        46: WindowsScanCode.m, 47: WindowsScanCode.period, 48: WindowsScanCode.tab,
        49: WindowsScanCode.space, 50: WindowsScanCode.grave,
        51: WindowsScanCode.backspace, 53: WindowsScanCode.escape,
        54: WindowsScanCode.rightWindows, 55: WindowsScanCode.leftWindows,
        56: WindowsScanCode.leftShift, 57: WindowsScanCode.capsLock,
        58: WindowsScanCode.leftAlt, 59: WindowsScanCode.leftControl,
        60: WindowsScanCode.rightShift, 61: WindowsScanCode.rightAlt,
        62: WindowsScanCode.rightControl,
        65: WindowsScanCode.numpadDecimal, 67: WindowsScanCode.numpadMultiply,
        69: WindowsScanCode.numpadAdd, 71: WindowsScanCode.numLock,
        75: WindowsScanCode.numpadDivide, 76: WindowsScanCode.numpadEnter,
        78: WindowsScanCode.numpadSubtract,
        82: WindowsScanCode.numpad0, 83: WindowsScanCode.numpad1,
        84: WindowsScanCode.numpad2, 85: WindowsScanCode.numpad3,
        86: WindowsScanCode.numpad4, 87: WindowsScanCode.numpad5,
        88: WindowsScanCode.numpad6, 89: WindowsScanCode.numpad7,
        91: WindowsScanCode.numpad8, 92: WindowsScanCode.numpad9,
        96: WindowsScanCode.f5, 97: WindowsScanCode.f6, 98: WindowsScanCode.f7,
        99: WindowsScanCode.f3, 100: WindowsScanCode.f8, 101: WindowsScanCode.f9,
        103: WindowsScanCode.f11, 109: WindowsScanCode.f10,
        111: WindowsScanCode.f12, 114: WindowsScanCode.insert,
        115: WindowsScanCode.home, 116: WindowsScanCode.pageUp,
        117: WindowsScanCode.delete, 118: WindowsScanCode.f4,
        119: WindowsScanCode.end, 120: WindowsScanCode.f2,
        121: WindowsScanCode.pageDown, 122: WindowsScanCode.f1,
        123: WindowsScanCode.left, 124: WindowsScanCode.right,
        125: WindowsScanCode.down, 126: WindowsScanCode.up,
    ]

    static func scanCode(for keyCode: UInt16) -> UInt32? {
        mapping[keyCode]
    }

    static func isModifier(_ keyCode: UInt16) -> Bool {
        (54...62).contains(keyCode) && keyCode != 57
    }
}

struct RemoteInputState: Sendable {
    private(set) var pressedScanCodes: Set<UInt32> = []
    private(set) var pressedButtons: Set<RemotePointerButton> = []
    private(set) var numLock = false

    mutating func keyCommand(
        keyCode: UInt16,
        down: Bool,
        repeatKey: Bool
    ) -> RemoteInputCommand? {
        guard let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) else {
            return nil
        }
        if down {
            if repeatKey {
                guard pressedScanCodes.contains(scanCode) else { return nil }
            } else if !pressedScanCodes.insert(scanCode).inserted {
                return nil
            } else if scanCode == WindowsScanCode.numLock {
                numLock.toggle()
            }
        } else if pressedScanCodes.remove(scanCode) == nil {
            return nil
        }
        return .scanCode(scanCode, down: down, repeatKey: repeatKey)
    }

    mutating func modifierCommand(keyCode: UInt16) -> RemoteInputCommand? {
        guard MacKeyCodeMapper.isModifier(keyCode),
              let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) else {
            return nil
        }
        return setModifierCommand(
            keyCode: keyCode,
            down: !pressedScanCodes.contains(scanCode)
        )
    }

    mutating func setModifierCommand(
        keyCode: UInt16,
        down: Bool
    ) -> RemoteInputCommand? {
        guard MacKeyCodeMapper.isModifier(keyCode),
              let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) else {
            return nil
        }
        if down {
            guard pressedScanCodes.insert(scanCode).inserted else { return nil }
        } else {
            guard pressedScanCodes.remove(scanCode) != nil else { return nil }
        }
        return .scanCode(scanCode, down: down, repeatKey: false)
    }

    mutating func releaseStaleModifiers(
        notPresentIn modifierFlags: NSEvent.ModifierFlags
    ) -> [(scanCode: UInt32, command: RemoteInputCommand)] {
        let staleScanCodes = pressedScanCodes
            .intersection(WindowsScanCode.modifiers)
            .filter { scanCode in
                switch scanCode {
                case WindowsScanCode.leftControl, WindowsScanCode.rightControl:
                    !modifierFlags.contains(.control)
                case WindowsScanCode.leftAlt, WindowsScanCode.rightAlt:
                    !modifierFlags.contains(.option)
                case WindowsScanCode.leftShift, WindowsScanCode.rightShift:
                    !modifierFlags.contains(.shift)
                case WindowsScanCode.leftWindows, WindowsScanCode.rightWindows:
                    !modifierFlags.contains(.command)
                default:
                    false
                }
            }
            .sorted()
        for scanCode in staleScanCodes {
            pressedScanCodes.remove(scanCode)
        }
        return staleScanCodes.map {
            ($0, .scanCode($0, down: false, repeatKey: false))
        }
    }

    mutating func buttonCommand(
        _ button: RemotePointerButton,
        down: Bool,
        position: RemotePointerPosition
    ) -> RemoteInputCommand? {
        if down {
            guard pressedButtons.insert(button).inserted else { return nil }
        } else {
            guard pressedButtons.remove(button) != nil else { return nil }
        }
        return .pointerButton(button, down: down, position: position)
    }

    mutating func releaseAll() -> RemoteInputCommand {
        pressedScanCodes.removeAll(keepingCapacity: true)
        pressedButtons.removeAll(keepingCapacity: true)
        return .releaseAll
    }

    mutating func releasePressedModifiers() -> [(scanCode: UInt32, command: RemoteInputCommand)] {
        let scanCodes = pressedScanCodes
            .intersection(WindowsScanCode.modifiers)
            .sorted()
        for scanCode in scanCodes {
            pressedScanCodes.remove(scanCode)
        }
        return scanCodes.map {
            ($0, .scanCode($0, down: false, repeatKey: false))
        }
    }
}
