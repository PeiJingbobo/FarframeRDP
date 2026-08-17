import AppKit
import CoreGraphics

struct EnhancedCaptureScope: Equatable, Sendable {
    var applicationIsActive: Bool
    var sessionIsConnected: Bool
    var canvasIsFirstResponder: Bool
    var userEnabled: Bool
    var permissionGranted: Bool

    var shouldInstallEventTap: Bool {
        applicationIsActive && sessionIsConnected && canvasIsFirstResponder &&
            userEnabled && permissionGranted
    }
}

struct EnhancedKeyEvent: Equatable, Sendable {
    let type: CGEventType
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let isRepeat: Bool

    var isMappablePhysicalInput: Bool {
        (type == .keyDown || type == .keyUp || type == .flagsChanged) &&
            MacKeyCodeMapper.scanCode(for: keyCode) != nil
    }
}

enum EnhancedEventTapNotification {
    static func requiresReenable(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }
}

enum EnhancedCaptureRuntimeState: Equatable, Sendable {
    case inactive
    case active
    case degraded
}

struct EnhancedTapRecoveryPolicy: Equatable, Sendable {
    static let maximumConsecutiveDisables = 3

    private(set) var consecutiveDisables = 0

    mutating func recordDisableNotification() -> Bool {
        consecutiveDisables += 1
        return consecutiveDisables < Self.maximumConsecutiveDisables
    }

    mutating func recordHealthyEvent() {
        consecutiveDisables = 0
    }

    mutating func reset() {
        consecutiveDisables = 0
    }
}

@MainActor
final class EnhancedShortcutCaptureController {
    typealias EventHandler = @MainActor (EnhancedKeyEvent) -> Bool
    typealias StateHandler = @MainActor (EnhancedCaptureRuntimeState) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let eventHandler: EventHandler
    private let stateHandler: StateHandler
    private var recoveryPolicy = EnhancedTapRecoveryPolicy()
    private(set) var runtimeState: EnhancedCaptureRuntimeState = .inactive

    init(
        eventHandler: @escaping EventHandler,
        stateHandler: @escaping StateHandler = { _ in }
    ) {
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    var isInstalled: Bool { eventTap != nil && runtimeState == .active }

    func update(scope: EnhancedCaptureScope) {
        if scope.shouldInstallEventTap {
            guard runtimeState != .degraded else { return }
            installIfNeeded()
        } else {
            uninstall()
        }
    }

    func uninstall() {
        teardownEventTap()
        recoveryPolicy.reset()
        publishState(.inactive)
    }

    private func teardownEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func process(_ event: EnhancedKeyEvent) -> Bool {
        recoveryPolicy.recordHealthyEvent()
        return eventHandler(event)
    }

    fileprivate func reenableAfterSystemDisable() {
        guard let eventTap else { return }
        guard recoveryPolicy.recordDisableNotification() else {
            Task { @MainActor [weak self] in
                self?.degrade()
            }
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        guard CGEvent.tapIsEnabled(tap: eventTap) else {
            Task { @MainActor [weak self] in
                self?.degrade()
            }
            return
        }
        publishState(.active)
    }

    private func installIfNeeded() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: enhancedShortcutEventTapCallback,
            userInfo: userInfo
        ) else {
            publishState(.degraded)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            degrade()
            return
        }
        recoveryPolicy.reset()
        publishState(.active)
    }

    private func degrade() {
        teardownEventTap()
        publishState(.degraded)
    }

    private func publishState(_ state: EnhancedCaptureRuntimeState) {
        guard runtimeState != state else { return }
        runtimeState = state
        stateHandler(state)
    }
}

private func enhancedShortcutEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<EnhancedShortcutCaptureController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if EnhancedEventTapNotification.requiresReenable(type) {
        MainActor.assumeIsolated {
            controller.reenableAfterSystemDisable()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }
    let keyEvent = EnhancedKeyEvent(
        type: type,
        keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    )
    let consumed = MainActor.assumeIsolated {
        controller.process(keyEvent)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
