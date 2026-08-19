import AppKit
import FarframeCore
import SwiftData
import SwiftUI

enum ProfileEditorPurpose: Equatable {
    case createAndConnect
    case edit
}

private struct ProfileOptionRow<Control: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    let control: Control

    init(
        systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            control
                .frame(minWidth: 130, alignment: .trailing)
        }
    }
}

struct ProfileEditorView: View {
    let purpose: ProfileEditorPurpose
    let initialDraft: ConnectionProfileDraft
    let onSubmit: (ConnectionProfileDraft, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfileDraft
    @State private var portText: String
    @State private var password = ""
    @State private var savePassword = true
    @State private var validationMessage: String?
    @State private var selectedSection = EditorSection.general
    @State private var microphoneInputDevices: [MicrophoneInputDevice] = []
    @FocusState private var focusedField: Field?

    private enum Field {
        case displayName
        case host
        case username
        case password
    }

    private enum EditorSection: String, CaseIterable, Identifiable {
        case general
        case display
        case remoteApp
        case devicesAndAudio
        case folders

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "常规"
            case .display: "显示"
            case .remoteApp: "RemoteApp"
            case .devicesAndAudio: "设备和音频"
            case .folders: "文件夹"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .display: "display"
            case .remoteApp: "macwindow.on.rectangle"
            case .devicesAndAudio: "speaker.wave.2"
            case .folders: "folder"
            }
        }
    }

    init(
        purpose: ProfileEditorPurpose,
        draft: ConnectionProfileDraft,
        onSubmit: @escaping (ConnectionProfileDraft, String, Bool) -> Void
    ) {
        self.purpose = purpose
        self.initialDraft = draft
        self.onSubmit = onSubmit
        _draft = State(initialValue: draft)
        _portText = State(initialValue: String(draft.port))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FarframeWindowBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        sectionPicker
                        selectedPanel
                        if let validationMessage {
                            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(purpose == .createAndConnect ? "添加电脑" : "编辑电脑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .createAndConnect ? "连接" : "保存") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(
            width: 660,
            height: purpose == .createAndConnect ? 720 : 620
        )
        .onAppear {
            focusedField = purpose == .createAndConnect ? .displayName : nil
        }
        .onDisappear {
            password = ""
        }
    }

    private var sectionPicker: some View {
        Picker("电脑设置", selection: $selectedSection) {
            ForEach(EditorSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("profileEditor.sections")
        .animation(.easeInOut(duration: 0.16), value: selectedSection)
    }

    private var selectedPanel: some View {
        Group {
            switch selectedSection {
            case .general:
                VStack(spacing: 18) {
                    connectionPanel
                    gatewayPanel
                    reconnectPanel
                    if purpose == .createAndConnect {
                        credentialPanel
                    }
                }
            case .display:
                displayPanel
            case .remoteApp:
                remoteAppPanel
            case .devicesAndAudio:
                devicesAndAudioPanel
            case .folders:
                foldersPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(purpose == .createAndConnect ? "连接新的 Windows 电脑" : "电脑设置")
                    .font(.title3.weight(.semibold))
                Text("连接、显示与重定向选项仅应用于这台电脑。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("连接信息", systemImage: "network")
                .font(.headline)

            Text("用于识别并连接这台 Windows 电脑。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    Text("名称")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("例如：办公室电脑", text: $draft.displayName)
                        .focused($focusedField, equals: .displayName)
                }
                GridRow {
                    Text("主机")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("主机名或 IP 地址", text: $draft.host)
                        .textContentType(.URL)
                        .focused($focusedField, equals: .host)
                }
                GridRow {
                    Text("端口")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("3389", text: $portText)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                GridRow {
                    Text("用户名")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("Windows 用户名", text: $draft.username)
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                }
                GridRow {
                    Text("域")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("可选", text: $draft.domain)
                }
            }
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var credentialPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("凭据", systemImage: "key.fill")
                .font(.headline)
            SecureField("密码", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
            Toggle("将密码保存到 macOS 钥匙串", isOn: $savePassword)
            Text("只有连接认证成功后才会保存；证书信任是另一项独立决定。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var gatewayPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("RD Gateway", systemImage: "lock.laptopcomputer")
                .font(.headline)

            Toggle("通过 RD Gateway 连接", isOn: $draft.gatewayOptions.enabled)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    Text("网关")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField("网关主机名或 IP 地址", text: $draft.gatewayOptions.host)
                        .textContentType(.URL)
                        .disabled(!draft.gatewayOptions.enabled)
                }
                GridRow {
                    Text("端口")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Stepper(
                        "\(draft.gatewayOptions.port)",
                        value: $draft.gatewayOptions.port,
                        in: 1...65535
                    )
                    .frame(maxWidth: 160, alignment: .leading)
                    .disabled(!draft.gatewayOptions.enabled)
                }
                GridRow {
                    Text("凭据")
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Toggle("使用电脑登录凭据", isOn: $draft.gatewayOptions.useSameCredentials)
                        .disabled(!draft.gatewayOptions.enabled)
                }
                if !draft.gatewayOptions.useSameCredentials {
                    GridRow {
                        Text("用户")
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                        TextField("网关用户名", text: $draft.gatewayOptions.username)
                            .textContentType(.username)
                            .disabled(!draft.gatewayOptions.enabled)
                    }
                    GridRow {
                        Text("域")
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                        TextField("可选", text: $draft.gatewayOptions.domain)
                            .disabled(!draft.gatewayOptions.enabled)
                    }
                }
            }

            Text("网关密码仍使用当前连接凭据；独立网关密码将在 Keychain 账号分离后启用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var reconnectPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("自动重连", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            ProfileOptionRow(
                systemImage: "bolt.horizontal.circle",
                title: "网络短暂中断后重试",
                detail: "仅在已经连上后发生掉线时重试；认证、证书和配置错误不会自动重试。"
            ) {
                Toggle("自动重连", isOn: $draft.reconnectOptions.enabled)
                    .labelsHidden()
            }

            ProfileOptionRow(
                systemImage: "number.circle",
                title: "最多重试次数",
                detail: "每次重试都会创建新的 RDP 会话；断开按钮会取消等待中的下一次重连。"
            ) {
                Stepper(
                    "\(draft.reconnectOptions.maximumAttempts)",
                    value: $draft.reconnectOptions.maximumAttempts,
                    in: 1...5
                )
                .frame(maxWidth: 140, alignment: .leading)
                .disabled(!draft.reconnectOptions.enabled)
            }
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("显示设置", systemImage: "display")
                .font(.headline)

            ProfileOptionRow(
                systemImage: "arrow.up.left.and.arrow.down.right",
                title: "分辨率",
                detail: "适应窗口会按显示器物理像素生成清晰画面，并保持与 macOS 一致的界面缩放。"
            ) {
                Picker("分辨率", selection: $draft.desktopOptions.resolution) {
                    ForEach(RemoteResolutionOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 170)
            }

            ProfileOptionRow(
                systemImage: "rectangle.connected.to.line.below",
                title: "显示器范围",
                detail: "当前窗口保持原有单屏行为；全部显示器会按 macOS 屏幕布局发送多显示器坐标和主屏。"
            ) {
                Picker("显示器范围", selection: $draft.desktopOptions.monitorSelection) {
                    ForEach(RemoteMonitorSelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(draft.desktopOptions.resolution != .fitWindow)
            }

            ProfileOptionRow(
                systemImage: "gauge.with.dots.needle.50percent",
                title: "画面刷新率",
                detail: "控制本地 Metal 画面的最高呈现频率。自适应会跟随当前显示器；实际流畅度仍取决于远端帧率和网络。"
            ) {
                Picker("画面刷新率", selection: $draft.desktopOptions.presentationRate) {
                    ForEach(RemotePresentationRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 170)
            }
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var remoteAppPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("RemoteApp", systemImage: "macwindow.on.rectangle")
                .font(.headline)

            Toggle("启动单个远程应用", isOn: $draft.remoteAppOptions.enabled)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    Text("程序")
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    TextField("例如：||notepad 或 C:\\Windows\\System32\\notepad.exe", text: $draft.remoteAppOptions.program)
                        .disabled(!draft.remoteAppOptions.enabled)
                }
                GridRow {
                    Text("参数")
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    TextField("可选", text: $draft.remoteAppOptions.arguments)
                        .disabled(!draft.remoteAppOptions.enabled)
                }
                GridRow {
                    Text("工作目录")
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    TextField("可选", text: $draft.remoteAppOptions.workingDirectory)
                        .disabled(!draft.remoteAppOptions.enabled)
                }
            }

            Text("RemoteApp 需要服务器发布应用并支持 RAIL；不支持的服务器会在连接或启动阶段返回错误。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private var devicesAndAudioPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("设备和音频", systemImage: "speaker.wave.2")
                .font(.headline)

            ProfileOptionRow(
                systemImage: "doc.on.clipboard",
                title: "剪贴板",
                detail: "按方向同步选定内容。旧配置升级后仍仅启用纯文本；可在每次文件传输前确认。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用", isOn: $draft.redirectOptions.clipboardEnabled)

                    Picker("方向", selection: $draft.redirectOptions.clipboardDirection) {
                        Text("双向").tag(ClipboardTransferDirection.bidirectional)
                        Text("仅 Mac → Windows").tag(ClipboardTransferDirection.macToWindows)
                        Text("仅 Windows → Mac").tag(ClipboardTransferDirection.windowsToMac)
                    }
                    .frame(width: 190)
                    .disabled(!draft.redirectOptions.clipboardEnabled)

                    Toggle("纯文本", isOn: $draft.redirectOptions.clipboardText)
                        .disabled(!draft.redirectOptions.clipboardEnabled)
                    Toggle("格式化文本", isOn: $draft.redirectOptions.clipboardFormattedText)
                        .disabled(!draft.redirectOptions.clipboardEnabled)
                    Toggle("图片", isOn: $draft.redirectOptions.clipboardImages)
                        .disabled(!draft.redirectOptions.clipboardEnabled)
                    Toggle("文件", isOn: $draft.redirectOptions.clipboardFiles)
                        .disabled(!draft.redirectOptions.clipboardEnabled)
                    Toggle("每次传输文件前询问", isOn: $draft.redirectOptions.confirmClipboardFiles)
                        .disabled(
                            !draft.redirectOptions.clipboardEnabled ||
                                !draft.redirectOptions.clipboardFiles
                        )
                }
                .frame(width: 250, alignment: .leading)
            }

            Divider()

            ProfileOptionRow(
                systemImage: "speaker.wave.2",
                title: "远端声音",
                detail: "在这台 Mac 当前的系统默认音频设备上播放远端声音。"
            ) {
                Picker("播放远端声音", selection: $draft.redirectOptions.audioPlayback) {
                    Text("不播放").tag(false)
                    Text("这台 Mac").tag(true)
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Divider()

            ProfileOptionRow(
                systemImage: "mic",
                title: "麦克风",
                detail: "将这台 Mac 的默认输入设备重定向到远端；macOS 权限被拒绝时不影响普通桌面连接。"
            ) {
                Toggle("重定向麦克风", isOn: $draft.redirectOptions.microphoneRedirection)
                    .labelsHidden()
            }

            if draft.redirectOptions.microphoneRedirection {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                    GridRow {
                        Text("设备")
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                        Picker("麦克风设备", selection: $draft.redirectOptions.microphoneDeviceName) {
                            ForEach(microphoneDeviceMenuOptions) { option in
                                Text(option.title).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
                Text(microphoneInputDevices.isEmpty
                    ? "未枚举到输入设备；选择默认输入设备时仍由 FreeRDP macOS 后端在连接时使用系统默认输入。"
                    : "设备列表来自 macOS 当前输入设备；默认输入设备会跟随系统设置变化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .farframeGlassPanel()
        .onAppear(perform: refreshMicrophoneInputDevices)
        .onChange(of: draft.redirectOptions.microphoneRedirection) { _, isEnabled in
            if isEnabled {
                refreshMicrophoneInputDevices()
            }
        }
    }

    private var microphoneDeviceMenuOptions: [MicrophoneDeviceMenuOption] {
        MicrophoneDeviceMenuOption.options(
            availableDevices: microphoneInputDevices,
            savedSelection: draft.redirectOptions.microphoneDeviceName
        )
    }

    private func refreshMicrophoneInputDevices() {
        microphoneInputDevices = MicrophoneInputDeviceSource.availableDevices()
    }

    private var foldersPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("文件夹重定向", systemImage: "folder")
                .font(.headline)

            ProfileOptionRow(
                systemImage: "folder.badge.gearshape",
                title: "在 Windows 中访问本地文件夹",
                detail: "只向当前电脑授权一个目录；远端显示为 Farframe。"
            ) {
                Toggle(
                    "重定向一个本地文件夹",
                    isOn: $draft.redirectOptions.directoryRedirectionEnabled
                )
                .labelsHidden()
                .disabled(draft.redirectOptions.redirectedDirectoryPath.isEmpty)
            }

            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(
                    draft.redirectOptions.redirectedDirectoryPath.isEmpty
                        ? "尚未选择文件夹"
                        : draft.redirectOptions.redirectedDirectoryPath
                )
                .foregroundStyle(
                    draft.redirectOptions.redirectedDirectoryPath.isEmpty ? .secondary : .primary
                )
                .lineLimit(1)
                .truncationMode(.middle)

                Spacer()

                Button("选择…") {
                    chooseRedirectedDirectory()
                }

                Button("清除") {
                    draft.redirectOptions.redirectedDirectoryPath = ""
                    draft.redirectOptions.directoryRedirectionEnabled = false
                }
                .disabled(draft.redirectOptions.redirectedDirectoryPath.isEmpty)
            }
            .padding(12)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

            Text("不会共享主目录、其他磁盘、打印机、智能卡或 USB。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .farframeGlassPanel()
    }

    private func chooseRedirectedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        panel.message = "选择一个只授权给当前电脑的本地目录。"
        if panel.runModal() == .OK, let url = panel.url {
            draft.redirectOptions.redirectedDirectoryPath = url.path
            draft.redirectOptions.directoryRedirectionEnabled = true
        }
    }

    private func submit() {
        validationMessage = nil
        guard let port = Int(portText) else {
            validationMessage = String(localized: "端口必须是 1 到 65535 之间的数字。")
            return
        }
        draft.port = port
        do {
            let result = try draft.validated()
            onSubmit(result.draft, password, savePassword)
            password = ""
            dismiss()
        } catch {
            validationMessage = profileValidationMessage(error)
        }
    }
}

enum CredentialPromptPurpose: Equatable {
    case connect
    case update
}

struct CredentialPromptView: View {
    let purpose: CredentialPromptPurpose
    let profileName: String
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var savePassword = true
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(purpose == .connect ? "输入凭据" : "更新保存的密码")
                        .font(.title3.weight(.semibold))
                    Text(profileName)
                        .foregroundStyle(.secondary)
                }
            }

            SecureField("密码", text: $password)
                .textContentType(.password)
                .focused($passwordFocused)
            Toggle("保存到 macOS 钥匙串", isOn: $savePassword)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(purpose == .connect ? "连接" : "更新") {
                    onSubmit(password, savePassword)
                    password = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(FarframeWindowBackground())
        .onAppear { passwordFocused = true }
        .onDisappear { password = "" }
    }
}

private extension HostReachabilityState {
    var trafficLightColor: Color {
        switch self {
        case .possiblyOnline, .recentlyConnected:
            Color(nsColor: .systemGreen)
        case .unreachable:
            Color(nsColor: .systemYellow)
        case .unchecked, .checking:
            .secondary
        }
    }
}

struct ProfileSidebarRow: View {
    let profile: ConnectionProfile
    let reachability: HostReachabilityState
    let showsReachability: Bool
    let credential: CredentialAvailability
    let isActive: Bool
    let phase: SessionPhase

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "desktopcomputer")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(profile.addressSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isActive && phase != .connected {
                ProgressView()
                    .controlSize(.small)
            } else if showsReachability {
                Image(systemName: reachability.symbolName)
                    .font(.caption)
                    .foregroundStyle(reachability.trafficLightColor)
                    .help(reachability.title)
            }
            if credential == .saved {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("密码已保存到钥匙串")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }
}

struct ProfileDetailView: View {
    let profile: ConnectionProfile
    let reachability: HostReachabilityState
    let showsReachability: Bool
    let credential: CredentialAvailability
    let isActive: Bool
    let phase: SessionPhase
    let failureMessage: String?
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onEdit: () -> Void
    let onUpdatePassword: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.displayName)
                            .font(.largeTitle.weight(.semibold))
                        Text(profile.addressSummary)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if showsReachability {
                            statusPill(
                                reachability.title,
                                symbol: reachability.symbolName,
                                symbolColor: reachability.trafficLightColor
                            )
                                .padding(.top, 5)
                        }
                    }
                    Spacer()
                    if isActive {
                        Button("取消/断开", role: .destructive, action: onCancel)
                    } else {
                        Button("连接", action: onConnect)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }

                HStack(spacing: 12) {
                    statusPill(
                        credential == .saved ? "密码已保存" : "需要密码",
                        symbol: credential == .saved ? "key.fill" : "key.slash"
                    )
                    if isActive {
                        statusPill(phaseTitle, symbol: phase == .connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Label("连接详情", systemImage: "info.circle")
                        .font(.headline)
                    detailRow("用户", value: profile.accountSummary, symbol: "person")
                    detailRow("地址", value: profile.addressSummary, symbol: "network")
                    if ConnectionProfileDraft(profile: profile).gatewayOptions.enabled {
                        detailRow(
                            "RD Gateway",
                            value: ConnectionProfileDraft(profile: profile).gatewayOptions.host,
                            symbol: "lock.laptopcomputer"
                        )
                    }
                    if ConnectionProfileDraft(profile: profile).remoteAppOptions.enabled {
                        detailRow(
                            "RemoteApp",
                            value: ConnectionProfileDraft(profile: profile).remoteAppOptions.program,
                            symbol: "macwindow.on.rectangle"
                        )
                    }
                    if ConnectionProfileDraft(profile: profile).reconnectOptions.enabled {
                        detailRow(
                            "自动重连",
                            value: "最多 \(ConnectionProfileDraft(profile: profile).reconnectOptions.maximumAttempts) 次",
                            symbol: "arrow.triangle.2.circlepath"
                        )
                    }
                    detailRow(
                        "分辨率",
                        value: ConnectionProfileDraft(profile: profile).desktopOptions.resolution.title,
                        symbol: "arrow.up.left.and.arrow.down.right"
                    )
                    detailRow(
                        "显示器范围",
                        value: ConnectionProfileDraft(profile: profile).desktopOptions.monitorSelection.title,
                        symbol: "rectangle.connected.to.line.below"
                    )
                    detailRow(
                        "画面刷新率",
                        value: ConnectionProfileDraft(profile: profile).desktopOptions.presentationRate.title,
                        symbol: "gauge.with.dots.needle.50percent"
                    )
                    if ConnectionProfileDraft(profile: profile).redirectOptions.microphoneRedirection {
                        detailRow(
                            "麦克风",
                            value: ConnectionProfileDraft(profile: profile).redirectOptions.microphoneDeviceName.isEmpty
                                ? "默认输入设备"
                                : ConnectionProfileDraft(profile: profile).redirectOptions.microphoneDeviceName,
                            symbol: "mic"
                        )
                    }
                    detailRow(
                        "上次成功连接",
                        value: profile.lastSuccessfulConnection?.formatted(date: .abbreviated, time: .shortened) ?? "尚未连接",
                        symbol: "clock"
                    )
                    Divider()
                    HStack {
                        Button("编辑", systemImage: "slider.horizontal.3", action: onEdit)
                        Button("更新密码", systemImage: "key", action: onUpdatePassword)
                        Spacer()
                    }
                }
                .padding(22)
                .farframeGlassPanel()

                if let warning = profile.lastConnectionWarning ?? failureMessage {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }

                if showsReachability {
                    Text("在线状态只是目标端口可达性提示。即使显示不可达，也始终可以尝试真实 RDP 连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func statusPill(
        _ title: String,
        symbol: String,
        symbolColor: Color = .primary
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: "就绪"
        case .resolving: "正在解析主机…"
        case .connecting: "正在连接…"
        case .authenticating: "正在认证…"
        case .connected: "已连接"
        case .reconnecting: "正在重新连接…"
        case .disconnecting: "正在断开…"
        case .disconnected: "已断开"
        case .failed: "连接失败"
        }
    }
}

func profileValidationMessage(_ error: Error) -> String {
    switch error as? ConnectionProfileValidationError {
    case .emptyDisplayName:
        String(localized: "请输入电脑名称。")
    case .displayNameTooLong:
        String(localized: "电脑名称超过支持的长度。")
    case .invalidRemoteAppConfiguration:
        String(localized: "RemoteApp 程序不能为空，程序、参数和工作目录均不能超过 4096 字节。")
    case .invalidMicrophoneConfiguration:
        String(localized: "麦克风设备名超过支持的长度。")
    case let .invalidEndpoint(endpointError):
        switch endpointError {
        case .emptyHost:
            String(localized: "请输入主机名或 IP 地址。")
        case .invalidPort:
            String(localized: "端口必须是 1 到 65535 之间的数字。")
        case .emptyUsername:
            String(localized: "请输入用户名。")
        case .valueTooLong:
            String(localized: "一个或多个连接字段超过支持的长度。")
        }
    case nil:
        String(localized: "连接配置无效。")
    }
}
