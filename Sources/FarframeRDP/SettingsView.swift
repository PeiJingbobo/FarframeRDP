import FarframeCore
import AppKit
import SwiftData
import SwiftUI

enum ApplicationPreferenceKeys {
    static let automaticHostStatusChecks = "automaticHostStatusChecks"
    static let enhancedShortcutCapture = "enhancedShortcutCapture"
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case network
    case keyboard

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "通用"
        case .network:
            "网络与状态"
        case .keyboard:
            "键盘与快捷键"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .network:
            "network"
        case .keyboard:
            "keyboard"
        }
    }

    var summary: String {
        switch self {
        case .general:
            "查看应用与安全存储信息。"
        case .network:
            "管理主机可达性提示。"
        case .keyboard:
            "设置远程会话的快捷键捕获策略。"
        }
    }
}

enum SettingsLayout {
    static let sidebarWidth: CGFloat = 220
    static let minimumContentWidth: CGFloat = 600
    static let minimumHeight: CGFloat = 620
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var shortcutSettings: ShortcutSettingsStore
    @EnvironmentObject private var enhancedCapturePermission: EnhancedCapturePermissionModel
    @AppStorage(ApplicationPreferenceKeys.automaticHostStatusChecks) private var automaticHostStatusChecks = true
    @AppStorage(ApplicationPreferenceKeys.enhancedShortcutCapture) private var enhancedShortcutCapture = false
    @State private var selection: SettingsDestination = .general
    @State private var showingClearConfirmation = false
    @State private var clearResultMessage: String?
    @State private var isClearingLocalData = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                settingsHeader
                Divider()
                selectedSettings
            }
            .frame(minWidth: SettingsLayout.minimumContentWidth)
        }
        .frame(
            minWidth: SettingsLayout.sidebarWidth + SettingsLayout.minimumContentWidth,
            idealWidth: 900,
            minHeight: SettingsLayout.minimumHeight,
            idealHeight: 700
        )
        .confirmationDialog(
            "清除全部本地数据？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部数据", role: .destructive) {
                clearAllLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前会话，并永久删除所有电脑配置、保存的密码、证书信任和应用偏好。此操作无法撤销。")
        }
        .alert(
            "本地数据清除",
            isPresented: Binding(
                get: { clearResultMessage != nil },
                set: { if !$0 { clearResultMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearResultMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设置")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 4)

            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .accessibilityIdentifier("settings.sidebar.\(destination.rawValue)")
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: SettingsLayout.sidebarWidth)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("settings.sidebar")
    }

    private var settingsHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: selection.systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                Text(selection.summary)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selection {
        case .general:
            generalSettings
        case .network:
            networkSettings
        case .keyboard:
            keyboardSettings
        }
    }

    private var generalSettings: some View {
        Form {
            Section("应用") {
                LabeledContent("应用", value: "Farframe RDP")
                LabeledContent("凭据服务", value: AppEnvironment.keychainService)
            }

            Section {
                Text("密码由 macOS 钥匙串保存，不会写入连接配置或偏好设置。")
                    .foregroundStyle(.secondary)
            } header: {
                Text("安全")
            }

            Section("本地数据") {
                Button("清除全部本地数据与凭据", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(isClearingLocalData)

                Text("删除所有电脑配置、钥匙串密码、已记住的证书信任和应用偏好。清除前会释放当前远程会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormStyle()
    }

    private func clearAllLocalData() {
        isClearingLocalData = true
        Task { @MainActor in
            let result = await LocalDataClearService().clearAll(modelContext: modelContext)
            shortcutSettings.restoreDefaults()
            automaticHostStatusChecks = true
            enhancedShortcutCapture = false
            isClearingLocalData = false
            if result.succeeded {
                clearResultMessage = "所有本地电脑配置、保存的密码、证书信任和应用偏好均已清除。"
            } else {
                let categories = result.failures.map(\.category.localizedName).joined(separator: "、")
                clearResultMessage = "部分数据未能清除：\(categories)。请解锁钥匙串或解决存储问题后重试。"
            }
        }
    }

    private var networkSettings: some View {
        Form {
            Section("可达性") {
                Toggle("自动检查可达性", isOn: $automaticHostStatusChecks)

                Text("使用短时 TCP 连接提示电脑是否可能在线。关闭后不会探测，也不会在电脑列表和详情中显示在线状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsFormStyle()
    }

    private var keyboardSettings: some View {
        Form {
            Section("增强系统捕获") {
                Toggle("启用增强快捷键捕获", isOn: $enhancedShortcutCapture)
                    .disabled(!enhancedCapturePermission.canUseEnhancedCapture)

                permissionRow("辅助功能", state: enhancedCapturePermission.accessibility)
                permissionRow("输入监控", state: enhancedCapturePermission.inputMonitoring)

                HStack {
                    Button("请求权限") {
                        enhancedCapturePermission.requestPermissions()
                    }
                    Button("打开系统隐私设置") {
                        enhancedCapturePermission.openPrivacySettings()
                    }
                    Button("刷新状态") {
                        enhancedCapturePermission.refresh()
                    }
                }

                if !enhancedCapturePermission.canUseEnhancedCapture {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("如果系统设置中的开关已开启，但这里仍显示未允许，请删除系统设置中的旧 Farframe RDP 条目，再添加当前正在运行的 App。Xcode 重新构建的临时签名副本可能会被 macOS 识别为新的授权对象。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("在访达中显示当前 App") {
                            enhancedCapturePermission.revealCurrentApplication()
                        }

                        Text(enhancedCapturePermission.applicationURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(enhancedCapturePermission.canUseEnhancedCapture
                    ? "权限已就绪。增强捕获只会在 Farframe 位于前台、会话已连接且远程画布聚焦时运行。"
                    : "权限未允许时，增强项保持不可用；Command-W 等应用内捕获仍正常工作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("快捷键捕获") {
                Text("语义快捷键优先于 Command 键的物理映射。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($shortcutSettings.policies) { $policy in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(
                                policy.displayName,
                                isOn: $policy.captureWhenRemoteFocused
                            )
                            .disabled(
                                policy.requiresEnhancedCapture &&
                                    (!enhancedCapturePermission.canUseEnhancedCapture || !enhancedShortcutCapture)
                            )

                            Spacer()

                            Text(policy.macChordDisplayName)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(policy.remoteChordDisplayName)
                                .font(.caption)
                            Spacer()
                            Picker("范围", selection: $policy.scope) {
                                ForEach(ShortcutCaptureScope.allCases) { scope in
                                    Text(scope.displayName).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            .disabled(
                                policy.requiresEnhancedCapture &&
                                    (!enhancedCapturePermission.canUseEnhancedCapture || !enhancedShortcutCapture)
                            )
                        }

                        if policy.requiresEnhancedCapture {
                            Label(
                                enhancedCapturePermission.canUseEnhancedCapture && enhancedShortcutCapture
                                    ? "增强捕获可用；系统保留组合仍可能不被 macOS 交付"
                                    : "需要启用增强捕获并允许系统权限",
                                systemImage: "lock.trianglebadge.exclamationmark"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Button("恢复快捷键默认设置") {
                    shortcutSettings.restoreDefaults()
                }
            }
        }
        .settingsFormStyle()
        .onAppear {
            enhancedCapturePermission.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enhancedCapturePermission.refresh()
        }
    }

    private func permissionRow(
        _ title: LocalizedStringKey,
        state: EnhancedCapturePermissionState
    ) -> some View {
        LabeledContent(title) {
            Label(
                state.isGranted ? "已允许" : "未允许",
                systemImage: state.isGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(state.isGranted ? .green : .secondary)
        }
    }
}

private extension LocalDataCategory {
    var localizedName: String {
        switch self {
        case .credentials: "钥匙串凭据"
        case .profilesAndCertificateTrust: "电脑配置与证书信任"
        case .preferences: "应用偏好"
        }
    }
}

private extension View {
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ShortcutSettingsStore())
        .environmentObject(EnhancedCapturePermissionModel())
}
