import AppKit
import Combine
import XCTest
@testable import FarframeRDP

@MainActor
final class FarframeRDPTests: XCTestCase {
    func testRemoteClipboardSessionPromptPolicySuppressesOnlyAfterAcceptedChoice() {
        var policy = RemoteClipboardFileConfirmationPolicy()

        XCTAssertTrue(policy.requiresApproval(profileRequiresApproval: true))
        policy.record(.cancel)
        XCTAssertTrue(policy.requiresApproval(profileRequiresApproval: true))

        policy.record(.confirmCopy(suppressFurtherPrompts: true))
        XCTAssertFalse(policy.requiresApproval(profileRequiresApproval: true))
        policy.reset()
        XCTAssertTrue(policy.requiresApproval(profileRequiresApproval: true))
    }

    func testRemoteClipboardDirectSaveCanSuppressLaterSessionPrompts() {
        var policy = RemoteClipboardFileConfirmationPolicy()
        policy.record(.directSave(
            .directory(URL(fileURLWithPath: "/tmp")),
            suppressFurtherPrompts: true
        ))

        XCTAssertFalse(policy.requiresApproval(profileRequiresApproval: true))
    }

    func testRemoteClipboardFileTransferWaitsForApprovalBeforeFirstRead() {
        var gate = RemoteClipboardFileTransferGate(requiresApproval: true)

        XCTAssertFalse(gate.beginTransfer())
        XCTAssertTrue(gate.resolveApproval(true))
        XCTAssertTrue(gate.beginTransfer())
        XCTAssertFalse(gate.beginTransfer())
        XCTAssertFalse(gate.resolveApproval(false))
    }

    func testRemoteClipboardFileTransferRejectsCancelledApproval() {
        var gate = RemoteClipboardFileTransferGate(requiresApproval: true)

        XCTAssertTrue(gate.resolveApproval(false))
        XCTAssertFalse(gate.beginTransfer())
    }

    func testRemoteClipboardFileTransferWithoutConfirmationCanStartOnce() {
        var gate = RemoteClipboardFileTransferGate(requiresApproval: false)

        XCTAssertTrue(gate.beginTransfer())
        XCTAssertFalse(gate.beginTransfer())
    }

    func testClipboardFileConfirmationUsesCopyLabelsAndThirtySecondTimeout() {
        let approval = ClipboardFileTransferApproval(
            direction: .windowsToMac,
            fileCount: 2,
            totalBytes: 1_024
        )

        let alert = ClipboardFileTransferConfirmationPresenter.makeAlert(for: approval)

        XCTAssertEqual(ClipboardFileTransferConfirmationPresenter.timeout, 30)
        XCTAssertEqual(alert.messageText, "允许从 Windows接收文件？")
        XCTAssertEqual(alert.buttons.map(\.title), ["确认复制", "取消"])
        XCTAssertTrue(alert.informativeText.contains("2 个普通文件"))
        XCTAssertEqual(alert.suppressionButton?.title, "本次不再询问")
        let directSaveButton = try? XCTUnwrap(alert.accessoryView as? NSButton)
        XCTAssertEqual(directSaveButton?.title, "直接保存")
        XCTAssertEqual(
            directSaveButton?.identifier,
            ClipboardFileTransferConfirmationPresenter.directSaveIdentifier
        )
    }

    func testClipboardFileConfirmationDescribesMacToWindowsDirection() {
        let approval = ClipboardFileTransferApproval(
            direction: .macToWindows,
            fileCount: 1,
            totalBytes: 0
        )

        let alert = ClipboardFileTransferConfirmationPresenter.makeAlert(for: approval)

        XCTAssertEqual(alert.messageText, "允许 mac 向 Windows 传输文件？")
        XCTAssertNil(alert.accessoryView)
        XCTAssertFalse(alert.showsSuppressionButton)
    }

    func testShortcutCaptureToolbarUsesDistinctAppearanceForEveryState() {
        let states: [ShortcutCaptureStatus] = [
            .inactive, .basic, .enhanced, .degraded, .released,
        ]
        let appearances = states.map(\.buttonAppearance)

        XCTAssertEqual(Set(appearances.map(\.symbolName)).count, states.count)
        XCTAssertEqual(Set(appearances.map(\.toolTip)).count, states.count)
        XCTAssertEqual(Set(appearances.map(\.accessibilityLabel)).count, states.count)
    }

    func testOpeningRemoteWindowDoesNotRepublishStatusDuringToolbarConstruction() {
        let manager = RemoteSessionWindowManager()
        var observedStatuses: [ShortcutCaptureStatus] = []
        let observation = manager.$shortcutCaptureStatus
            .dropFirst()
            .sink { observedStatuses.append($0) }

        manager.openRemoteWindow()

        XCTAssertEqual(observedStatuses, [.basic])
        manager.closeRemoteWindow()
        withExtendedLifetime(observation) {}
    }

    func testSettingsSidebarHasStableNonCollapsibleWidthAndDestinations() {
        XCTAssertEqual(SettingsLayout.sidebarWidth, 220)
        XCTAssertEqual(
            SettingsDestination.allCases,
            [.general, .network, .keyboard]
        )
        XCTAssertEqual(SettingsDestination.general.title, "\u{901A}\u{7528}")
        XCTAssertEqual(SettingsDestination.network.systemImage, "network")
        XCTAssertEqual(SettingsDestination.keyboard.title, "\u{952E}\u{76D8}\u{4E0E}\u{5FEB}\u{6377}\u{952E}")
    }

    func testConnectionLibraryUsesOnlyTheSystemSidebarToggle() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/FarframeRDP/ConnectionLibraryView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertFalse(source.contains("NSSplitViewController.toggleSidebar"))
    }

    func testApplicationTerminatesAfterLastWindowCloses() {
        let delegate = FarframeApplicationDelegate()

        XCTAssertTrue(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        )
    }

    func testSimplifiedChineseIsTheDevelopmentLocalization() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "zh-Hans")
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"))
        XCTAssertEqual(String(localized: "就绪"), "就绪")
        XCTAssertEqual(
            ShortcutPolicy.defaults.first { $0.id == "copy" }?.displayName,
            "复制"
        )
        XCTAssertEqual(ShortcutCaptureScope.both.displayName, "窗口和全屏模式")
    }

    func testApplicationDeclaresMicrophonePrivacyUsage() {
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String

        XCTAssertEqual(
            usage,
            "启用麦克风重定向时，Farframe RDP 需要访问麦克风并将音频输入发送到当前远程会话。"
        )
    }

    func testMicrophoneDeviceMenuKeepsDefaultAndUnavailableSavedSelection() {
        let options = MicrophoneDeviceMenuOption.options(
            availableDevices: [
                MicrophoneInputDevice(name: "Studio Mic", isDefault: false),
                MicrophoneInputDevice(name: "Built-in Microphone", isDefault: true),
                MicrophoneInputDevice(name: "Studio Mic", isDefault: false)
            ],
            savedSelection: "Desk Interface"
        )

        XCTAssertEqual(options.map(\.value), ["", "Studio Mic", "Built-in Microphone", "Desk Interface"])
        XCTAssertEqual(options[0].title, "默认输入设备")
        XCTAssertEqual(options[2].title, "Built-in Microphone（当前默认）")
        XCTAssertEqual(options[3].title, "Desk Interface（当前不可用）")
    }

    func testMicrophoneDeviceResolutionFallsBackToDefaultWhenUnavailable() {
        let availableDevices = [
            MicrophoneInputDevice(name: "Studio Mic", isDefault: false),
            MicrophoneInputDevice(name: "Built-in Microphone", isDefault: true)
        ]

        XCTAssertEqual(
            MicrophoneDeviceMenuOption.resolvedDeviceName(
                savedSelection: "Studio Mic",
                availableDevices: availableDevices
            ),
            "Studio Mic"
        )
        XCTAssertEqual(
            MicrophoneDeviceMenuOption.resolvedDeviceName(
                savedSelection: "Desk Interface",
                availableDevices: availableDevices
            ),
            ""
        )
        XCTAssertEqual(
            MicrophoneDeviceMenuOption.resolvedDeviceName(
                savedSelection: "",
                availableDevices: availableDevices
            ),
            ""
        )
    }

    func testFreeRDPVersionIsAvailableThroughBridge() {
        XCTAssertEqual(NativeRuntime.freeRDPVersion, "3.30.0")
    }

    func testClipboardTextPolicyRejectsOversizedText() {
        XCTAssertEqual(ClipboardTextPolicy.acceptedText("hello 中文"), "hello 中文")
        XCTAssertNotNil(ClipboardTextPolicy.acceptedText(String(repeating: "a", count: 1_048_576)))
        XCTAssertNil(ClipboardTextPolicy.acceptedText(String(repeating: "a", count: 1_048_577)))
        XCTAssertNotNil(ClipboardTextPolicy.acceptedText(String(repeating: "😀", count: 262_144)))
        XCTAssertNil(ClipboardTextPolicy.acceptedText(String(repeating: "😀", count: 262_145)))
        XCTAssertNil(ClipboardTextPolicy.acceptedText(nil))
    }

    func testClipboardWireTextIsExplicitLittleEndianAndNullTerminated() throws {
        let data = try XCTUnwrap(ClipboardTextPolicy.encodeWireText("A中😀"))

        XCTAssertEqual(data.suffix(2), Data([0, 0]))
        XCTAssertEqual(ClipboardTextPolicy.decodeWireText(data), "A中😀")
        XCTAssertNil(ClipboardTextPolicy.decodeWireText(Data([0x41, 0x00])))
        XCTAssertNil(ClipboardTextPolicy.decodeWireText(Data([0x41, 0x00, 0x00])))
    }

    func testClipboardHTMLCodecRoundTripsUTF8ByteOffsets() throws {
        let fragment = Data("<p><b>你好</b> — clipboard</p>".utf8)
        let encoded = try XCTUnwrap(ClipboardHTMLCodec.encode(fragment: fragment))

        XCTAssertEqual(ClipboardHTMLCodec.decode(encoded), fragment)
        XCTAssertLessThanOrEqual(encoded.count, ClipboardTransferPolicy.maximumRichTextBytes)
    }

    func testClipboardHTMLCodecRejectsMalformedOffsetsAndFallsBackToMarkers() throws {
        let malformed = Data(
            "Version:1.0\r\nStartHTML:0000000010\r\nEndHTML:9999999999\r\n".utf8
        )
        XCTAssertNil(ClipboardHTMLCodec.decode(malformed))

        let marked = Data("<html><!--StartFragment-->ok<!--EndFragment--></html>".utf8)
        XCTAssertEqual(ClipboardHTMLCodec.decode(marked), Data("ok".utf8))
    }

    func testClipboardDIBV5RoundTripPreservesDimensions() throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 12,
            bitsPerPixel: 32
        )
        let representation = try XCTUnwrap(bitmap)
        representation.setColor(.systemRed, atX: 0, y: 0)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let dib = try XCTUnwrap(ClipboardDIBCodec.encodeV5(imageData: png))
        let decoded = try XCTUnwrap(ClipboardDIBCodec.decode(dib))
        let decodedBitmap = try XCTUnwrap(NSBitmapImageRep(data: decoded.png))

        XCTAssertEqual(decodedBitmap.pixelsWide, 3)
        XCTAssertEqual(decodedBitmap.pixelsHigh, 2)
    }

    func testClipboardPNGRoundTripPreservesDimensionsAndRejectsMislabeledData() throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16,
            bitsPerPixel: 32
        )
        let representation = try XCTUnwrap(bitmap)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(ClipboardPNGCodec.decode(png))
        let decodedBitmap = try XCTUnwrap(NSBitmapImageRep(data: decoded.png))

        XCTAssertEqual(decodedBitmap.pixelsWide, 4)
        XCTAssertEqual(decodedBitmap.pixelsHigh, 3)
        XCTAssertNil(ClipboardPNGCodec.decode(Data("not a png".utf8)))
    }

    func testClipboardDIBRejectsOversizedDimensionsBeforeAllocatingPixels() {
        var header = Data(count: 40)
        header[0] = 40
        header[4] = 1
        header[6] = 1 // 65,537 pixels wide in little endian.
        header[8] = 1
        header[12] = 1
        header[14] = 32

        XCTAssertNil(ClipboardDIBCodec.decode(header))
    }

    func testLegacyRedirectOptionsRemainTextOnly() throws {
        let legacy = Data(#"{"clipboardText":true,"audioPlayback":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileRedirectOptions.self, from: legacy)

        XCTAssertTrue(decoded.clipboardEnabled)
        XCTAssertTrue(decoded.clipboardText)
        XCTAssertFalse(decoded.clipboardFormattedText)
        XCTAssertFalse(decoded.clipboardImages)
        XCTAssertFalse(decoded.clipboardFiles)
        XCTAssertEqual(decoded.clipboardDirection, .bidirectional)
        XCTAssertTrue(decoded.confirmClipboardFiles)
    }

    func testDisabledLegacyClipboardKeepsMasterSwitchOff() throws {
        let legacy = Data(#"{"clipboardText":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileRedirectOptions.self, from: legacy)

        XCTAssertFalse(decoded.clipboardEnabled)
        XCTAssertFalse(decoded.clipboardText)
    }

    func testClipboardFileListRoundTripsBoundedBasenamesAndMetadata() throws {
        let files = [
            ClipboardLocalFileSnapshot(
                url: URL(fileURLWithPath: "/unlogged/location/报告.txt"),
                name: "报告.txt",
                size: 42,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                deviceID: 1,
                inode: 2
            ),
            ClipboardLocalFileSnapshot(
                url: URL(fileURLWithPath: "/unlogged/location/photo.png"),
                name: "photo.png",
                size: 1_024,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
                deviceID: 1,
                inode: 3
            ),
        ]
        let encoded = try XCTUnwrap(ClipboardFileListCodec.encode(files))
        let decoded = try XCTUnwrap(ClipboardFileListCodec.decode(encoded))

        XCTAssertEqual(decoded.map(\.name), ["报告.txt", "photo.png"])
        XCTAssertEqual(decoded.map(\.size), [42, 1_024])
        XCTAssertEqual(encoded.count, 4 + 2 * ClipboardFilePolicy.descriptorSize)
    }

    func testClipboardFilePolicyRejectsPathsReservedNamesAndUnsafeTypes() {
        XCTAssertNil(ClipboardFilePolicy.acceptedName("../secret.txt"))
        XCTAssertNil(ClipboardFilePolicy.acceptedName("folder\\secret.txt"))
        XCTAssertNil(ClipboardFilePolicy.acceptedName("CON.txt"))
        XCTAssertNil(ClipboardFilePolicy.acceptedName("trailing. "))
        XCTAssertEqual(ClipboardFilePolicy.acceptedName("normal 文件.txt"), "normal 文件.txt")
    }

    func testClipboardFileListRejectsDirectoryAndDuplicateNames() throws {
        let file = ClipboardLocalFileSnapshot(
            url: URL(fileURLWithPath: "/unlogged/a.txt"),
            name: "a.txt",
            size: 1,
            modificationDate: .now,
            deviceID: 1,
            inode: 1
        )
        XCTAssertNil(ClipboardFileListCodec.encode([
            file,
            ClipboardLocalFileSnapshot(
                url: URL(fileURLWithPath: "/unlogged/A.TXT"),
                name: "A.TXT",
                size: 1,
                modificationDate: .now,
                deviceID: 1,
                inode: 2
            ),
        ]))

        var encoded = try XCTUnwrap(ClipboardFileListCodec.encode([file]))
        encoded[4 + 36] = 0x10 // FILE_ATTRIBUTE_DIRECTORY
        XCTAssertNil(ClipboardFileListCodec.decode(encoded))
    }

    func testRemoteCanvasAcceptsFirstResponder() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))

        XCTAssertTrue(canvas.acceptsFirstResponder)
    }

    func testRemoteWindowCanOpenAndClose() async throws {
        let manager = RemoteSessionWindowManager()
        manager.displayActivationRetryDelay = .milliseconds(10)
        var closeNotifications = 0
        var viewportRequests: [RemoteDesktopSize] = []
        manager.onWindowClosed = {
            closeNotifications += 1
        }
        manager.onViewportResize = {
            viewportRequests.append($0)
        }

        manager.displayControlDidBecomeReady()
        XCTAssertTrue(viewportRequests.isEmpty)

        manager.openRemoteWindow()
        XCTAssertTrue(manager.hasOpenRemoteWindow)
        XCTAssertEqual(manager.activePresentationRate, .adaptive)
        XCTAssertTrue(manager.supportsNativeFullScreen)
        XCTAssertTrue(manager.usesScrollableRemoteCanvas)
        XCTAssertFalse(manager.usesOverlayRemoteScrollers)
        XCTAssertTrue(manager.remoteViewportBackgroundIsTransparent)
        XCTAssertTrue(manager.usesImmersiveWindowChrome)
        XCTAssertTrue(manager.usesUnifiedWindowChromeMaterial)
        XCTAssertTrue(manager.usesDefaultOuterWindowCornerStyle)
        XCTAssertEqual(
            manager.remoteCanvasCornerRadius,
            RemoteWindowChromeMetrics.remoteCanvasCornerRadius
        )
        XCTAssertTrue(manager.isRemoteWindowResizable)
        XCTAssertFalse(manager.isFloatingToolbarVisible)
        XCTAssertFalse(manager.isWindowChromeBackgroundVisible)
        XCTAssertTrue(manager.hasNativeWindowShadow)
        XCTAssertTrue(manager.standardWindowButtonsAreHidden)
        let hiddenToolbarViewport = try XCTUnwrap(manager.remoteViewportSize)
        let hiddenToolbarCanvas = try XCTUnwrap(manager.remoteCanvasSize)
        let requestCountBeforeToolbarReveal = viewportRequests.count
        manager.setFloatingToolbarVisible(true)
        XCTAssertTrue(manager.isFloatingToolbarVisible)
        XCTAssertTrue(manager.isWindowChromeBackgroundVisible)
        XCTAssertTrue(manager.hasNativeWindowShadow)
        XCTAssertFalse(manager.standardWindowButtonsAreHidden)
        XCTAssertEqual(manager.standardWindowButtonVerticalOffsets.count, 3)
        XCTAssertTrue(
            manager.standardWindowButtonVerticalOffsets.allSatisfy { abs($0) <= 0.5 }
        )
        let visibleToolbarViewport = try XCTUnwrap(manager.remoteViewportSize)
        XCTAssertEqual(visibleToolbarViewport.width, hiddenToolbarViewport.width, accuracy: 0.5)
        XCTAssertEqual(visibleToolbarViewport.height, hiddenToolbarViewport.height, accuracy: 0.5)
        XCTAssertEqual(manager.remoteCanvasSize, hiddenToolbarCanvas)
        XCTAssertEqual(viewportRequests.count, requestCountBeforeToolbarReveal)
        manager.setFloatingToolbarVisible(false)
        XCTAssertFalse(manager.isFloatingToolbarVisible)
        XCTAssertFalse(manager.isWindowChromeBackgroundVisible)
        XCTAssertTrue(manager.hasNativeWindowShadow)
        XCTAssertTrue(manager.standardWindowButtonsAreHidden)
        XCTAssertEqual(manager.remoteViewportSize, hiddenToolbarViewport)
        XCTAssertEqual(manager.remoteCanvasSize, hiddenToolbarCanvas)
        XCTAssertEqual(viewportRequests.count, requestCountBeforeToolbarReveal)
        XCTAssertEqual(manager.shortcutCaptureStatus, .basic)
        XCTAssertFalse(viewportRequests.isEmpty)
        let immediateRequestCount = viewportRequests.count
        for _ in 0..<30 where viewportRequests.count == immediateRequestCount {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(viewportRequests.count, immediateRequestCount)

        let requestCountBeforeLiveResize = viewportRequests.count
        manager.beginRemoteWindowLiveResize()
        XCTAssertTrue(manager.isRemoteWindowLiveResizing)
        manager.resizeRemoteWindow(to: CGSize(width: 900, height: 600))
        manager.resizeRemoteWindow(to: CGSize(width: 1000, height: 680))
        manager.resizeRemoteWindow(to: CGSize(width: 1100, height: 720))
        XCTAssertEqual(viewportRequests.count, requestCountBeforeLiveResize)
        manager.finishRemoteWindowLiveResize()
        XCTAssertFalse(manager.isRemoteWindowLiveResizing)
        XCTAssertEqual(viewportRequests.count, requestCountBeforeLiveResize + 1)

        manager.resolution = .size1920x1080
        XCTAssertTrue(manager.isRemoteWindowResizable)
        XCTAssertFalse(manager.supportsNativeFullScreen)
        XCTAssertEqual(viewportRequests.last, RemoteDesktopSize(width: 1920, height: 1080))
        XCTAssertEqual(manager.remoteCanvasSize, CGSize(width: 1920, height: 1080))

        manager.presentationRate = .fps30
        XCTAssertEqual(manager.activePresentationRate, .fps30)

        manager.resolution = .size1280x720
        let fixedResolutionRequestCount = viewportRequests.count
        manager.resizeRemoteWindow(to: CGSize(width: 900, height: 540))
        XCTAssertEqual(manager.remoteCanvasSize, CGSize(width: 1280, height: 720))
        XCTAssertTrue(manager.hasHorizontalRemoteScroller)
        XCTAssertTrue(manager.hasVerticalRemoteScroller)
        XCTAssertTrue(manager.usesPersistentRemoteScrollers)
        XCTAssertTrue(manager.remoteScrollersAreManagedByScrollView)
        XCTAssertTrue(manager.usesNativeRemoteScrollers)
        XCTAssertTrue(manager.remoteScrollersHaveNativeActions)
        XCTAssertTrue(manager.remoteScrollersOverlapCanvasViewport)
        XCTAssertEqual(manager.remoteScrollerAlphaValues.count, 2)
        XCTAssertTrue(manager.remoteScrollerAlphaValues.allSatisfy { $0 == 1 })
        XCTAssertEqual(manager.remoteScrollerFrames.count, 2)
        XCTAssertTrue(
            manager.remoteScrollerFrames.contains { $0.width > $0.height && !$0.isEmpty }
        )
        XCTAssertTrue(
            manager.remoteScrollerFrames.contains { $0.height > $0.width && !$0.isEmpty }
        )
        XCTAssertEqual(manager.remoteScrollerKnobRects.count, 2)
        XCTAssertTrue(
            manager.remoteScrollerKnobRects.contains { $0.width > 100 && $0.width > $0.height }
        )
        XCTAssertTrue(
            manager.remoteScrollerKnobRects.contains { $0.height > 100 && $0.height > $0.width }
        )

        manager.resizeRemoteWindow(to: CGSize(width: 1440, height: 900))
        XCTAssertEqual(manager.remoteCanvasSize, CGSize(width: 1280, height: 720))
        XCTAssertFalse(manager.hasHorizontalRemoteScroller)
        XCTAssertFalse(manager.hasVerticalRemoteScroller)
        let topAlignedViewport = try XCTUnwrap(manager.remoteViewportBounds)
        XCTAssertEqual(topAlignedViewport.minX, 0, accuracy: 0.5)
        XCTAssertEqual(topAlignedViewport.maxY, 720, accuracy: 0.5)
        XCTAssertLessThan(topAlignedViewport.minY, 0)
        XCTAssertEqual(viewportRequests.count, fixedResolutionRequestCount)

        manager.resolution = .size3840x2160
        XCTAssertEqual(manager.remoteCanvasSize, CGSize(width: 3840, height: 2160))
        if let viewportSize = manager.remoteViewportSize {
            if viewportSize.width < 3840 {
                XCTAssertTrue(manager.hasHorizontalRemoteScroller)
                XCTAssertLessThan(manager.horizontalRemoteScrollerKnobProportion ?? 1, 1)
                XCTAssertGreaterThan(manager.horizontalRemoteScrollerKnobProportion ?? 0, 0)
            }
            if viewportSize.height < 2160 {
                XCTAssertTrue(manager.hasVerticalRemoteScroller)
                XCTAssertLessThan(manager.verticalRemoteScrollerKnobProportion ?? 1, 1)
                XCTAssertGreaterThan(manager.verticalRemoteScrollerKnobProportion ?? 0, 0)
            }
        } else {
            XCTFail("Expected a fixed-resolution viewport")
        }

        manager.resolution = .size1280x720
        XCTAssertEqual(manager.remoteCanvasSize, CGSize(width: 1280, height: 720))
        if let viewportSize = manager.remoteViewportSize,
           viewportSize.width >= 1280,
           viewportSize.height >= 720 {
            XCTAssertFalse(manager.hasHorizontalRemoteScroller)
            XCTAssertFalse(manager.hasVerticalRemoteScroller)
        }

        manager.resolution = .fitWindow
        XCTAssertTrue(manager.isRemoteWindowResizable)
        XCTAssertTrue(manager.supportsNativeFullScreen)
        XCTAssertFalse(manager.hasHorizontalRemoteScroller)
        XCTAssertFalse(manager.hasVerticalRemoteScroller)

        manager.closeRemoteWindow()

        XCTAssertFalse(manager.hasOpenRemoteWindow)
        XCTAssertEqual(closeNotifications, 1)
        XCTAssertEqual(manager.shortcutCaptureStatus, .inactive)
    }

    func testRemoteWindowChromeReservesCompactStableToolbarArea() {
        XCTAssertEqual(RemoteWindowChromeMetrics.reservedTopHeight, 40)
        XCTAssertEqual(RemoteWindowChromeMetrics.horizontalContentInset, 0)
        XCTAssertEqual(RemoteWindowChromeMetrics.bottomContentInset, 0)
        XCTAssertEqual(RemoteWindowChromeMetrics.toolbarHeight, 34)
        XCTAssertEqual(RemoteWindowChromeMetrics.edgeRevealWidth, 12)
        XCTAssertEqual(RemoteWindowChromeMetrics.remoteCanvasCornerRadius, 24)

        let viewportSize = CGSize(width: 1024, height: 640)
        let contentSize = RemoteWindowChromeMetrics.contentSize(forViewport: viewportSize)

        XCTAssertEqual(contentSize, CGSize(width: 1024, height: 680))
        XCTAssertEqual(
            RemoteWindowChromeMetrics.viewportSize(forContent: contentSize),
            viewportSize
        )
    }

    func testRemoteSessionWindowTitleIncludesProfileNameAndAddress() {
        XCTAssertEqual(
            RemoteSessionWindowIdentity(
                displayName: "电脑A",
                host: "192.168.10.3",
                port: 3389
            ).title,
            "电脑A-192.168.10.3"
        )
        XCTAssertEqual(
            RemoteSessionWindowIdentity(
                displayName: "测试机",
                host: "2001:db8::10",
                port: 3390
            ).title,
            "测试机-[2001:db8::10]:3390"
        )
    }

    func testRemoteTitlebarElementsAlignWithStandardWindowButtons() {
        let manager = RemoteSessionWindowManager()
        manager.sessionIdentity = RemoteSessionWindowIdentity(
            displayName: "电脑A",
            host: "192.168.10.3",
            port: 3389
        )

        manager.openRemoteWindow()
        let systemButtonCenters = manager.standardWindowButtonCenterYs
        manager.setFloatingToolbarVisible(true)

        XCTAssertEqual(manager.remoteWindowTitle, "电脑A-192.168.10.3")
        XCTAssertEqual(manager.displayedToolbarTitle, "电脑A-192.168.10.3")
        let verticalOffsets = manager.titlebarElementVerticalOffsets
        XCTAssertEqual(verticalOffsets.count, 2)
        XCTAssertTrue(
            verticalOffsets.allSatisfy { abs($0) <= 0.5 },
            "Titlebar elements are vertically offset: \(verticalOffsets)"
        )
        XCTAssertEqual(manager.standardWindowButtonCenterYs.count, systemButtonCenters.count)
        XCTAssertTrue(
            zip(manager.standardWindowButtonCenterYs, systemButtonCenters).allSatisfy { centers in
                abs(centers.0 - centers.1) <= 0.5
            },
            "Showing the custom toolbar must not move AppKit's titlebar buttons"
        )

        manager.closeRemoteWindow()
    }

    func testRemoteToolbarDoubleClickTogglesWindowZoom() {
        XCTAssertFalse(RemoteToolbarInteractionPolicy.togglesWindowZoom(clickCount: 1))
        XCTAssertTrue(RemoteToolbarInteractionPolicy.togglesWindowZoom(clickCount: 2))
        XCTAssertFalse(RemoteToolbarInteractionPolicy.togglesWindowZoom(clickCount: 3))
    }

    func testClipboardTransferPinsRemoteToolbarUntilProgressClears() {
        let manager = RemoteSessionWindowManager()
        manager.openRemoteWindow()

        manager.updateClipboardFileTransfer(
            progress: ClipboardTransferProgress(
                direction: .windowsToMac,
                fileCount: 2,
                completedBytes: 2_048,
                totalBytes: 4_096,
                failed: false
            )
        )
        XCTAssertTrue(manager.clipboardToolbarStatusIsVisible)
        XCTAssertEqual(manager.clipboardToolbarProgressValue, 2_048)
        XCTAssertTrue(manager.floatingToolbarIsVisible)

        manager.updateClipboardFileTransfer(progress: nil)
        XCTAssertFalse(manager.clipboardToolbarStatusIsVisible)
        XCTAssertFalse(manager.floatingToolbarIsVisible)
        manager.closeRemoteWindow()
    }

    func testRemoteFilesPublishFileURLsForFinderPaste() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            deferRemoteFileOffersWhileApplicationActive: false
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("remote.txt")
        try Data("remote".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        controller.applyRemoteFiles([file])

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(urls, [file])
    }

    func testRemoteFileOfferPublishesPlaceholderWithoutStartingTransfer() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            deferRemoteFileOffersWhileApplicationActive: false
        )
        defer { controller.stop() }
        var requestCount = 0

        XCTAssertTrue(controller.offerRemoteFiles(
            generation: 42,
            files: [ClipboardRemoteFileDescriptor(
                name: "remote.txt",
                size: 6,
                modificationDate: nil
            )],
            onRequest: { _, _ in
                requestCount += 1
            },
            onCancel: { _ in }
        ))
        XCTAssertEqual(requestCount, 0)

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        _ = item.data(forType: .fileURL)
        let placeholder = try XCTUnwrap(URL(
            string: try XCTUnwrap(item.string(forType: .fileURL))
        ))
        let attributes = try FileManager.default.attributesOfItem(atPath: placeholder.path)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(placeholder.lastPathComponent, "remote.txt")
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, 6)
    }

    func testDirectSaveStartsImmediatelyAndInstallsAtChosenFilePath() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            deferRemoteFileOffersWhileApplicationActive: false
        )
        defer { controller.stop() }
        let targetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: targetDirectory) }
        let target = targetDirectory.appendingPathComponent("renamed.txt")
        try Data("old".utf8).write(to: target)
        var stagingDirectory: URL?
        var completedURLs: [URL] = []
        let completed = expectation(description: "direct save installed")

        XCTAssertTrue(controller.saveRemoteFiles(
            generation: 47,
            files: [ClipboardRemoteFileDescriptor(
                name: "remote.txt",
                size: 6,
                modificationDate: nil
            )],
            destination: .file(target),
            onRequest: { generation, directory in
                XCTAssertEqual(generation, 47)
                stagingDirectory = directory
            },
            onCancel: { _ in XCTFail("Direct save must not be cancelled") },
            onCompletion: { succeeded, urls in
                XCTAssertTrue(succeeded)
                completedURLs = urls
                completed.fulfill()
            }
        ))
        let staging = try XCTUnwrap(stagingDirectory)
        let stagingFile = staging.appendingPathComponent("remote.txt")
        try Data("remote".utf8).write(to: stagingFile)

        XCTAssertTrue(controller.fulfillRemoteFiles(generation: 47, urls: [stagingFile]))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completedURLs, [target])
        XCTAssertEqual(try Data(contentsOf: target), Data("remote".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty != false)
    }

    func testDirectSaveBatchPreservesRemoteNamesInChosenDirectory() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(pasteboard: pasteboard)
        defer { controller.stop() }
        let targetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: targetDirectory) }
        let files = [
            ClipboardRemoteFileDescriptor(name: "first.txt", size: 5, modificationDate: nil),
            ClipboardRemoteFileDescriptor(name: "second.txt", size: 6, modificationDate: nil),
        ]
        var stagingDirectory: URL?
        var completedURLs: [URL] = []
        let completed = expectation(description: "direct save batch installed")

        XCTAssertTrue(controller.saveRemoteFiles(
            generation: 48,
            files: files,
            destination: .directory(targetDirectory),
            onRequest: { _, directory in stagingDirectory = directory },
            onCancel: { _ in XCTFail("Direct save must not be cancelled") },
            onCompletion: { succeeded, urls in
                XCTAssertTrue(succeeded)
                completedURLs = urls
                completed.fulfill()
            }
        ))
        let staging = try XCTUnwrap(stagingDirectory)
        let stagingURLs = files.map { staging.appendingPathComponent($0.name) }
        try Data("first".utf8).write(to: stagingURLs[0])
        try Data("second".utf8).write(to: stagingURLs[1])

        XCTAssertTrue(controller.fulfillRemoteFiles(generation: 48, urls: stagingURLs))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completedURLs.map(\.lastPathComponent), ["first.txt", "second.txt"])
        XCTAssertEqual(
            try Data(contentsOf: targetDirectory.appendingPathComponent("first.txt")),
            Data("first".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: targetDirectory.appendingPathComponent("second.txt")),
            Data("second".utf8)
        )
    }

    func testCoordinatedPlaceholderReadStartsOneBatchAndWaitsForMaterialization() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            deferRemoteFileOffersWhileApplicationActive: false
        )
        defer { controller.stop() }
        let requested = expectation(description: "batch requested once")
        let coordinatedReadFinished = DispatchSemaphore(value: 0)
        var requestCount = 0
        var offeredURLs: [URL] = []

        XCTAssertTrue(controller.offerRemoteFiles(
            generation: 43,
            files: [
                ClipboardRemoteFileDescriptor(name: "first.txt", size: 5, modificationDate: nil),
                ClipboardRemoteFileDescriptor(name: "second.txt", size: 6, modificationDate: nil),
            ],
            onRequest: { generation, directory in
                requestCount += 1
                XCTAssertEqual(directory, offeredURLs[0].deletingLastPathComponent())
                requested.fulfill()
            },
            onCancel: { _ in XCTFail("Promise must not be cancelled") }
        ))
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        offeredURLs = try items.map { item in
            _ = item.data(forType: .fileURL)
            return try XCTUnwrap(URL(
                string: try XCTUnwrap(item.string(forType: .fileURL))
            ))
        }
        XCTAssertEqual(requestCount, 0)

        let firstURL = offeredURLs[0]
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            coordinator.coordinate(
                readingItemAt: firstURL,
                options: .withoutChanges,
                error: &error
            ) { _ in
                coordinatedReadFinished.signal()
            }
        }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinatedReadFinished.wait(timeout: .now() + 0.05), .timedOut)
        try Data("first".utf8).write(to: offeredURLs[0])
        try Data("second".utf8).write(to: offeredURLs[1])
        XCTAssertTrue(controller.fulfillRemoteFiles(generation: 43, urls: offeredURLs))
        XCTAssertEqual(coordinatedReadFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try Data(contentsOf: offeredURLs[0]), Data("first".utf8))
    }

    func testCancellingMaterializationRemovesPlaceholderBeforeReleasingReader() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            deferRemoteFileOffersWhileApplicationActive: false
        )
        defer { controller.stop() }
        let requested = expectation(description: "coordinated read requested materialization")
        let coordinatedReadFinished = DispatchSemaphore(value: 0)
        let observedMissingFile = DispatchSemaphore(value: 0)

        XCTAssertTrue(controller.offerRemoteFiles(
            generation: 46,
            files: [ClipboardRemoteFileDescriptor(
                name: "cancelled.txt",
                size: 9,
                modificationDate: nil
            )],
            onRequest: { _, _ in requested.fulfill() },
            onCancel: { _ in }
        ))
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        _ = item.data(forType: .fileURL)
        let url = try XCTUnwrap(URL(
            string: try XCTUnwrap(item.string(forType: .fileURL))
        ))

        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            coordinator.coordinate(
                readingItemAt: url,
                options: .withoutChanges,
                error: &error
            ) { coordinatedURL in
                if !FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    observedMissingFile.signal()
                }
                coordinatedReadFinished.signal()
            }
        }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(coordinatedReadFinished.wait(timeout: .now() + 0.05), .timedOut)

        controller.cancelRemoteFileOffer(generation: 46)

        XCTAssertEqual(coordinatedReadFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(observedMissingFile.wait(timeout: .now()), .success)
    }

    func testRemoteFilePromiseIsPublishedAfterApplicationResignsActive() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let notificationCenter = NotificationCenter()
        let controller = RemoteClipboardController(
            pasteboard: pasteboard,
            notificationCenter: notificationCenter,
            isApplicationActive: { true }
        )
        controller.start()
        defer { controller.stop() }
        let initialChangeCount = pasteboard.changeCount

        XCTAssertTrue(controller.offerRemoteFiles(
            generation: 44,
            files: [ClipboardRemoteFileDescriptor(
                name: "deferred.txt",
                size: 8,
                modificationDate: nil
            )],
            onRequest: { _, _ in XCTFail("Listing promised types must not request file data") },
            onCancel: { _ in }
        ))
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)

        notificationCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        await Task.yield()

        XCTAssertGreaterThan(pasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
    }

    func testFixedResolutionViewportIsCappedByAvailableScreenSize() {
        XCTAssertEqual(
            FixedResolutionViewportPolicy.targetSize(
                documentSize: CGSize(width: 1920, height: 1080),
                availableSize: CGSize(width: 1400, height: 900)
            ),
            CGSize(width: 1400, height: 900)
        )
        XCTAssertEqual(
            FixedResolutionViewportPolicy.targetSize(
                documentSize: CGSize(width: 1280, height: 720),
                availableSize: CGSize(width: 1400, height: 900)
            ),
            CGSize(width: 1280, height: 720)
        )
    }

    func testRemoteDocumentAlignmentUsesTopLeftOrigin() {
        XCTAssertEqual(
            RemoteDocumentAlignmentPolicy.topLeftBoundsOrigin(
                documentFrame: CGRect(x: 0, y: 0, width: 1280, height: 720),
                viewportSize: CGSize(width: 1440, height: 860)
            ),
            CGPoint(x: 0, y: -140)
        )
        XCTAssertEqual(
            RemoteDocumentAlignmentPolicy.topLeftBoundsOrigin(
                documentFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                viewportSize: CGSize(width: 1440, height: 860)
            ),
            CGPoint(x: 0, y: 220)
        )
    }

    func testPersistentRemoteScrollerOnlyCapturesItsKnob() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 240))
        let scroller = PersistentRemoteScroller(frame: host.bounds)
        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .light
        scroller.knobProportion = 0.25
        scroller.doubleValue = 0.5
        host.addSubview(scroller)

        let knobRect = scroller.renderedKnobRect
        XCTAssertFalse(knobRect.isEmpty)
        let knobPoint = NSPoint(x: knobRect.midX, y: knobRect.midY)
        XCTAssertTrue(scroller.capturesKnob(at: knobPoint))
        XCTAssertIdentical(
            scroller.hitTest(scroller.convert(knobPoint, to: host)),
            scroller
        )

        let trackPoint = NSPoint(x: scroller.bounds.midX, y: scroller.bounds.minY + 1)
        XCTAssertFalse(knobRect.contains(trackPoint))
        XCTAssertFalse(scroller.capturesKnob(at: trackPoint))
        XCTAssertNil(scroller.hitTest(scroller.convert(trackPoint, to: host)))

        scroller.alphaValue = 0
        XCTAssertEqual(scroller.alphaValue, 1)
        XCTAssertEqual(scroller.scrollerStyle, .legacy)
        XCTAssertEqual(scroller.knobStyle, .light)
    }

    func testNativeRemoteScrollerRendersBothOrientations() throws {
        let scrollbars = [
            PersistentRemoteScroller(frame: NSRect(x: 0, y: 0, width: 320, height: 16)),
            PersistentRemoteScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 240)),
        ]

        for scroller in scrollbars {
            scroller.controlSize = .regular
            scroller.scrollerStyle = .legacy
            scroller.knobStyle = .light
            scroller.knobProportion = 0.5
            scroller.doubleValue = 0.25
            scroller.layoutSubtreeIfNeeded()

            XCTAssertFalse(scroller.renderedKnobRect.isEmpty)
            let bitmap = try XCTUnwrap(scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds))
            scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
            let containsDrawnPixel = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
                }
            }
            XCTAssertTrue(containsDrawnPixel)
            XCTAssertEqual(scroller.scrollerStyle, .legacy)
            XCTAssertEqual(scroller.knobStyle, .light)
        }
    }
}


extension FarframeRDPTests {
    func testEnhancedTapRecoveryDegradesAfterRepeatedDisableNotifications() {
        var policy = EnhancedTapRecoveryPolicy()

        XCTAssertTrue(policy.recordDisableNotification())
        XCTAssertTrue(policy.recordDisableNotification())
        XCTAssertFalse(policy.recordDisableNotification())

        policy.recordHealthyEvent()
        XCTAssertEqual(policy.consecutiveDisables, 0)
        XCTAssertTrue(policy.recordDisableNotification())
    }

    func testLockScreenAndForceQuitRemainLocalSecurityChords() {
        XCTAssertTrue(ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: 12,
            modifierFlags: [.control, .command]
        ))
        XCTAssertTrue(ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: 53,
            modifierFlags: [.option, .command]
        ))
        XCTAssertFalse(ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: 53,
            modifierFlags: [.control, .option, .command]
        ))
        XCTAssertFalse(ShortcutRouter.isAlwaysLocalSecurityChord(
            keyCode: 12,
            modifierFlags: [.command]
        ))
    }

    func testEnhancedCaptureAcceptsPhysicalModifiersAndOrdinaryKeys() {
        XCTAssertTrue(EnhancedKeyEvent(
            type: .flagsChanged,
            keyCode: 55,
            modifierFlags: [.command],
            isRepeat: false
        ).isMappablePhysicalInput)
        XCTAssertTrue(EnhancedKeyEvent(
            type: .keyDown,
            keyCode: 126,
            modifierFlags: [.command],
            isRepeat: false
        ).isMappablePhysicalInput)
        XCTAssertFalse(EnhancedKeyEvent(
            type: .keyDown,
            keyCode: UInt16.max,
            modifierFlags: [],
            isRepeat: false
        ).isMappablePhysicalInput)
    }

    func testEnhancedEventTapSystemDisableNotificationsRequireReenable() {
        XCTAssertTrue(
            EnhancedEventTapNotification.requiresReenable(.tapDisabledByTimeout)
        )
        XCTAssertTrue(
            EnhancedEventTapNotification.requiresReenable(.tapDisabledByUserInput)
        )
        XCTAssertFalse(EnhancedEventTapNotification.requiresReenable(.keyDown))
        XCTAssertFalse(EnhancedEventTapNotification.requiresReenable(.keyUp))
    }

    func testEnhancedCaptureScopeRequiresEverySafetyCondition() {
        var scope = EnhancedCaptureScope(
            applicationIsActive: true,
            sessionIsConnected: true,
            canvasIsFirstResponder: true,
            userEnabled: true,
            permissionGranted: true
        )
        XCTAssertTrue(scope.shouldInstallEventTap)

        scope.applicationIsActive = false
        XCTAssertFalse(scope.shouldInstallEventTap)
        scope.applicationIsActive = true
        scope.sessionIsConnected = false
        XCTAssertFalse(scope.shouldInstallEventTap)
        scope.sessionIsConnected = true
        scope.canvasIsFirstResponder = false
        XCTAssertFalse(scope.shouldInstallEventTap)
        scope.canvasIsFirstResponder = true
        scope.userEnabled = false
        XCTAssertFalse(scope.shouldInstallEventTap)
        scope.userEnabled = true
        scope.permissionGranted = false
        XCTAssertFalse(scope.shouldInstallEventTap)
    }

    func testEnhancedShortcutRouterOnlyCapturesEnabledEnhancedPolicy() {
        var policy = ShortcutPolicy.defaults.first { $0.id == "app-switcher" }!
        policy.captureWhenRemoteFocused = true
        policy.scope = .both
        var router = ShortcutRouter(policies: [policy])

        XCTAssertEqual(policy.remoteChordDisplayName, "Win-Tab")
        XCTAssertEqual(policy.remoteChord?.modifiers, [WindowsScanCode.leftWindows])

        XCTAssertEqual(
            router.routeEnhancedKeyDown(
                keyCode: 48,
                modifierFlags: [.command],
                isFullScreen: false
            ),
            .captured(policyID: "app-switcher", remoteCommands: policy.remoteChord!.commands)
        )
        XCTAssertTrue(router.shouldSuppressKeyUp(keyCode: 48))
    }

    func testEnhancedRouterKeepsConfiguredSemanticOverrides() {
        var router = ShortcutRouter(policies: ShortcutPolicy.defaults)
        XCTAssertEqual(
            router.routeEnhancedKeyDown(
                keyCode: 13,
                modifierFlags: [.command],
                isFullScreen: false
            ),
            .captured(
                policyID: "close",
                remoteCommands: ShortcutPolicy.defaults.first {
                    $0.id == "close"
                }!.remoteChord!.commands
            )
        )
    }

    func testControlCommandArrowsMapToWindowsVirtualDesktopChords() {
        for (id, keyCode, remoteKey) in [
            ("space-left", UInt16(123), WindowsScanCode.left),
            ("space-right", UInt16(124), WindowsScanCode.right),
        ] {
            guard let policy = ShortcutPolicy.defaults.first(where: { $0.id == id }) else {
                return XCTFail("Missing \(id) policy")
            }
            XCTAssertTrue(policy.captureWhenRemoteFocused)
            XCTAssertEqual(policy.scope, .both)
            XCTAssertEqual(
                policy.remoteChord?.modifiers,
                [WindowsScanCode.leftControl, WindowsScanCode.leftWindows]
            )
            var router = ShortcutRouter(policies: [policy])
            XCTAssertEqual(
                router.routeEnhancedKeyDown(
                    keyCode: keyCode,
                    modifierFlags: [.control, .command],
                    isFullScreen: false
                ),
                .captured(policyID: id, remoteCommands: policy.remoteChord!.commands)
            )
            XCTAssertEqual(policy.remoteChord?.key, remoteKey)
        }
    }

    @MainActor
    func testEnhancedCapturePermissionRequiresBothSystemGrantsAndSupportsSafeRefresh() {
        var accessibility = true
        var inputMonitoring = false
        var requestCount = 0
        var openCount = 0
        let model = EnhancedCapturePermissionModel(
            accessibilityCheck: { accessibility },
            inputMonitoringCheck: { inputMonitoring },
            permissionRequest: { requestCount += 1 },
            settingsOpener: { openCount += 1 }
        )

        XCTAssertFalse(model.canUseEnhancedCapture)
        XCTAssertEqual(model.accessibility, .granted)
        XCTAssertEqual(model.inputMonitoring, .denied)

        inputMonitoring = true
        model.requestPermissions()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(model.canUseEnhancedCapture)

        accessibility = false
        model.refresh()
        XCTAssertFalse(model.canUseEnhancedCapture)
        model.openPrivacySettings()
        XCTAssertEqual(openCount, 1)
    }

    @MainActor
    func testEnhancedCapturePermissionRevealsTheRunningApplicationBundle() {
        let applicationURL = URL(fileURLWithPath: "/tmp/FarframeRDP.app")
        var revealedURL: URL?
        let model = EnhancedCapturePermissionModel(
            accessibilityCheck: { false },
            inputMonitoringCheck: { false },
            permissionRequest: {},
            settingsOpener: {},
            applicationURL: applicationURL,
            applicationRevealer: { revealedURL = $0 }
        )

        model.revealCurrentApplication()

        XCTAssertEqual(model.applicationURL, applicationURL)
        XCTAssertEqual(revealedURL, applicationURL)
    }

    func testRemoteFrameUpdateRejectsInvalidGeometryAndByteCount() {
        let size = RemoteDesktopSize(width: 2, height: 2)!
        XCTAssertNil(RemoteFrameRect(x: -1, y: 0, width: 1, height: 1, desktop: size))
        XCTAssertNil(RemoteFrameRect(x: 1, y: 1, width: 2, height: 1, desktop: size))

        let rect = RemoteFrameRect(x: 0, y: 0, width: 2, height: 2, desktop: size)!
        XCTAssertNil(RemoteFrameUpdate(
            desktopSize: size,
            dirtyRect: rect,
            pixels: Data(count: 15),
            sequenceNumber: 1
        ))
        XCTAssertNotNil(RemoteFrameUpdate(
            desktopSize: size,
            dirtyRect: rect,
            pixels: Data(count: 16),
            sequenceNumber: 1
        ))
    }

    func testFrameMailboxCoalescesUpdatesIntoOneNotification() {
        let mailbox = RemoteFrameMailbox()
        var source = [UInt8](repeating: 0, count: 16)
        source[0...3] = [1, 2, 3, 4]
        source[12...15] = [5, 6, 7, 8]

        source.withUnsafeBufferPointer { buffer in
            XCTAssertTrue(mailbox.ingest(
                desktopWidth: 2,
                desktopHeight: 2,
                sourceStride: 8,
                pixels: buffer.baseAddress!,
                bufferLength: buffer.count,
                dirtyX: 0,
                dirtyY: 0,
                dirtyWidth: 1,
                dirtyHeight: 1,
                sequenceNumber: 1
            ))
            XCTAssertFalse(mailbox.ingest(
                desktopWidth: 2,
                desktopHeight: 2,
                sourceStride: 8,
                pixels: buffer.baseAddress!,
                bufferLength: buffer.count,
                dirtyX: 1,
                dirtyY: 1,
                dirtyWidth: 1,
                dirtyHeight: 1,
                sequenceNumber: 2
            ))
        }

        var consumed = false
        XCTAssertTrue(mailbox.consumePendingFrame { size, rect, pixels, bytesPerRow, sequenceNumber in
            consumed = true
            XCTAssertEqual(rect, RemoteFrameRect(
                x: 0,
                y: 0,
                width: 2,
                height: 2,
                desktop: RemoteDesktopSize(width: 2, height: 2)!
            ))
            XCTAssertEqual(sequenceNumber, 2)
            XCTAssertEqual(bytesPerRow, size.packedBytesPerRow)
            XCTAssertEqual(Array(pixels[0...3]), [1, 2, 3, 4])
            XCTAssertEqual(Array(pixels[12...15]), [5, 6, 7, 8])
        })
        XCTAssertTrue(consumed)
        XCTAssertFalse(mailbox.consumePendingFrame { _, _, _, _, _ in
            XCTFail("A consumed mailbox must not redeliver an old frame")
        })
    }

    func testRemoteCanvasStoresValidatedFrame() {
        let size = RemoteDesktopSize(width: 2, height: 2)!
        let rect = RemoteFrameRect(x: 0, y: 0, width: 2, height: 2, desktop: size)!
        let update = RemoteFrameUpdate(
            desktopSize: size,
            dirtyRect: rect,
            pixels: Data(repeating: 0x7F, count: 16),
            sequenceNumber: 1
        )!
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))

        canvas.display(update)

        XCTAssertEqual(canvas.displayedDesktopSize, size)
        XCTAssertTrue(canvas.hasReceivedFrame)
    }

    func testRemoteCanvasConsumesBorrowedFullFramebufferWithoutIntermediateUpdate() {
        let size = RemoteDesktopSize(width: 2, height: 2)!
        let rect = RemoteFrameRect(x: 1, y: 1, width: 1, height: 1, desktop: size)!
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let source = Data([
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 1, 2, 3, 4,
        ])

        source.withUnsafeBytes { pixels in
            canvas.display(
                desktopSize: size,
                dirtyRect: rect,
                pixels: pixels,
                bytesPerRow: size.packedBytesPerRow,
                sequenceNumber: 1
            )
        }

        XCTAssertEqual(canvas.displayedDesktopSize, size)
        XCTAssertTrue(canvas.hasReceivedFrame)
    }

    func testPresentationRateOffersAdaptiveThirtyAndSixtyFPS() {
        XCTAssertEqual(RemotePresentationRate.allCases, [.adaptive, .fps30, .fps60])
        XCTAssertEqual(RemotePresentationRate.fps30.frameRateRange.preferred, 30)
        XCTAssertEqual(RemotePresentationRate.fps30.frameRateRange.maximum, 30)
        XCTAssertEqual(RemotePresentationRate.fps60.frameRateRange.preferred, 60)
        XCTAssertEqual(RemotePresentationRate.fps60.frameRateRange.maximum, 60)
    }
}


extension FarframeRDPTests {
    func testRemoteCursorValidationAndCanvasState() {
        XCTAssertNil(RemoteCursorShape(
            width: 2,
            height: 2,
            hotspotX: 2,
            hotspotY: 0,
            pixels: Data(count: 16)
        ))
        let shape = RemoteCursorShape(
            width: 1,
            height: 1,
            hotspotX: 0,
            hotspotY: 0,
            pixels: Data([0, 0, 0, 255])
        )!
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

        canvas.applyCursorUpdate(.shape(shape))
        XCTAssertEqual(canvas.currentCursorUpdate, .shape(shape))

        canvas.applyCursorUpdate(.hidden)
        XCTAssertEqual(canvas.currentCursorUpdate, .hidden)

        canvas.applyCursorUpdate(.position(x: 10, y: 20))
        XCTAssertEqual(canvas.currentCursorUpdate, .position(x: 10, y: 20))

        canvas.applyCursorUpdate(.defaultCursor)
        XCTAssertEqual(canvas.currentCursorUpdate, .defaultCursor)
    }
}


extension FarframeRDPTests {
    func testCoreGraphicsDiagnosticFallbackCanReceiveFrame() {
        setenv("FARFRAME_RENDERER", "coregraphics", 1)
        defer { unsetenv("FARFRAME_RENDERER") }

        let size = RemoteDesktopSize(width: 1, height: 1)!
        let rect = RemoteFrameRect(x: 0, y: 0, width: 1, height: 1, desktop: size)!
        let update = RemoteFrameUpdate(
            desktopSize: size,
            dirtyRect: rect,
            pixels: Data([0, 0, 0, 255]),
            sequenceNumber: 1
        )!
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

        XCTAssertTrue(canvas.isUsingCoreGraphicsFallback)
        canvas.display(update)
        XCTAssertTrue(canvas.hasReceivedFrame)
    }
}


extension FarframeRDPTests {
    func testMacKeyCodeMappingCoversPhysicalAndNavigationKeys() {
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 0), WindowsScanCode.a)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 55), WindowsScanCode.leftWindows)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 54), WindowsScanCode.rightWindows)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 58), WindowsScanCode.leftAlt)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 62), WindowsScanCode.rightControl)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 122), WindowsScanCode.f1)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 111), WindowsScanCode.f12)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 123), WindowsScanCode.left)
        XCTAssertEqual(MacKeyCodeMapper.scanCode(for: 117), WindowsScanCode.delete)
        XCTAssertNil(MacKeyCodeMapper.scanCode(for: UInt16.max))
    }

    func testInputStatePairsKeysRepeatsModifiersAndButtons() {
        var state = RemoteInputState()
        XCTAssertEqual(
            state.keyCommand(keyCode: 123, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.left, down: true, repeatKey: false)
        )
        XCTAssertNil(state.keyCommand(keyCode: 123, down: true, repeatKey: false))
        XCTAssertEqual(
            state.keyCommand(keyCode: 123, down: true, repeatKey: true),
            .scanCode(WindowsScanCode.left, down: true, repeatKey: true)
        )
        XCTAssertEqual(
            state.keyCommand(keyCode: 123, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.left, down: false, repeatKey: false)
        )
        XCTAssertNil(state.keyCommand(keyCode: 123, down: false, repeatKey: false))

        XCTAssertEqual(
            state.modifierCommand(keyCode: 55),
            .scanCode(WindowsScanCode.leftWindows, down: true, repeatKey: false)
        )
        XCTAssertEqual(
            state.modifierCommand(keyCode: 55),
            .scanCode(WindowsScanCode.leftWindows, down: false, repeatKey: false)
        )

        let position = RemotePointerPosition(x: 10, y: 20)
        XCTAssertEqual(
            state.buttonCommand(.x1, down: true, position: position),
            .pointerButton(.x1, down: true, position: position)
        )
        XCTAssertNil(state.buttonCommand(.x1, down: true, position: position))
        XCTAssertEqual(state.releaseAll(), .releaseAll)
        XCTAssertTrue(state.pressedScanCodes.isEmpty)
        XCTAssertTrue(state.pressedButtons.isEmpty)
    }

    func testNumLockTogglesOnlyOnNewPhysicalPress() {
        var state = RemoteInputState()
        XCTAssertFalse(state.numLock)
        _ = state.keyCommand(keyCode: 71, down: true, repeatKey: false)
        XCTAssertTrue(state.numLock)
        _ = state.keyCommand(keyCode: 71, down: true, repeatKey: true)
        XCTAssertTrue(state.numLock)
        _ = state.keyCommand(keyCode: 71, down: false, repeatKey: false)
        _ = state.keyCommand(keyCode: 71, down: true, repeatKey: false)
        XCTAssertFalse(state.numLock)
    }

    func testViewportGeometryMapsFitAndRetinaActualPixels() {
        let desktop = RemoteDesktopSize(width: 1920, height: 1080)!
        let fit = RemoteViewportGeometry(
            desktopSize: desktop,
            canvasSize: CGSize(width: 1000, height: 1000),
            backingScale: 1,
            scalingMode: .fit
        )
        XCTAssertEqual(fit.destinationRect.width, 1000, accuracy: 0.001)
        XCTAssertEqual(fit.destinationRect.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(
            fit.remotePosition(for: CGPoint(x: 500, y: 500)),
            RemotePointerPosition(x: 960, y: 540)
        )
        XCTAssertNil(fit.remotePosition(for: CGPoint(x: 500, y: 100)))

        let retinaDesktop = RemoteDesktopSize(width: 200, height: 100)!
        let actual = RemoteViewportGeometry(
            desktopSize: retinaDesktop,
            canvasSize: CGSize(width: 200, height: 100),
            backingScale: 2,
            scalingMode: .actualPixels
        )
        XCTAssertEqual(actual.destinationRect, CGRect(x: 50, y: 25, width: 100, height: 50))
        XCTAssertEqual(
            actual.remotePosition(for: CGPoint(x: 100, y: 50)),
            RemotePointerPosition(x: 100, y: 50)
        )
    }

    func testDynamicResolutionPolicyUsesBackingPixelsAndDisplayControlBounds() {
        XCTAssertEqual(
            DynamicResolutionPolicy.targetSize(
                canvasSize: CGSize(width: 513.4, height: 384.2),
                backingScale: 2
            ),
            RemoteDesktopSize(width: 1026, height: 768)
        )
        XCTAssertEqual(
            DynamicResolutionPolicy.targetSize(canvasSize: CGSize(width: 40, height: 80)),
            RemoteDesktopSize(width: 200, height: 200)
        )
        XCTAssertEqual(
            DynamicResolutionPolicy.targetSize(canvasSize: CGSize(width: 9000, height: 9000)),
            RemoteDesktopSize(width: 8192, height: 8192)
        )
        XCTAssertNil(DynamicResolutionPolicy.targetSize(
            canvasSize: CGSize(width: CGFloat.infinity, height: 600)
        ))
        XCTAssertEqual(DynamicResolutionPolicy.desktopScaleFactor(backingScale: 2), 200)
        XCTAssertEqual(DynamicResolutionPolicy.desktopScaleFactor(backingScale: 1.5), 150)
    }

    func testMonitorLayoutPolicyBuildsPrimaryWindowLayout() {
        let layouts = RemoteMonitorLayoutPolicy.targetLayout(
            selection: .window,
            canvasSize: CGSize(width: 801, height: 603),
            backingScale: 2,
            windowScreen: nil,
            screens: []
        )

        XCTAssertEqual(layouts, [
            RemoteMonitorLayout(
                left: 0,
                top: 0,
                width: 1602,
                height: 1206,
                desktopScaleFactor: 200,
                deviceScaleFactor: 100,
                primary: true
            )
        ].compactMap { $0 })
    }

    func testRemoteWindowPublishesViewportLayoutRequests() {
        let manager = RemoteSessionWindowManager()
        var sizes: [RemoteDesktopSize] = []
        var layouts: [[RemoteMonitorLayout]] = []
        manager.onViewportResize = {
            sizes.append($0)
        }
        manager.onViewportLayout = {
            layouts.append($0)
        }

        manager.openRemoteWindow()

        XCTAssertEqual(
            layouts.last,
            sizes.last.map {
                [RemoteMonitorLayout(
                    left: 0,
                    top: 0,
                    width: $0.width,
                    height: $0.height,
                    desktopScaleFactor: DynamicResolutionPolicy.desktopScaleFactor(
                        backingScale: NSScreen.main?.backingScaleFactor ?? 1
                    ),
                    deviceScaleFactor: 100,
                    primary: true
                )]
                    .compactMap { $0 }
            }
        )
        manager.closeRemoteWindow()
    }

    func testRemoteCanvasForcesInitialBackingPixelViewportRequest() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640))
        var requests: [RemoteDesktopSize] = []
        canvas.onViewportResize = { requests.append($0) }

        canvas.requestInitialDynamicResolution()

        let scale = NSScreen.main?.backingScaleFactor ?? 1
        XCTAssertEqual(requests, [DynamicResolutionPolicy.targetSize(
            canvasSize: CGSize(width: 1024, height: 640),
            backingScale: scale
        )!])
    }

    func testTextAndBackspaceAlwaysUsePhysicalScanCodes() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        let chineseCompositionKey = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "中",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )!
        let backspace = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: String(UnicodeScalar(8)),
            charactersIgnoringModifiers: String(UnicodeScalar(8)),
            isARepeat: false,
            keyCode: 51
        )!

        canvas.keyDown(with: chineseCompositionKey)
        canvas.keyDown(with: backspace)

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.b, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.backspace, down: true, repeatKey: false),
        ])
    }

    func testActualPixelRendererCropsTextureToMatchInputGeometry() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        canvas.setScalingMode(.actualPixels)
        let desktop = RemoteDesktopSize(width: 1920, height: 1080)!

        let vertices = canvas.aspectFitVertices(
            desktopSize: desktop,
            drawableSize: CGSize(width: 1000, height: 1000)
        )

        XCTAssertEqual(vertices[0], -1, accuracy: 0.0001)
        XCTAssertEqual(vertices[1], 1, accuracy: 0.0001)
        XCTAssertEqual(vertices[2], 0.239583, accuracy: 0.0001)
        XCTAssertEqual(vertices[3], 0.037037, accuracy: 0.0001)
        XCTAssertEqual(vertices[6], 0.760417, accuracy: 0.0001)
        XCTAssertEqual(vertices[11], 0.962963, accuracy: 0.0001)
    }

    func testCanvasReleasePathEmitsReleaseBarrier() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.releaseAllRemoteInput()

        XCTAssertEqual(commands, [.releaseAll])
        XCTAssertEqual(canvas.releaseAllRequestCount, 1)
    }
}

extension FarframeRDPTests {
    func testDefaultShortcutPoliciesCoverApplicationCommandsAndDeferEnhancedItems() {
        let policies = ShortcutPolicy.defaults
        let close = policies.first { $0.id == "close" }
        let quit = policies.first { $0.id == "quit-protection" }
        let appSwitcher = policies.first { $0.id == "app-switcher" }

        XCTAssertEqual(close?.macChordDisplayName, "Command-W")
        XCTAssertEqual(close?.remoteChordDisplayName, "Ctrl-W")
        XCTAssertEqual(close?.scope, .both)
        XCTAssertEqual(quit?.remoteChord, nil)
        XCTAssertTrue(quit?.captureWhenRemoteFocused == true)
        XCTAssertTrue(appSwitcher?.requiresEnhancedCapture == true)
        XCTAssertTrue(appSwitcher?.isSystemReserved == true)
        XCTAssertTrue(appSwitcher?.captureWhenRemoteFocused == true)
        XCTAssertEqual(appSwitcher?.scope, .both)

        XCTAssertEqual(Set(policies.map { policy in policy.id }).count, policies.count)
        let chords = policies.map { policy in
            String(policy.macChord.keyCode) + ":" +
                String(policy.macChord.modifiers.rawValue)
        }
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    func testShortcutRouterPrioritizesSemanticCommandAndPairsRemoteChord() {
        var router = ShortcutRouter(policies: ShortcutPolicy.defaults)

        XCTAssertEqual(
            router.routeKeyDown(
                keyCode: 13,
                modifierFlags: [.command],
                isFullScreen: false
            ),
            .captured(
                policyID: "close",
                remoteCommands: [
                    .scanCode(WindowsScanCode.leftControl, down: true, repeatKey: false),
                    .scanCode(WindowsScanCode.w, down: true, repeatKey: false),
                    .scanCode(WindowsScanCode.w, down: false, repeatKey: false),
                    .scanCode(WindowsScanCode.leftControl, down: false, repeatKey: false),
                ]
            )
        )
        XCTAssertTrue(router.shouldSuppressKeyUp(keyCode: 13))
        XCTAssertFalse(router.shouldSuppressKeyUp(keyCode: 13))
    }

    func testShortcutRouterHonorsScopeAndNeverActivatesEnhancedPolicy() {
        guard var fullScreenOnly = ShortcutPolicy.defaults.first(where: { $0.id == "close" }) else {
            return XCTFail("Missing close policy")
        }
        fullScreenOnly.scope = .fullscreen
        var router = ShortcutRouter(policies: [fullScreenOnly])

        XCTAssertEqual(
            router.routeKeyDown(keyCode: 13, modifierFlags: [.command], isFullScreen: false),
            .passThrough
        )
        XCTAssertNotEqual(
            router.routeKeyDown(keyCode: 13, modifierFlags: [.command], isFullScreen: true),
            .passThrough
        )

        guard var enhanced = ShortcutPolicy.defaults.first(where: { $0.id == "app-switcher" }) else {
            return XCTFail("Missing enhanced policy")
        }
        enhanced.captureWhenRemoteFocused = true
        router = ShortcutRouter(policies: [enhanced])
        XCTAssertEqual(
            router.routeKeyDown(keyCode: 48, modifierFlags: [.command], isFullScreen: true),
            .passThrough
        )

        var disabled = fullScreenOnly
        disabled.captureWhenRemoteFocused = false
        disabled.scope = .both
        router = ShortcutRouter(policies: [disabled])
        XCTAssertEqual(
            router.routeKeyDown(keyCode: 13, modifierFlags: [.command], isFullScreen: false),
            .passThrough
        )
    }

    func testSemanticShortcutDoesNotSendWindowsKeyBeforeCtrlW() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        XCTAssertTrue(window.makeFirstResponder(canvas))

        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.command]))

        let commandW = keyEvent(type: .keyDown, keyCode: 13, modifiers: [.command])
        XCTAssertTrue(canvas.performKeyEquivalent(with: commandW))
        canvas.keyUp(with: keyEvent(type: .keyUp, keyCode: 13, modifiers: [.command]))
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: []))

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.leftControl, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.w, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.w, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.leftControl, down: false, repeatKey: false),
        ])
    }

    func testStandaloneCommandSendsWindowsKeyTapOnRelease() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.command]))
        XCTAssertTrue(commands.isEmpty)
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: []))

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.leftWindows, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.leftWindows, down: false, repeatKey: false),
        ])
    }

    func testReleaseAllRecoversWhenCommandKeyUpWasNotDelivered() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.command]))
        canvas.releaseAllRemoteInput()

        // Simulate focus loss swallowing the old key-up, followed by a fresh Command press.
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.command]))
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: []))

        XCTAssertEqual(commands, [
            .releaseAll,
            .scanCode(WindowsScanCode.leftWindows, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.leftWindows, down: false, repeatKey: false),
        ])
    }

    func testUnmappedCommandChordFlushesWindowsKeyBeforePhysicalKey() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.command]))
        canvas.keyDown(with: keyEvent(type: .keyDown, keyCode: 11, modifiers: [.command]))
        canvas.keyUp(with: keyEvent(type: .keyUp, keyCode: 11, modifiers: [.command]))
        canvas.flagsChanged(with: keyEvent(type: .flagsChanged, keyCode: 55, modifiers: []))

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.leftWindows, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.b, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.b, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.leftWindows, down: false, repeatKey: false),
        ])
    }

    func testBasicCapturePairsRepeatedWindowsArrowChords() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.flagsChanged(with: keyEvent(
            type: .flagsChanged,
            keyCode: 55,
            modifiers: [.command]
        ))
        for _ in 0..<2 {
            XCTAssertTrue(canvas.handleCapturedLocalKeyEvent(keyEvent(
                type: .keyDown,
                keyCode: 126,
                modifiers: [.command]
            )))
            XCTAssertTrue(canvas.handleCapturedLocalKeyEvent(keyEvent(
                type: .keyUp,
                keyCode: 126,
                modifiers: [.command]
            )))
        }
        canvas.flagsChanged(with: keyEvent(
            type: .flagsChanged,
            keyCode: 55,
            modifiers: []
        ))

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.leftWindows, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.up, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.up, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.up, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.up, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.leftWindows, down: false, repeatKey: false),
        ])
    }

    func testEmergencyChordReleasesInputAndDisablesKeyboardCapture() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        XCTAssertTrue(window.makeFirstResponder(canvas))

        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        XCTAssertTrue(canvas.performKeyEquivalent(with: keyEvent(
            type: .keyDown,
            keyCode: 53,
            modifiers: [.control, .option, .command]
        )))

        XCTAssertEqual(commands, [.releaseAll])
        XCTAssertFalse(canvas.keyboardCaptureEnabled)
        XCTAssertEqual(canvas.shortcutCaptureStatus, .released)
    }

    func testEscapeReleasesControlWhenModifierKeyUpWasNotDelivered() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var commands: [RemoteInputCommand] = []
        canvas.onInput = { commands.append($0) }

        canvas.flagsChanged(with: keyEvent(
            type: .flagsChanged,
            keyCode: 59,
            modifiers: [.control]
        ))
        canvas.keyDown(with: keyEvent(type: .keyDown, keyCode: 53, modifiers: []))
        canvas.keyUp(with: keyEvent(type: .keyUp, keyCode: 53, modifiers: []))

        XCTAssertEqual(commands, [
            .scanCode(WindowsScanCode.leftControl, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.leftControl, down: false, repeatKey: false),
            .scanCode(WindowsScanCode.escape, down: true, repeatKey: false),
            .scanCode(WindowsScanCode.escape, down: false, repeatKey: false),
        ])
    }

    func testLocalKeyMonitorFollowsCanvasWindowLifetime() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        window.contentView = canvas
        XCTAssertTrue(canvas.hasLocalKeyMonitor)
        canvas.deactivateInputHandling()
        XCTAssertFalse(canvas.hasLocalKeyMonitor)
    }

    func testRemovingCanvasFromWindowDoesNotReinstallLocalKeyMonitor() {
        let canvas = RemoteCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        window.contentView = canvas
        XCTAssertTrue(canvas.hasLocalKeyMonitor)
        window.contentView = NSView(frame: canvas.frame)
        XCTAssertFalse(canvas.hasLocalKeyMonitor)
    }

    private func keyEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            preconditionFailure("Unable to create key event")
        }
        return event
    }
}
