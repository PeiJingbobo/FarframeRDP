import AppKit
import FarframeCore
import QuartzCore

enum FixedResolutionViewportPolicy {
    static func targetSize(documentSize: CGSize, availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(documentSize.width, availableSize.width),
            height: min(documentSize.height, availableSize.height)
        )
    }
}

enum RemoteDocumentAlignmentPolicy {
    static func topLeftBoundsOrigin(
        documentFrame: CGRect,
        viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: documentFrame.minX,
            y: documentFrame.maxY - viewportSize.height
        )
    }
}

enum RemoteWindowChromeMetrics {
    static let reservedTopHeight: CGFloat = 40
    static let horizontalContentInset: CGFloat = 0
    static let bottomContentInset: CGFloat = 0
    static let toolbarHeight: CGFloat = 34
    static let toolbarCanvasGap: CGFloat = 3
    static let revealZoneHeight: CGFloat = 52
    static let edgeRevealWidth: CGFloat = 12
    static let remoteCanvasCornerRadius: CGFloat = 24

    static func contentSize(forViewport viewportSize: CGSize) -> CGSize {
        CGSize(
            width: viewportSize.width + horizontalContentInset * 2,
            height: viewportSize.height + reservedTopHeight + bottomContentInset
        )
    }

    static func viewportSize(forContent contentSize: CGSize) -> CGSize {
        CGSize(
            width: max(0, contentSize.width - horizontalContentInset * 2),
            height: max(0, contentSize.height - reservedTopHeight - bottomContentInset)
        )
    }
}

struct RemoteSessionWindowIdentity: Equatable, Sendable {
    let displayName: String
    let host: String
    let port: UInt16

    var address: String {
        guard port != 3389 else { return host }
        let formattedHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        return "\(formattedHost):\(port)"
    }

    var title: String {
        "\(displayName)-\(address)"
    }
}

enum RemoteToolbarInteractionPolicy {
    static func togglesWindowZoom(clickCount: Int) -> Bool {
        clickCount == 2
    }
}

@MainActor
private final class FloatingRemoteToolbarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView is NSTextField ? self : hitView
    }

    override func mouseDown(with event: NSEvent) {
        guard RemoteToolbarInteractionPolicy.togglesWindowZoom(
            clickCount: event.clickCount
        ) else {
            if let window {
                window.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
            return
        }
        window?.zoom(nil)
    }
}

@MainActor
private final class TopLeftRemoteClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }
        let topLeftOrigin = RemoteDocumentAlignmentPolicy.topLeftBoundsOrigin(
            documentFrame: documentView.frame,
            viewportSize: constrainedBounds.size
        )
        if documentView.frame.width <= constrainedBounds.width {
            constrainedBounds.origin.x = topLeftOrigin.x
        }
        if documentView.frame.height <= constrainedBounds.height {
            constrainedBounds.origin.y = topLeftOrigin.y
        }
        return constrainedBounds
    }

    func scrollToDocumentTopLeft() {
        guard let documentView else { return }
        scroll(
            to: RemoteDocumentAlignmentPolicy.topLeftBoundsOrigin(
                documentFrame: documentView.frame,
                viewportSize: bounds.size
            )
        )
    }
}

@MainActor
final class PersistentRemoteScroller: NSScroller {
    static let persistentKnobOpacity: CGFloat = 0.9

    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = 1 }
    }

    var renderedKnobRect: NSRect {
        rect(for: .knob)
    }

    func capturesKnob(at point: NSPoint) -> Bool {
        renderedKnobRect.contains(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let knobRect = renderedKnobRect
        guard !knobRect.isEmpty else { return }
        let knobPath = NSBezierPath(
            roundedRect: knobRect,
            xRadius: min(knobRect.width, knobRect.height) / 2,
            yRadius: min(knobRect.width, knobRect.height) / 2
        )
        NSColor.white.withAlphaComponent(Self.persistentKnobOpacity).setFill()
        knobPath.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        knobPath.lineWidth = 1
        knobPath.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let localPoint = convert(point, from: superview)
        return capturesKnob(at: localPoint) ? self : nil
    }
}

@MainActor
final class PersistentRemoteScrollView: NSScrollView {
    private let persistentHorizontalScroller = PersistentRemoteScroller(frame: .zero)
    private let persistentVerticalScroller = PersistentRemoteScroller(frame: .zero)

    private(set) var showsPersistentHorizontalScroller = false
    private(set) var showsPersistentVerticalScroller = false

    var visiblePersistentScrollers: [PersistentRemoteScroller] {
        [persistentHorizontalScroller, persistentVerticalScroller]
            .filter { !$0.isHidden }
    }

    var persistentScrollersOverlapContentView: Bool {
        !visiblePersistentScrollers.isEmpty
            && visiblePersistentScrollers.allSatisfy {
                contentView.frame.intersects($0.frame)
            }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePersistentScrollers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePersistentScrollers()
    }

    func setPersistentScrollersVisible(horizontal: Bool, vertical: Bool) {
        showsPersistentHorizontalScroller = horizontal
        showsPersistentVerticalScroller = vertical
        hasHorizontalScroller = horizontal
        hasVerticalScroller = vertical
        autohidesScrollers = false
        tile()
        reflectScrolledClipView(contentView)
    }

    override func tile() {
        super.tile()
        // AppKit forces always-visible scrollers to the legacy style. Expand
        // the clip view beneath those native controls so they overlay the
        // remote canvas without surrendering NSScrollView's drag handling.
        contentView.frame = bounds
        if let horizontalScroller, hasHorizontalScroller {
            addSubview(horizontalScroller, positioned: .above, relativeTo: contentView)
        }
        if let verticalScroller, hasVerticalScroller {
            addSubview(verticalScroller, positioned: .above, relativeTo: contentView)
        }
    }

    private func configurePersistentScrollers() {
        contentView = TopLeftRemoteClipView()
        scrollerStyle = .legacy
        autohidesScrollers = false
        horizontalScroller = persistentHorizontalScroller
        verticalScroller = persistentVerticalScroller
        persistentHorizontalScroller.knobStyle = .light
        persistentVerticalScroller.knobStyle = .light
        hasHorizontalScroller = false
        hasVerticalScroller = false
    }
}

@MainActor
private final class RemoteSessionContainerView: NSView {
    private let floatingToolbar: NSView
    private let chromeMaterialView = NSVisualEffectView()
    private var toolbarHeightConstraint: NSLayoutConstraint!
    private var toolbarCenterYConstraint: NSLayoutConstraint!
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isFloatingToolbarVisible = false

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === chromeMaterialView ? self : hitView
    }

    override func mouseDown(with event: NSEvent) {
        guard RemoteToolbarInteractionPolicy.togglesWindowZoom(
            clickCount: event.clickCount
        ) else {
            if let window {
                window.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
            return
        }
        window?.zoom(nil)
    }

    var usesUnifiedChromeMaterial: Bool {
        chromeMaterialView.material == .titlebar
            && chromeMaterialView.blendingMode == .withinWindow
            && !(floatingToolbar is NSVisualEffectView)
    }

    var isChromeBackgroundVisible: Bool {
        chromeMaterialView.alphaValue > 0.99
    }

    var standardWindowButtonVerticalOffsets: [CGFloat] {
        let toolbarCenterInWindow = floatingToolbar.convert(
            NSPoint(x: floatingToolbar.bounds.midX, y: floatingToolbar.bounds.midY),
            to: nil
        ).y
        return standardWindowButtons.map { button in
            let buttonCenterInWindow = button.superview?.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            ).y ?? toolbarCenterInWindow
            return buttonCenterInWindow - toolbarCenterInWindow
        }
    }

    var standardWindowButtonCenterYs: [CGFloat] {
        standardWindowButtons.compactMap { button in
            button.superview?.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            ).y
        }
    }

    var titlebarElementVerticalOffsets: [CGFloat] {
        guard let referenceButton = standardWindowButtons.first,
              let referenceSuperview = referenceButton.superview else {
            return []
        }
        let referenceCenterInWindow = referenceSuperview.convert(
            NSPoint(x: referenceButton.frame.midX, y: referenceButton.frame.midY),
            to: nil
        ).y
        return floatingToolbar.subviews.map { view in
            let centerInWindow = view.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                to: nil
            ).y
            return centerInWindow - referenceCenterInWindow
        }
    }

    init(scrollView: PersistentRemoteScrollView, floatingToolbar: NSView) {
        self.floatingToolbar = floatingToolbar
        super.init(frame: scrollView.frame)

        chromeMaterialView.material = .titlebar
        chromeMaterialView.blendingMode = .withinWindow
        chromeMaterialView.state = .active
        chromeMaterialView.alphaValue = 0
        chromeMaterialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chromeMaterialView)

        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = RemoteWindowChromeMetrics.remoteCanvasCornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        floatingToolbar.translatesAutoresizingMaskIntoConstraints = false
        floatingToolbar.isHidden = true
        floatingToolbar.alphaValue = 0
        addSubview(floatingToolbar)

        toolbarHeightConstraint = floatingToolbar.heightAnchor.constraint(equalToConstant: 0)
        toolbarCenterYConstraint = floatingToolbar.centerYAnchor.constraint(
            equalTo: bottomAnchor
        )
        NSLayoutConstraint.activate([
            chromeMaterialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeMaterialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeMaterialView.topAnchor.constraint(equalTo: topAnchor),
            chromeMaterialView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RemoteWindowChromeMetrics.horizontalContentInset
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -RemoteWindowChromeMetrics.horizontalContentInset
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -RemoteWindowChromeMetrics.bottomContentInset
            ),
            scrollView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: RemoteWindowChromeMetrics.reservedTopHeight
            ),
            floatingToolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            floatingToolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarCenterYConstraint,
            toolbarHeightConstraint,
        ])

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        setFloatingToolbarVisible(false, animated: false)
        alignFloatingToolbarWithStandardWindowButtons()
    }

    override func layout() {
        super.layout()
        alignFloatingToolbarWithStandardWindowButtons()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let revealZone = bounds.maxY - RemoteWindowChromeMetrics.revealZoneHeight
        let toolbarHitArea = floatingToolbar.frame.insetBy(dx: 0, dy: -8)
        let isNearWindowEdge = location.x <= RemoteWindowChromeMetrics.edgeRevealWidth
            || location.x >= bounds.maxX - RemoteWindowChromeMetrics.edgeRevealWidth
            || location.y <= RemoteWindowChromeMetrics.edgeRevealWidth
        setFloatingToolbarVisible(
            location.y >= revealZone
                || isNearWindowEdge
                || toolbarHitArea.contains(location),
            animated: true
        )
    }

    override func mouseExited(with event: NSEvent) {
        setFloatingToolbarVisible(false, animated: true)
    }

    func setFloatingToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != isFloatingToolbarVisible || !animated else { return }
        isFloatingToolbarVisible = visible
        let targetHeight = visible ? RemoteWindowChromeMetrics.toolbarHeight : 0

        if !animated {
            toolbarHeightConstraint.constant = targetHeight
            floatingToolbar.alphaValue = visible ? 1 : 0
            floatingToolbar.isHidden = !visible
            chromeMaterialView.alphaValue = visible ? 1 : 0
            setStandardWindowButtonsVisible(visible, alpha: visible ? 1 : 0)
            window?.invalidateShadow()
            layoutSubtreeIfNeeded()
            return
        }

        if visible {
            floatingToolbar.isHidden = false
            setStandardWindowButtonsVisible(true, alpha: 0)
            window?.invalidateShadow()
        }
        layoutSubtreeIfNeeded()
        toolbarHeightConstraint.constant = targetHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.14
            context.timingFunction = CAMediaTimingFunction(
                name: visible ? .easeOut : .easeIn
            )
            context.allowsImplicitAnimation = true
            floatingToolbar.animator().alphaValue = visible ? 1 : 0
            chromeMaterialView.animator().alphaValue = visible ? 1 : 0
            for button in standardWindowButtons {
                button.animator().alphaValue = visible ? 1 : 0
            }
            layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isFloatingToolbarVisible else { return }
                floatingToolbar.isHidden = true
                setStandardWindowButtonsVisible(false, alpha: 0)
                window?.invalidateShadow()
            }
        }
    }

    private var standardWindowButtons: [NSButton] {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].compactMap { window?.standardWindowButton($0) }
    }

    private func setStandardWindowButtonsVisible(_ visible: Bool, alpha: CGFloat) {
        alignFloatingToolbarWithStandardWindowButtons()
        for button in standardWindowButtons {
            button.isHidden = !visible
            button.alphaValue = alpha
        }
    }

    private func alignFloatingToolbarWithStandardWindowButtons() {
        let targetCenterY: CGFloat
        if let referenceButton = standardWindowButtons.first,
           let referenceSuperview = referenceButton.superview {
            let centerInWindow = referenceSuperview.convert(
                NSPoint(x: referenceButton.frame.midX, y: referenceButton.frame.midY),
                to: nil
            )
            targetCenterY = convert(centerInWindow, from: nil).y
        } else {
            targetCenterY = bounds.maxY
                - RemoteWindowChromeMetrics.reservedTopHeight / 2
        }

        let targetConstant = -(targetCenterY - bounds.minY)
        guard abs(toolbarCenterYConstraint.constant - targetConstant) > 0.5 else { return }
        toolbarCenterYConstraint.constant = targetConstant
    }
}

struct ShortcutCaptureButtonAppearance: Equatable {
    let symbolName: String
    let toolTip: String
    let accessibilityLabel: String
}

extension ShortcutCaptureStatus {
    var buttonAppearance: ShortcutCaptureButtonAppearance {
        switch self {
        case .inactive:
            ShortcutCaptureButtonAppearance(
                symbolName: "keyboard",
                toolTip: String(localized: "远程画布未聚焦，macOS 快捷键在本地执行。"),
                accessibilityLabel: String(localized: "键盘捕获未启用")
            )
        case .basic:
            ShortcutCaptureButtonAppearance(
                symbolName: "keyboard.fill",
                toolTip: String(localized: "应用内快捷键捕获已启用。点按可释放。"),
                accessibilityLabel: String(localized: "应用内键盘捕获已启用")
            )
        case .enhanced:
            ShortcutCaptureButtonAppearance(
                symbolName: "keyboard.badge.ellipsis",
                toolTip: String(localized: "增强系统快捷键捕获已启用。点按可释放。"),
                accessibilityLabel: String(localized: "增强键盘捕获已启用")
            )
        case .degraded:
            ShortcutCaptureButtonAppearance(
                symbolName: "exclamationmark.triangle.fill",
                toolTip: String(localized: "增强捕获已降级为应用内捕获。移开焦点后可重试。"),
                accessibilityLabel: String(localized: "增强键盘捕获已降级")
            )
        case .released:
            ShortcutCaptureButtonAppearance(
                symbolName: "pause.circle.fill",
                toolTip: String(localized: "键盘捕获已释放。点按可恢复。"),
                accessibilityLabel: String(localized: "键盘捕获已释放")
            )
        }
    }
}

@MainActor
final class RemoteSessionWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private var remoteWindowController: NSWindowController?
    private var remoteCanvas: RemoteCanvasView?
    private var remoteScrollView: PersistentRemoteScrollView?
    private var remoteContainerView: RemoteSessionContainerView?
    private var pendingDesktopSize: RemoteDesktopSize?
    private var requestedInitialViewportAfterWindowReady = false
    private var retriedInitialViewportAfterFirstFrame = false
    private var shouldRequestViewportWhenWindowOpens = false
    private var isLiveResizingWindow = false
    private var displayActivationRetryTask: Task<Void, Never>?
    private weak var captureToolbarButton: NSButton?
    private weak var resolutionToolbarButton: NSPopUpButton?
    private weak var sessionTitleLabel: NSTextField?
    var displayActivationRetryDelay: Duration = .milliseconds(500)
    @Published private(set) var shortcutCaptureStatus: ShortcutCaptureStatus = .inactive
    var onWindowClosed: (@MainActor () -> Void)?
    var onInput: (@MainActor (RemoteInputCommand) -> Void)? {
        didSet { remoteCanvas?.onInput = onInput }
    }
    var onViewportResize: (@MainActor (RemoteDesktopSize) -> Void)?
    var onViewportLayout: (@MainActor ([RemoteMonitorLayout]) -> Void)?
    var monitorSelection: RemoteMonitorSelection = .window
    var resolution: RemoteResolutionOption = .fitWindow {
        didSet {
            guard resolution != oldValue else { return }
            applyResolutionMode(requestRemoteResolution: true)
        }
    }
    var presentationRate: RemotePresentationRate = .adaptive {
        didSet { remoteCanvas?.presentationRate = presentationRate }
    }
    var shortcutPolicies: [ShortcutPolicy] = ShortcutPolicy.defaults {
        didSet {
            remoteCanvas?.shortcutPolicies = shortcutPolicies
        }
    }
    var enhancedCaptureEnabled = false {
        didSet { remoteCanvas?.enhancedCaptureEnabled = enhancedCaptureEnabled }
    }
    var enhancedCapturePermissionGranted = false {
        didSet { remoteCanvas?.enhancedCapturePermissionGranted = enhancedCapturePermissionGranted }
    }
    var sessionIsConnected = false {
        didSet { remoteCanvas?.sessionIsConnected = sessionIsConnected }
    }
    var sessionIdentity: RemoteSessionWindowIdentity? {
        didSet {
            let title = displayedSessionTitle
            remoteWindowController?.window?.title = title
            sessionTitleLabel?.stringValue = title
        }
    }

    var displayedSessionTitle: String {
        sessionIdentity?.title ?? String(localized: "远程会话")
    }

    var hasOpenRemoteWindow: Bool {
        remoteWindowController?.window?.isVisible == true
    }

    var activePresentationRate: RemotePresentationRate? {
        remoteCanvas?.presentationRate
    }

    var supportsNativeFullScreen: Bool {
        remoteWindowController?.window?.collectionBehavior.contains(.fullScreenPrimary) == true
    }

    var isRemoteWindowResizable: Bool {
        remoteWindowController?.window?.styleMask.contains(.resizable) == true
    }

    var usesScrollableRemoteCanvas: Bool {
        remoteScrollView != nil
    }

    var usesOverlayRemoteScrollers: Bool {
        remoteScrollView?.persistentScrollersOverlapContentView == true
    }

    var remoteViewportBackgroundIsTransparent: Bool {
        guard let scrollView = remoteScrollView else { return false }
        return !scrollView.drawsBackground && scrollView.backgroundColor == .clear
    }

    var isFloatingToolbarVisible: Bool {
        remoteContainerView?.isFloatingToolbarVisible == true
    }

    var usesImmersiveWindowChrome: Bool {
        guard let window = remoteWindowController?.window else { return false }
        return window.styleMask.contains(.fullSizeContentView)
            && window.titleVisibility == .hidden
            && window.titlebarAppearsTransparent
            && window.toolbar == nil
    }

    var standardWindowButtonsAreHidden: Bool {
        guard let window = remoteWindowController?.window else { return false }
        return [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].allSatisfy { window.standardWindowButton($0)?.isHidden == true }
    }

    var isRemoteWindowLiveResizing: Bool {
        isLiveResizingWindow
    }

    var usesUnifiedWindowChromeMaterial: Bool {
        remoteContainerView?.usesUnifiedChromeMaterial == true
    }

    var isWindowChromeBackgroundVisible: Bool {
        remoteContainerView?.isChromeBackgroundVisible == true
    }

    var hasNativeWindowShadow: Bool {
        remoteWindowController?.window?.hasShadow == true
    }

    var usesDefaultOuterWindowCornerStyle: Bool {
        guard let container = remoteContainerView else { return false }
        return (container.layer?.cornerRadius ?? 0) == 0
            && container.layer?.masksToBounds != true
    }

    var remoteCanvasCornerRadius: CGFloat? {
        remoteScrollView?.layer?.cornerRadius
    }

    var standardWindowButtonVerticalOffsets: [CGFloat] {
        remoteContainerView?.standardWindowButtonVerticalOffsets ?? []
    }

    var standardWindowButtonCenterYs: [CGFloat] {
        remoteContainerView?.standardWindowButtonCenterYs ?? []
    }

    var titlebarElementVerticalOffsets: [CGFloat] {
        remoteContainerView?.titlebarElementVerticalOffsets ?? []
    }

    var remoteWindowTitle: String? {
        remoteWindowController?.window?.title
    }

    var displayedToolbarTitle: String? {
        sessionTitleLabel?.stringValue
    }

    var remoteCanvasSize: CGSize? {
        remoteCanvas?.frame.size
    }

    var remoteViewportSize: CGSize? {
        remoteScrollView?.contentSize
    }

    var remoteViewportBounds: CGRect? {
        remoteScrollView?.contentView.bounds
    }

    func resizeRemoteWindow(to contentSize: CGSize) {
        guard contentSize.width > 0,
              contentSize.height > 0,
              let window = remoteWindowController?.window else { return }
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        layoutCanvasForResolution()
    }

    func setFloatingToolbarVisible(_ visible: Bool) {
        remoteContainerView?.setFloatingToolbarVisible(visible, animated: false)
    }

    var hasHorizontalRemoteScroller: Bool {
        remoteScrollView?.showsPersistentHorizontalScroller == true
    }

    var hasVerticalRemoteScroller: Bool {
        remoteScrollView?.showsPersistentVerticalScroller == true
    }

    var horizontalRemoteScrollerKnobProportion: CGFloat? {
        remoteScrollView?.horizontalScroller?.knobProportion
    }

    var verticalRemoteScrollerKnobProportion: CGFloat? {
        remoteScrollView?.verticalScroller?.knobProportion
    }

    var remoteScrollerAlphaValues: [CGFloat] {
        remoteScrollView?.visiblePersistentScrollers.map(\.alphaValue) ?? []
    }

    var usesPersistentRemoteScrollers: Bool {
        guard let scrollView = remoteScrollView else { return false }
        return scrollView.horizontalScroller is PersistentRemoteScroller
            && scrollView.verticalScroller is PersistentRemoteScroller
    }

    var remoteScrollersAreManagedByScrollView: Bool {
        guard let scrollView = remoteScrollView,
              let horizontalScroller = scrollView.horizontalScroller,
              let verticalScroller = scrollView.verticalScroller else { return false }
        return horizontalScroller.superview === scrollView
            && verticalScroller.superview === scrollView
    }

    var usesNativeRemoteScrollers: Bool {
        guard let scrollbars = remoteScrollView?.visiblePersistentScrollers,
              !scrollbars.isEmpty else { return false }
        return scrollbars.allSatisfy {
            $0.scrollerStyle == .legacy && $0.knobStyle == .light
        }
    }

    var remoteScrollerFrames: [CGRect] {
        remoteScrollView?.visiblePersistentScrollers.map(\.frame) ?? []
    }

    var remoteScrollersOverlapCanvasViewport: Bool {
        remoteScrollView?.persistentScrollersOverlapContentView == true
    }

    var remoteScrollerKnobRects: [CGRect] {
        remoteScrollView?.visiblePersistentScrollers.map(\.renderedKnobRect) ?? []
    }

    var remoteScrollersHaveNativeActions: Bool {
        guard let scrollbars = remoteScrollView?.visiblePersistentScrollers,
              !scrollbars.isEmpty else { return false }
        return scrollbars.allSatisfy {
            $0.isEnabled && $0.target != nil && $0.action != nil
        }
    }

    func openRemoteWindow() {
        if let window = remoteWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(remoteCanvas)
            return
        }

        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640))
        canvas.presentationRate = presentationRate
        canvas.shortcutPolicies = shortcutPolicies
        canvas.enhancedCaptureEnabled = enhancedCaptureEnabled
        canvas.enhancedCapturePermissionGranted = enhancedCapturePermissionGranted
        canvas.sessionIsConnected = sessionIsConnected
        canvas.onInput = onInput
        canvas.onViewportResize = { [weak self] size in
            guard let self,
                  resolution == .fitWindow,
                  !isLiveResizingWindow else { return }
            handleViewportResize(size)
        }
        canvas.onShortcutCaptureStatusChange = { [weak self] status in
            guard let self else { return }
            shortcutCaptureStatus = status
            updateCaptureToolbarButton()
        }
        remoteCanvas = canvas
        if let pendingDesktopSize {
            canvas.announceDesktopSize(pendingDesktopSize)
        }
        let scrollView = PersistentRemoteScrollView(frame: canvas.frame)
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.documentView = canvas
        remoteScrollView = scrollView

        let floatingToolbar = makeFloatingToolbar()
        let container = RemoteSessionContainerView(
            scrollView: scrollView,
            floatingToolbar: floatingToolbar
        )
        remoteContainerView = container

        let initialContentSize = RemoteWindowChromeMetrics.contentSize(
            forViewport: canvas.frame.size
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = displayedSessionTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = container
        window.center()
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("FarframeRemoteSessionWindow")

        let controller = NSWindowController(window: window)
        remoteWindowController = controller
        applyResolutionMode(requestRemoteResolution: false)
        controller.showWindow(nil)
        window.makeFirstResponder(canvas)
        if shouldRequestViewportWhenWindowOpens {
            requestCurrentViewportResolution()
        }
        FarframeLog.logger(for: .session).info("Remote session window opened")
    }

    func announceDesktopSize(_ size: RemoteDesktopSize) {
        pendingDesktopSize = size
        remoteCanvas?.announceDesktopSize(size)
    }

    func display(
        desktopSize: RemoteDesktopSize,
        dirtyRect: RemoteFrameRect,
        pixels: UnsafeRawBufferPointer,
        bytesPerRow: Int,
        sequenceNumber: UInt64
    ) {
        pendingDesktopSize = desktopSize
        remoteCanvas?.display(
            desktopSize: desktopSize,
            dirtyRect: dirtyRect,
            pixels: pixels,
            bytesPerRow: bytesPerRow,
            sequenceNumber: sequenceNumber
        )
        if remoteCanvas != nil, !retriedInitialViewportAfterFirstFrame {
            retriedInitialViewportAfterFirstFrame = true
            requestSelectedResolution(force: true)
        }
    }

    func applyCursorUpdate(_ update: RemoteCursorUpdate) {
        remoteCanvas?.applyCursorUpdate(update)
    }

    func requestCurrentViewportResolution() {
        shouldRequestViewportWhenWindowOpens = true
        guard remoteCanvas != nil else {
            FarframeLog.logger(for: .session).info(
                "Deferring initial dynamic resolution until the remote window opens"
            )
            return
        }
        remoteWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
        requestSelectedResolution(force: true)
    }

    func displayControlDidBecomeReady() {
        requestCurrentViewportResolution()
        displayActivationRetryTask?.cancel()
        let delay = displayActivationRetryDelay
        displayActivationRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, remoteCanvas != nil else { return }
            FarframeLog.logger(for: .session).info(
                "Retrying initial dynamic resolution after display activation"
            )
            requestCurrentViewportResolution()
            displayActivationRetryTask = nil
        }
    }

    private func handleViewportResize(_ size: RemoteDesktopSize) {
        onViewportResize?(size)
        if resolution.desktopSize != nil {
            let layout = RemoteMonitorLayout(
                left: 0,
                top: 0,
                width: size.width,
                height: size.height,
                desktopScaleFactor: 100,
                deviceScaleFactor: 100,
                primary: true
            ).map { [$0] }
            if let layout {
                onViewportLayout?(layout)
            }
            return
        }
        let backingScale = remoteWindowController?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        guard let layout = RemoteMonitorLayoutPolicy.targetLayout(
            selection: monitorSelection,
            canvasSize: remoteCanvas?.bounds.size ?? CGSize(
                width: CGFloat(size.width) / backingScale,
                height: CGFloat(size.height) / backingScale
            ),
            backingScale: backingScale,
            windowScreen: remoteWindowController?.window?.screen
        ) else {
            return
        }
        onViewportLayout?(layout)
    }

    func closeRemoteWindow() {
        remoteWindowController?.window?.close()
    }

    private func makeFloatingToolbar() -> NSView {
        let toolbar = FloatingRemoteToolbarView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.clear.cgColor

        let title = NSTextField(labelWithString: displayedSessionTitle)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionTitleLabel = title

        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(toggleKeyboardCapture))
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        captureToolbarButton = button

        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        for (index, option) in RemoteResolutionOption.allCases.enumerated() {
            control.addItem(withTitle: option.title)
            control.item(at: index)?.tag = index
        }
        control.selectItem(at: RemoteResolutionOption.allCases.firstIndex(of: resolution) ?? 0)
        control.target = self
        control.action = #selector(resolutionChanged(_:))
        control.toolTip = String(localized: "快速选择远程桌面分辨率")
        control.controlSize = .mini
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        resolutionToolbarButton = control

        let actions = NSStackView(views: [button, control])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(title)
        toolbar.addSubview(actions)
        let centeredTitle = title.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor)
        centeredTitle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centeredTitle,
            title.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: toolbar.leadingAnchor, constant: 92),
            title.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        updateCaptureToolbarButton(
            displayedStatus: remoteCanvas?.shortcutCaptureStatus ?? shortcutCaptureStatus
        )
        return toolbar
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        let options = RemoteResolutionOption.allCases
        guard options.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        resolution = options[sender.indexOfSelectedItem]
        remoteWindowController?.window?.makeFirstResponder(remoteCanvas)
    }

    @objc private func toggleKeyboardCapture() {
        guard let canvas = remoteCanvas else { return }
        canvas.setKeyboardCaptureEnabled(!canvas.keyboardCaptureEnabled)
        if canvas.keyboardCaptureEnabled {
            remoteWindowController?.window?.makeFirstResponder(canvas)
        }
    }

    private func updateCaptureToolbarButton(
        displayedStatus: ShortcutCaptureStatus? = nil
    ) {
        guard let button = captureToolbarButton else { return }
        let status = displayedStatus ?? shortcutCaptureStatus
        let appearance = status.buttonAppearance
        button.image = NSImage(
            systemSymbolName: appearance.symbolName,
            accessibilityDescription: appearance.accessibilityLabel
        ) ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: appearance.accessibilityLabel)
        button.toolTip = appearance.toolTip
        button.setAccessibilityLabel(appearance.accessibilityLabel)

        switch status {
        case .inactive:
            button.contentTintColor = .secondaryLabelColor
        case .basic:
            button.contentTintColor = .controlAccentColor
        case .enhanced:
            button.contentTintColor = .systemPurple
        case .degraded:
            button.contentTintColor = .systemOrange
        case .released:
            button.contentTintColor = .systemYellow
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else {
            return
        }
        remoteCanvas?.deactivateInputHandling()
        remoteCanvas?.onInput = nil
        remoteCanvas?.onViewportResize = nil
        remoteCanvas?.onShortcutCaptureStatusChange = nil
        remoteWindowController = nil
        remoteCanvas = nil
        remoteScrollView = nil
        remoteContainerView = nil
        pendingDesktopSize = nil
        requestedInitialViewportAfterWindowReady = false
        retriedInitialViewportAfterFirstFrame = false
        shouldRequestViewportWhenWindowOpens = false
        isLiveResizingWindow = false
        displayActivationRetryTask?.cancel()
        displayActivationRetryTask = nil
        captureToolbarButton = nil
        resolutionToolbarButton = nil
        sessionTitleLabel = nil
        shortcutCaptureStatus = .inactive
        FarframeLog.logger(for: .session).info("Remote session window closed")
        onWindowClosed?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window,
              !requestedInitialViewportAfterWindowReady else {
            return
        }
        requestedInitialViewportAfterWindowReady = true
        remoteWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
        requestSelectedResolution(force: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else { return }
        layoutCanvasForResolution()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else { return }
        beginRemoteWindowLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else { return }
        finishRemoteWindowLiveResize()
    }

    func beginRemoteWindowLiveResize() {
        isLiveResizingWindow = true
    }

    func finishRemoteWindowLiveResize() {
        guard isLiveResizingWindow else { return }
        isLiveResizingWindow = false
        layoutCanvasForResolution()
        guard resolution == .fitWindow else { return }
        requestSelectedResolution(force: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else { return }
        remoteScrollView?.layer?.cornerRadius = 0
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === remoteWindowController?.window else { return }
        remoteScrollView?.layer?.cornerRadius = RemoteWindowChromeMetrics.remoteCanvasCornerRadius
    }

    private func applyResolutionMode(requestRemoteResolution: Bool) {
        guard let window = remoteWindowController?.window else { return }
        window.styleMask.insert(.resizable)
        if resolution == .fitWindow {
            window.collectionBehavior.insert(.fullScreenPrimary)
        } else {
            window.collectionBehavior.remove(.fullScreenPrimary)
        }
        layoutCanvasForResolution(resizeWindow: resolution != .fitWindow)
        resolutionToolbarButton?.selectItem(
            at: RemoteResolutionOption.allCases.firstIndex(of: resolution) ?? 0
        )
        if requestRemoteResolution {
            requestSelectedResolution(force: true)
        }
    }

    private func layoutCanvasForResolution(resizeWindow: Bool = false) {
        guard let canvas = remoteCanvas,
              let scrollView = remoteScrollView,
              remoteWindowController?.window != nil else { return }
        if let fixedSize = resolution.desktopSize {
            let documentSize = NSSize(
                width: CGFloat(fixedSize.width),
                height: CGFloat(fixedSize.height)
            )
            // Remove the overlay controls before measuring the viewport so a
            // resolution transition starts from one deterministic layout.
            scrollView.setPersistentScrollersVisible(horizontal: false, vertical: false)
            if resizeWindow {
                resizeWindowForFixedResolution(documentSize)
            }
            remoteWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
            canvas.autoresizingMask = []
            canvas.setFrameSize(documentSize)
            canvas.setScalingMode(.fit)
            scrollView.scrollerStyle = .legacy
            let viewportSize = scrollView.contentSize
            scrollView.setPersistentScrollersVisible(
                horizontal: documentSize.width > viewportSize.width + 0.5,
                vertical: documentSize.height > viewportSize.height + 0.5
            )
            (scrollView.contentView as? TopLeftRemoteClipView)?.scrollToDocumentTopLeft()
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.setPersistentScrollersVisible(horizontal: false, vertical: false)
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .legacy
            canvas.autoresizingMask = [.width, .height]
            canvas.setFrameSize(scrollView.contentSize)
            canvas.setScalingMode(.actualPixels)
        }
    }

    private func resizeWindowForFixedResolution(_ documentSize: NSSize) {
        guard let window = remoteWindowController?.window else { return }
        let screen = window.screen ?? NSScreen.main
        let currentContentSize = window.contentView?.frame.size ?? window.contentLayoutRect.size
        let chromeWidth = max(0, window.frame.width - currentContentSize.width)
        let chromeHeight = max(0, window.frame.height - currentContentSize.height)
        let availableViewportSize = screen.map {
            RemoteWindowChromeMetrics.viewportSize(forContent: NSSize(
                width: max(200, $0.visibleFrame.width - chromeWidth),
                height: max(200, $0.visibleFrame.height - chromeHeight)
            ))
        } ?? documentSize
        let targetViewportSize = FixedResolutionViewportPolicy.targetSize(
            documentSize: documentSize,
            availableSize: availableViewportSize
        )
        let targetContentSize = RemoteWindowChromeMetrics.contentSize(
            forViewport: targetViewportSize
        )
        window.setContentSize(targetContentSize)
        if let visibleFrame = screen?.visibleFrame, !visibleFrame.contains(window.frame) {
            var constrainedFrame = window.frame
            let maximumOriginX = max(visibleFrame.minX, visibleFrame.maxX - constrainedFrame.width)
            let maximumOriginY = max(visibleFrame.minY, visibleFrame.maxY - constrainedFrame.height)
            constrainedFrame.origin.x = min(
                max(constrainedFrame.origin.x, visibleFrame.minX),
                maximumOriginX
            )
            constrainedFrame.origin.y = min(
                max(constrainedFrame.origin.y, visibleFrame.minY),
                maximumOriginY
            )
            window.setFrame(constrainedFrame, display: true)
        }
    }

    private func requestSelectedResolution(force: Bool) {
        guard let canvas = remoteCanvas else { return }
        if let fixedSize = resolution.desktopSize {
            handleViewportResize(fixedSize)
        } else if force {
            canvas.requestInitialDynamicResolution()
        }
    }
}
