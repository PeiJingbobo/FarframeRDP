import AppKit
import FarframeCore
import SwiftData
import SwiftUI

final class FarframeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct FarframeRDPApp: App {
    @NSApplicationDelegateAdaptor(FarframeApplicationDelegate.self) private var applicationDelegate
    @StateObject private var shortcutSettings = ShortcutSettingsStore()
    @StateObject private var enhancedCapturePermission = EnhancedCapturePermissionModel()

    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: Schema(versionedSchema: FarframeSchemaV1.self),
                migrationPlan: FarframeMigrationPlan.self
            )
        } catch {
            // Crash reasons are persisted outside the app by macOS. Never put
            // database paths or underlying storage details in this message.
            fatalError("Unable to create the Farframe profile store")
        }
    }()

    init() {
        let logger = FarframeLog.logger(for: .app)
        logger.info("Farframe RDP application started")
        logger.info("FreeRDP \(NativeRuntime.freeRDPVersion, privacy: .public) loaded")
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(shortcutSettings)
                .environmentObject(enhancedCapturePermission)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView()
                .environmentObject(shortcutSettings)
                .environmentObject(enhancedCapturePermission)
        }
        .modelContainer(modelContainer)
    }
}
