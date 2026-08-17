import AppKit
import ApplicationServices
import CoreGraphics

enum EnhancedCapturePermissionState: Equatable, Sendable {
    case granted
    case denied

    var isGranted: Bool { self == .granted }
}

@MainActor
final class EnhancedCapturePermissionModel: ObservableObject {
    @Published private(set) var accessibility: EnhancedCapturePermissionState = .denied
    @Published private(set) var inputMonitoring: EnhancedCapturePermissionState = .denied

    private let accessibilityCheck: () -> Bool
    private let inputMonitoringCheck: () -> Bool
    private let permissionRequest: () -> Void
    private let settingsOpener: () -> Void
    private let applicationRevealer: (URL) -> Void

    let applicationURL: URL

    init(
        accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputMonitoringCheck: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        permissionRequest: @escaping () -> Void = {
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestListenEventAccess()
        },
        settingsOpener: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
            ) else { return }
            NSWorkspace.shared.open(url)
        },
        applicationURL: URL = Bundle.main.bundleURL,
        applicationRevealer: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.accessibilityCheck = accessibilityCheck
        self.inputMonitoringCheck = inputMonitoringCheck
        self.permissionRequest = permissionRequest
        self.settingsOpener = settingsOpener
        self.applicationURL = applicationURL
        self.applicationRevealer = applicationRevealer
        refresh()
    }

    var canUseEnhancedCapture: Bool {
        accessibility.isGranted && inputMonitoring.isGranted
    }

    func refresh() {
        accessibility = accessibilityCheck() ? .granted : .denied
        inputMonitoring = inputMonitoringCheck() ? .granted : .denied
    }

    func requestPermissions() {
        permissionRequest()
        refresh()
    }

    func openPrivacySettings() {
        settingsOpener()
    }

    func revealCurrentApplication() {
        applicationRevealer(applicationURL)
    }
}
