import AppKit
import Metal
import QuartzCore

@MainActor
private final class CoreGraphicsFallbackView: NSView {
    private var image: CGImage?
    private var scalingMode: RemoteScalingMode = .fit

    override var isFlipped: Bool {
        true
    }

    func update(framebuffer: Data, size: RemoteDesktopSize, scalingMode: RemoteScalingMode) {
        guard let provider = CGDataProvider(data: framebuffer as CFData) else {
            return
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
        ).union(.byteOrder32Little)
        image = CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size.packedBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: scalingMode == .fit,
            intent: .defaultIntent
        )
        self.scalingMode = scalingMode
        needsDisplay = true
    }

    func setScalingMode(_ mode: RemoteScalingMode) {
        scalingMode = mode
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        bounds.fill()

        guard let image, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let imageSize: CGSize
        switch scalingMode {
        case .fit:
            let factor = min(
                bounds.width / CGFloat(image.width),
                bounds.height / CGFloat(image.height)
            )
            imageSize = CGSize(
                width: CGFloat(image.width) * factor,
                height: CGFloat(image.height) * factor
            )
        case .actualPixels:
            imageSize = CGSize(
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
        }
        let destination = CGRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        context.interpolationQuality = scalingMode == .fit ? .low : .none
        context.draw(image, in: destination)
    }
}

@MainActor
final class RemoteCanvasView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private let coreGraphicsFallbackView = CoreGraphicsFallbackView()

    private var remoteTexture: MTLTexture?
    private var framebuffer = Data()
    private var desktopSize: RemoteDesktopSize?
    private var pendingDirtyRect: RemoteFrameRect?
    private var renderInFlight = false
    private var needsPresentation = false
    private var presentationDisplayLink: CADisplayLink?
    private var activeCursor = NSCursor.arrow
    var onInput: (@MainActor (RemoteInputCommand) -> Void)?
    var onViewportResize: (@MainActor (RemoteDesktopSize) -> Void)?
    var onShortcutCaptureStatusChange: (@MainActor (ShortcutCaptureStatus) -> Void)?
    var shortcutPolicies: [ShortcutPolicy] = ShortcutPolicy.defaults {
        didSet {
            shortcutRouter.policies = shortcutPolicies
        }
    }
    private var remoteInputState = RemoteInputState()
    private var shortcutRouter = ShortcutRouter(policies: ShortcutPolicy.defaults)
    private lazy var enhancedCaptureController = EnhancedShortcutCaptureController(
        eventHandler: { [weak self] event in
            self?.processEnhancedKeyEvent(event) ?? false
        },
        stateHandler: { [weak self] state in
            self?.handleEnhancedCaptureRuntimeState(state)
        }
    )
    private var inputObservers: [NSObjectProtocol] = []
    private var localKeyMonitor: Any?
    private var suppressedModifierTransitions: Set<UInt32> = []
    private var pressedCommandKeyCodes: Set<UInt16> = []
    private var deferredCommandKeyCodes: Set<UInt16> = []
    private var enhancedKeyEventQueue: [EnhancedKeyEvent] = []
    private var enhancedKeyEventDrainScheduled = false
    private var pointerTrackingArea: NSTrackingArea?
    private var verticalWheelRemainder: CGFloat = 0
    private var horizontalWheelRemainder: CGFloat = 0
    private var lastCapsLockState = false
    private(set) var releaseAllRequestCount = 0
    private(set) var keyboardCaptureEnabled = true
    var enhancedCaptureEnabled = false {
        didSet { updateEnhancedCaptureScope() }
    }
    var enhancedCapturePermissionGranted = false {
        didSet { updateEnhancedCaptureScope() }
    }
    var sessionIsConnected = false {
        didSet { updateEnhancedCaptureScope() }
    }
    private(set) var shortcutCaptureStatus: ShortcutCaptureStatus = .inactive

    private(set) var currentCursorUpdate: RemoteCursorUpdate = .defaultCursor
    private(set) var scalingMode: RemoteScalingMode = .fit
    var presentationRate: RemotePresentationRate = .adaptive {
        didSet {
            guard presentationRate != oldValue else { return }
            configurePresentationDisplayLink()
        }
    }
    private(set) var lastRequestedDynamicResolution: RemoteDesktopSize?

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "正在等待远程桌面…"))
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    var displayedDesktopSize: RemoteDesktopSize? {
        desktopSize
    }

    var hasReceivedFrame: Bool {
        !framebuffer.isEmpty && statusLabel.isHidden
    }

    var hasLocalKeyMonitor: Bool {
        localKeyMonitor != nil
    }

    var isUsingCoreGraphicsFallback: Bool {
        device == nil ||
            ProcessInfo.processInfo.environment["FARFRAME_RENDERER"] == "coregraphics"
    }

    override init(frame frameRect: NSRect) {
        let selectedDevice = MTLCreateSystemDefaultDevice()
        device = selectedDevice
        commandQueue = selectedDevice?.makeCommandQueue()
        pipelineState = Self.makePipeline(device: selectedDevice)

        super.init(frame: frameRect)

        metalLayer.device = selectedDevice
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        coreGraphicsFallbackView.translatesAutoresizingMaskIntoConstraints = false
        coreGraphicsFallbackView.isHidden = !isUsingCoreGraphicsFallback
        addSubview(coreGraphicsFallbackView)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            coreGraphicsFallbackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            coreGraphicsFallbackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            coreGraphicsFallbackView.topAnchor.constraint(equalTo: topAnchor),
            coreGraphicsFallbackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if selectedDevice == nil {
            statusLabel.stringValue = String(localized: "正在使用 Core Graphics 诊断渲染器。")
        } else if commandQueue == nil || pipelineState == nil {
            statusLabel.stringValue = String(localized: "Metal 渲染不可用。")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if oldSize != newSize {
            requestDynamicResolutionUpdate()
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            lastCapsLockState = NSEvent.modifierFlags.contains(.capsLock)
            emitInput(.synchronizeLocks(
                capsLock: lastCapsLockState,
                numLock: remoteInputState.numLock,
                scrollLock: false
            ))
            publishShortcutCaptureStatus(keyboardCaptureEnabled ? .basic : .released)
            updateEnhancedCaptureScope()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        releaseAllRemoteInput()
        let resigned = super.resignFirstResponder()
        publishShortcutCaptureStatus(keyboardCaptureEnabled ? .inactive : .released)
        updateEnhancedCaptureScope()
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              handleShortcutKeyDown(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !handleCapturedLocalKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        _ = handleCapturedLocalKeyEvent(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !enhancedCaptureController.isInstalled else { return }
        handlePhysicalModifierChange(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        )
    }

    private func handlePhysicalModifierChange(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        if Self.isCommandKeyCode(keyCode) {
            handleCommandFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags)
            return
        }
        guard keyboardCaptureEnabled else { return }
        let modifierIsDown = Self.modifierFlag(for: keyCode)
            .map(modifierFlags.contains) ?? false
        if let scanCode = MacKeyCodeMapper.scanCode(for: keyCode),
           suppressedModifierTransitions.contains(scanCode) {
            suppressedModifierTransitions.remove(scanCode)
            if !modifierIsDown { return }
        }
        if keyCode == 57 {
            let capsLock = modifierFlags.contains(.capsLock)
            guard capsLock != lastCapsLockState else { return }
            lastCapsLockState = capsLock
            emitInput(.scanCode(WindowsScanCode.capsLock, down: true, repeatKey: false))
            emitInput(.scanCode(WindowsScanCode.capsLock, down: false, repeatKey: false))
            emitInput(.synchronizeLocks(
                capsLock: capsLock,
                numLock: remoteInputState.numLock,
                scrollLock: false
            ))
            return
        }
        if let command = remoteInputState.setModifierCommand(
            keyCode: keyCode,
            down: modifierIsDown
        ) {
            emitInput(command)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.left, down: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointerButton(.left, down: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.right, down: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointerButton(.right, down: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let button = remoteButton(for: event.buttonNumber) else { return }
        sendPointerButton(button, down: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = remoteButton(for: event.buttonNumber) else { return }
        sendPointerButton(button, down: false, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let position = remotePosition(for: event) else { return }
        reconcileRemoteModifiers(with: event.modifierFlags)
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 120
        verticalWheelRemainder += event.scrollingDeltaY * multiplier
        horizontalWheelRemainder += event.scrollingDeltaX * multiplier
        flushWheelRemainder(&verticalWheelRemainder, horizontal: false, position: position)
        flushWheelRemainder(&horizontalWheelRemainder, horizontal: true, position: position)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        pointerTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: activeCursor)
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        requestDynamicResolutionUpdate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow !== window {
            deactivateInputHandling()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configurePresentationDisplayLink()
        guard window != nil else {
            removeInputObservers()
            return
        }
        updateDrawableSize()
        requestDynamicResolutionUpdate()
        installInputObservers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configurePresentationDisplayLink()
        updateDrawableSize()
        requestDynamicResolutionUpdate()
    }

    func setScalingMode(_ mode: RemoteScalingMode) {
        guard scalingMode != mode else {
            return
        }
        scalingMode = mode
        coreGraphicsFallbackView.setScalingMode(mode)
        requestPresentation()
        requestDynamicResolutionUpdate()
    }

    func announceDesktopSize(_ size: RemoteDesktopSize) {
        guard desktopSize != size else {
            return
        }
        prepareFramebuffer(for: size)
        statusLabel.stringValue = String(localized: "正在等待首个远程画面…")
        requestPresentation()
    }

    func requestInitialDynamicResolution() {
        requestDynamicResolutionUpdate(force: true)
    }

    func applyCursorUpdate(_ update: RemoteCursorUpdate) {
        switch update {
        case let .shape(shape):
            guard let cursor = makeCursor(from: shape) else {
                return
            }
            activeCursor = cursor
        case .hidden:
            activeCursor = makeTransparentCursor()
        case .defaultCursor:
            activeCursor = .arrow
        case .position:
            break
        }
        currentCursorUpdate = update
        window?.invalidateCursorRects(for: self)
    }

    func display(_ update: RemoteFrameUpdate) {
        if desktopSize != update.desktopSize {
            prepareFramebuffer(for: update.desktopSize)
        }
        guard let desktopSize,
              framebuffer.count == desktopSize.packedByteCount else {
            return
        }

        let rect = update.dirtyRect
        let destinationStride = desktopSize.packedBytesPerRow
        framebuffer.withUnsafeMutableBytes { destination in
            update.pixels.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else {
                    return
                }
                for row in 0..<rect.height {
                    let destinationOffset = (rect.y + row) * destinationStride + rect.x * 4
                    let sourceOffset = row * update.bytesPerRow
                    memcpy(
                        destinationBase.advanced(by: destinationOffset),
                        sourceBase.advanced(by: sourceOffset),
                        update.bytesPerRow
                    )
                }
            }
        }

        if let pendingDirtyRect {
            self.pendingDirtyRect = pendingDirtyRect.union(rect, desktop: desktopSize)
        } else {
            pendingDirtyRect = rect
        }
        statusLabel.isHidden = true
        finishFrameIngestion()
    }

    func display(
        desktopSize: RemoteDesktopSize,
        dirtyRect rect: RemoteFrameRect,
        pixels: UnsafeRawBufferPointer,
        bytesPerRow: Int,
        sequenceNumber _: UInt64
    ) {
        if self.desktopSize != desktopSize {
            prepareFramebuffer(for: desktopSize)
        }
        guard framebuffer.count == desktopSize.packedByteCount,
              bytesPerRow >= desktopSize.packedBytesPerRow,
              bytesPerRow <= pixels.count,
              desktopSize.height <= pixels.count / bytesPerRow,
              let sourceBase = pixels.baseAddress else {
            return
        }

        let copyByteCount = rect.width * 4
        framebuffer.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<rect.height {
                let sourceOffset = (rect.y + row) * bytesPerRow + rect.x * 4
                let destinationOffset = (rect.y + row) * desktopSize.packedBytesPerRow + rect.x * 4
                memcpy(
                    destinationBase.advanced(by: destinationOffset),
                    sourceBase.advanced(by: sourceOffset),
                    copyByteCount
                )
            }
        }

        if let pendingDirtyRect {
            self.pendingDirtyRect = pendingDirtyRect.union(rect, desktop: desktopSize)
        } else {
            pendingDirtyRect = rect
        }
        statusLabel.isHidden = true
        finishFrameIngestion()
    }

    private func finishFrameIngestion() {
        if isUsingCoreGraphicsFallback {
            guard let desktopSize else { return }
            coreGraphicsFallbackView.update(
                framebuffer: framebuffer,
                size: desktopSize,
                scalingMode: scalingMode
            )
            return
        }
        requestPresentation()
    }

    func deactivateInputHandling() {
        enhancedCaptureController.uninstall()
        guard localKeyMonitor != nil || !inputObservers.isEmpty else {
            publishShortcutCaptureStatus(.inactive)
            return
        }
        releaseAllRemoteInput()
        removeInputObservers()
        publishShortcutCaptureStatus(.inactive)
    }

    func setKeyboardCaptureEnabled(_ enabled: Bool) {
        guard keyboardCaptureEnabled != enabled else {
            updateShortcutCaptureStatus()
            return
        }
        if !enabled {
            releaseAllRemoteInput()
        } else {
            shortcutRouter.resetTransientState()
        }
        keyboardCaptureEnabled = enabled
        updateEnhancedCaptureScope()
    }

    func releaseAllRemoteInput() {
        verticalWheelRemainder = 0
        horizontalWheelRemainder = 0
        for keyCode in deferredCommandKeyCodes {
            if let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) {
                suppressedModifierTransitions.insert(scanCode)
            }
        }
        pressedCommandKeyCodes.removeAll(keepingCapacity: true)
        deferredCommandKeyCodes.removeAll(keepingCapacity: true)
        suppressedModifierTransitions.formUnion(
            remoteInputState.pressedScanCodes.intersection(WindowsScanCode.modifiers)
        )
        shortcutRouter.resetTransientState()
        releaseAllRequestCount += 1
        emitInput(remoteInputState.releaseAll())
    }

    private func handleShortcutKeyDown(_ event: NSEvent) -> Bool {
        guard keyboardCaptureEnabled else { return false }
        switch shortcutRouter.routeKeyDown(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            isFullScreen: window?.styleMask.contains(.fullScreen) == true
        ) {
        case .passThrough:
            return false
        case let .captured(_, remoteCommands):
            releasePhysicalModifiersForSemanticShortcut()
            for command in remoteCommands {
                emitInput(command)
            }
            return true
        case .releaseCapture:
            setKeyboardCaptureEnabled(false)
            return true
        }
    }

    private func releasePhysicalModifiersForSemanticShortcut() {
        for keyCode in deferredCommandKeyCodes {
            if let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) {
                suppressedModifierTransitions.insert(scanCode)
            }
        }
        deferredCommandKeyCodes.removeAll(keepingCapacity: true)
        for released in remoteInputState.releasePressedModifiers() {
            suppressedModifierTransitions.insert(released.scanCode)
            emitInput(released.command)
        }
    }

    private static func isCommandKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 54 || keyCode == 55
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 54, 55: .command
        default: nil
        }
    }

    private func reconcileRemoteModifiers(with modifierFlags: NSEvent.ModifierFlags) {
        for released in remoteInputState.releaseStaleModifiers(
            notPresentIn: modifierFlags
        ) {
            suppressedModifierTransitions.insert(released.scanCode)
            emitInput(released.command)
        }
    }

    private func handleCommandFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let scanCode = MacKeyCodeMapper.scanCode(for: keyCode) else { return }

        let isDown = modifierFlags.contains(.command) &&
            !pressedCommandKeyCodes.contains(keyCode)
        if isDown {
            suppressedModifierTransitions.remove(scanCode)
            pressedCommandKeyCodes.insert(keyCode)
            if keyboardCaptureEnabled {
                deferredCommandKeyCodes.insert(keyCode)
            }
            return
        }

        pressedCommandKeyCodes.remove(keyCode)
        if suppressedModifierTransitions.remove(scanCode) != nil {
            deferredCommandKeyCodes.remove(keyCode)
            return
        }
        guard keyboardCaptureEnabled else {
            deferredCommandKeyCodes.remove(keyCode)
            return
        }

        if deferredCommandKeyCodes.remove(keyCode) != nil {
            if let down = remoteInputState.modifierCommand(keyCode: keyCode) {
                emitInput(down)
            }
            if let up = remoteInputState.modifierCommand(keyCode: keyCode) {
                emitInput(up)
            }
            return
        }
        if let command = remoteInputState.modifierCommand(keyCode: keyCode) {
            emitInput(command)
        }
    }

    private func flushDeferredCommandModifiers() {
        for keyCode in deferredCommandKeyCodes.sorted() {
            deferredCommandKeyCodes.remove(keyCode)
            if let command = remoteInputState.modifierCommand(keyCode: keyCode) {
                emitInput(command)
            }
        }
    }

    private func processLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.firstResponder === self else {
            return event
        }
        if ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            return event
        }
        return handleCapturedLocalKeyEvent(event) ? nil : event
    }

    func handleCapturedLocalKeyEvent(_ event: NSEvent) -> Bool {
        guard keyboardCaptureEnabled else { return false }
        switch event.type {
        case .keyDown:
            reconcileRemoteModifiers(with: event.modifierFlags)
            if handleShortcutKeyDown(event) {
                return true
            }
            guard MacKeyCodeMapper.scanCode(for: event.keyCode) != nil else {
                return false
            }
            flushDeferredCommandModifiers()
            if let command = remoteInputState.keyCommand(
                keyCode: event.keyCode,
                down: true,
                repeatKey: event.isARepeat
            ) {
                emitInput(command)
            }
            return true
        case .keyUp:
            if shortcutRouter.shouldSuppressKeyUp(keyCode: event.keyCode) {
                return true
            }
            guard MacKeyCodeMapper.scanCode(for: event.keyCode) != nil else {
                return false
            }
            if let command = remoteInputState.keyCommand(
                keyCode: event.keyCode,
                down: false,
                repeatKey: false
            ) {
                emitInput(command)
            }
            return true
        default:
            return false
        }
    }

    private func processEnhancedKeyEvent(_ event: EnhancedKeyEvent) -> Bool {
        guard enhancedCaptureController.isInstalled else { return false }
        guard event.isMappablePhysicalInput else { return false }
        if ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            return false
        }
        enhancedKeyEventQueue.append(event)
        scheduleEnhancedKeyEventDrain()
        return event.type != .flagsChanged
    }

    private func scheduleEnhancedKeyEventDrain() {
        guard !enhancedKeyEventDrainScheduled else { return }
        enhancedKeyEventDrainScheduled = true
        Task { @MainActor [weak self] in
            self?.drainEnhancedKeyEvents()
        }
    }

    private func drainEnhancedKeyEvents() {
        enhancedKeyEventDrainScheduled = false
        guard enhancedCaptureController.isInstalled, sessionIsConnected else {
            enhancedKeyEventQueue.removeAll(keepingCapacity: true)
            return
        }
        let events = enhancedKeyEventQueue
        enhancedKeyEventQueue.removeAll(keepingCapacity: true)
        for event in events {
            handleEnhancedKeyEvent(event)
        }
        if !enhancedKeyEventQueue.isEmpty {
            scheduleEnhancedKeyEventDrain()
        }
    }

    private func handleEnhancedKeyEvent(_ event: EnhancedKeyEvent) {
        switch event.type {
        case .keyDown:
            switch shortcutRouter.routeEnhancedKeyDown(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                isFullScreen: window?.styleMask.contains(.fullScreen) == true
            ) {
            case .passThrough:
                reconcileRemoteModifiers(with: event.modifierFlags)
                flushDeferredCommandModifiers()
                if let command = remoteInputState.keyCommand(
                    keyCode: event.keyCode,
                    down: true,
                    repeatKey: event.isRepeat
                ) {
                    emitInput(command)
                }
            case let .captured(_, commands):
                releasePhysicalModifiersForSemanticShortcut()
                commands.forEach(emitInput)
            case .releaseCapture:
                setKeyboardCaptureEnabled(false)
            }
        case .keyUp:
            if !shortcutRouter.shouldSuppressKeyUp(keyCode: event.keyCode),
               let command = remoteInputState.keyCommand(
                   keyCode: event.keyCode,
                   down: false,
                   repeatKey: false
               ) {
                emitInput(command)
            }
        case .flagsChanged:
            handlePhysicalModifierChange(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
        default:
            break
        }
    }

    private func updateEnhancedCaptureScope() {
        let scope = EnhancedCaptureScope(
            applicationIsActive: NSApp.isActive,
            sessionIsConnected: sessionIsConnected,
            canvasIsFirstResponder: window?.isKeyWindow == true && window?.firstResponder === self,
            userEnabled: enhancedCaptureEnabled && keyboardCaptureEnabled,
            permissionGranted: enhancedCapturePermissionGranted
        )
        let wasInstalled = enhancedCaptureController.isInstalled
        enhancedCaptureController.update(scope: scope)
        if wasInstalled && !enhancedCaptureController.isInstalled {
            releaseAllRemoteInput()
        }
        updateShortcutCaptureStatus()
    }

    private func handleEnhancedCaptureRuntimeState(_ state: EnhancedCaptureRuntimeState) {
        if state == .degraded {
            enhancedKeyEventQueue.removeAll(keepingCapacity: true)
            releaseAllRemoteInput()
        }
        updateShortcutCaptureStatus()
    }

    private func updateShortcutCaptureStatus() {
        let next: ShortcutCaptureStatus
        if !keyboardCaptureEnabled {
            next = .released
        } else if enhancedCaptureController.runtimeState == .degraded {
            next = .degraded
        } else if enhancedCaptureController.isInstalled {
            next = .enhanced
        } else if window?.firstResponder === self {
            next = .basic
        } else {
            next = .inactive
        }
        publishShortcutCaptureStatus(next)
    }

    private func publishShortcutCaptureStatus(_ status: ShortcutCaptureStatus) {
        guard shortcutCaptureStatus != status else { return }
        shortcutCaptureStatus = status
        onShortcutCaptureStatusChange?(status)
    }

    private func emitInput(_ command: RemoteInputCommand) {
        onInput?(command)
    }

    private func requestDynamicResolutionUpdate(force: Bool = false) {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard let target = DynamicResolutionPolicy.targetSize(
            canvasSize: bounds.size,
            backingScale: backingScale
        ),
              force || target != lastRequestedDynamicResolution else {
            return
        }
        lastRequestedDynamicResolution = target
        onViewportResize?(target)
    }

    private func viewportGeometry() -> RemoteViewportGeometry? {
        guard let desktopSize else { return nil }
        return RemoteViewportGeometry(
            desktopSize: desktopSize,
            canvasSize: bounds.size,
            backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            scalingMode: scalingMode
        )
    }

    private func remotePosition(for event: NSEvent) -> RemotePointerPosition? {
        viewportGeometry()?.remotePosition(for: convert(event.locationInWindow, from: nil))
    }

    private func sendPointerMove(_ event: NSEvent) {
        guard let position = remotePosition(for: event) else { return }
        emitInput(.pointerMove(position))
    }

    private func sendPointerButton(
        _ button: RemotePointerButton,
        down: Bool,
        event: NSEvent
    ) {
        guard let position = remotePosition(for: event),
              let command = remoteInputState.buttonCommand(
                button,
                down: down,
                position: position
              ) else { return }
        emitInput(command)
    }

    private func remoteButton(for buttonNumber: Int) -> RemotePointerButton? {
        switch buttonNumber {
        case 2: .middle
        case 3: .x1
        case 4: .x2
        default: nil
        }
    }

    private func flushWheelRemainder(
        _ remainder: inout CGFloat,
        horizontal: Bool,
        position: RemotePointerPosition
    ) {
        while abs(remainder) >= 1 {
            let integral = Int(remainder.rounded(.towardZero))
            let chunk = max(-255, min(255, integral))
            guard let delta = Int16(exactly: chunk) else { return }
            emitInput(.wheel(delta: delta, horizontal: horizontal, position: position))
            remainder -= CGFloat(chunk)
        }
    }

    private func installInputObservers() {
        guard let window else {
            removeInputObservers()
            return
        }
        removeInputObservers()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            return self.processLocalKeyEvent(event)
        }
        let center = NotificationCenter.default
        inputObservers = [
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnhancedCaptureScope() }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnhancedCaptureScope() }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnhancedCaptureScope() }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnhancedCaptureScope() }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAllRemoteInput() }
            },
        ]
        updateShortcutCaptureStatus()
    }

    private func removeInputObservers() {
        let center = NotificationCenter.default
        for observer in inputObservers {
            center.removeObserver(observer)
        }
        inputObservers.removeAll()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        updateShortcutCaptureStatus()
    }

    private func makeCursor(from shape: RemoteCursorShape) -> NSCursor? {
        guard let provider = CGDataProvider(data: shape.pixels as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        ).union(.byteOrder32Little)
        guard let image = CGImage(
            width: shape.width,
            height: shape.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: shape.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        let cursorImage = NSImage(
            cgImage: image,
            size: NSSize(width: shape.width, height: shape.height)
        )
        return NSCursor(
            image: cursorImage,
            hotSpot: NSPoint(x: shape.hotspotX, y: shape.hotspotY)
        )
    }

    private func makeTransparentCursor() -> NSCursor {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }

    private func prepareFramebuffer(for size: RemoteDesktopSize) {
        desktopSize = size
        framebuffer = Data(repeating: 0, count: size.packedByteCount)
        remoteTexture = nil
        pendingDirtyRect = RemoteFrameRect(
            x: 0,
            y: 0,
            width: size.width,
            height: size.height,
            desktop: size
        )
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        let size = CGSize(width: width, height: height)
        if metalLayer.drawableSize != size {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = size
            requestPresentation()
        }
    }

    private func configurePresentationDisplayLink() {
        presentationDisplayLink?.invalidate()
        presentationDisplayLink = nil
        guard window != nil, !isUsingCoreGraphicsFallback else { return }

        let link = displayLink(
            target: self,
            selector: #selector(presentationDisplayLinkDidFire(_:))
        )
        link.preferredFrameRateRange = presentationRate.frameRateRange
        link.isPaused = !needsPresentation
        link.add(to: .main, forMode: .common)
        presentationDisplayLink = link
    }

    private func requestPresentation() {
        needsPresentation = true
        presentationDisplayLink?.isPaused = false
    }

    @objc private func presentationDisplayLinkDidFire(_ link: CADisplayLink) {
        guard link === presentationDisplayLink else { return }
        renderIfPossible()
    }

    private func makeTextureIfNeeded() -> MTLTexture? {
        if let remoteTexture {
            return remoteTexture
        }
        guard let device, let desktopSize else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: desktopSize.width,
            height: desktopSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)
        remoteTexture = texture
        return texture
    }

    private func renderIfPossible() {
        guard !renderInFlight,
              needsPresentation,
              let desktopSize,
              let texture = makeTextureIfNeeded(),
              let commandQueue,
              let pipelineState else {
            return
        }

        if let dirtyRect = pendingDirtyRect {
            framebuffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                let offset = dirtyRect.y * desktopSize.packedBytesPerRow + dirtyRect.x * 4
                texture.replace(
                    region: MTLRegionMake2D(
                        dirtyRect.x,
                        dirtyRect.y,
                        dirtyRect.width,
                        dirtyRect.height
                    ),
                    mipmapLevel: 0,
                    withBytes: baseAddress.advanced(by: offset),
                    bytesPerRow: desktopSize.packedBytesPerRow
                )
            }
            pendingDirtyRect = nil
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        let vertices = aspectFitVertices(
            desktopSize: desktopSize,
            drawableSize: metalLayer.drawableSize
        )
        encoder.setRenderPipelineState(pipelineState)
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        renderInFlight = true
        needsPresentation = false
        presentationDisplayLink?.isPaused = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.renderDidComplete()
            }
        }
        commandBuffer.commit()
    }

    private func renderDidComplete() {
        renderInFlight = false
        if pendingDirtyRect != nil {
            requestPresentation()
        } else {
            presentationDisplayLink?.isPaused = true
        }
    }

    func aspectFitVertices(
        desktopSize: RemoteDesktopSize,
        drawableSize: CGSize
    ) -> [Float] {
        let drawableWidth = max(1, Float(drawableSize.width))
        let drawableHeight = max(1, Float(drawableSize.height))
        let remoteAspect = Float(desktopSize.width) / Float(desktopSize.height)
        let drawableAspect = drawableWidth / drawableHeight

        let xScale: Float
        let yScale: Float
        let uMinimum: Float
        let uMaximum: Float
        let vMinimum: Float
        let vMaximum: Float
        switch scalingMode {
        case .fit:
            if remoteAspect > drawableAspect {
                xScale = 1
                yScale = drawableAspect / remoteAspect
            } else {
                xScale = remoteAspect / drawableAspect
                yScale = 1
            }
            uMinimum = 0
            uMaximum = 1
            vMinimum = 0
            vMaximum = 1
        case .actualPixels:
            let remoteWidth = Float(desktopSize.width)
            let remoteHeight = Float(desktopSize.height)
            let visibleWidth = min(remoteWidth, drawableWidth)
            let visibleHeight = min(remoteHeight, drawableHeight)
            xScale = visibleWidth / drawableWidth
            yScale = visibleHeight / drawableHeight
            let visibleU = visibleWidth / remoteWidth
            let visibleV = visibleHeight / remoteHeight
            uMinimum = (1 - visibleU) / 2
            uMaximum = 1 - uMinimum
            vMinimum = (1 - visibleV) / 2
            vMaximum = 1 - vMinimum
        }

        return [
            -xScale, yScale, uMinimum, vMinimum,
             xScale, yScale, uMaximum, vMinimum,
            -xScale, -yScale, uMinimum, vMaximum,
             xScale, yScale, uMaximum, vMinimum,
             xScale, -yScale, uMaximum, vMaximum,
            -xScale, -yScale, uMinimum, vMaximum,
        ]
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device else {
            return nil
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOutput {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex VertexOutput remoteVertex(
            const device float4 *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOutput output;
            output.position = float4(vertices[vertexID].xy, 0.0, 1.0);
            output.textureCoordinate = vertices[vertexID].zw;
            return output;
        }

        fragment float4 remoteFragment(
            VertexOutput input [[stage_in]],
            texture2d<float> remoteTexture [[texture(0)]]
        ) {
            constexpr sampler textureSampler(
                address::clamp_to_edge,
                filter::linear
            );
            return remoteTexture.sample(textureSampler, input.textureCoordinate);
        }
        """

        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertexFunction = library.makeFunction(name: "remoteVertex"),
              let fragmentFunction = library.makeFunction(name: "remoteFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
