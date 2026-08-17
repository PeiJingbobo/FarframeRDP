import AppKit
import FarframeCore
import FarframeRDPBridge
import SwiftData
import SwiftUI

private struct ProfileEditorRequest: Identifiable {
    let id = UUID()
    let profileID: UUID?
}

private struct CredentialRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let purpose: CredentialPromptPurpose
}

private struct ProfileDeletionRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
}

private struct UserNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct EnhancedCaptureSynchronizationModifier: ViewModifier {
    @ObservedObject var permission: EnhancedCapturePermissionModel
    let manager: RemoteSessionWindowManager
    let userEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: userEnabled) { _, enabled in
                manager.enhancedCaptureEnabled = enabled
            }
            .onChange(of: permission.canUseEnhancedCapture) { _, granted in
                manager.enhancedCapturePermissionGranted = granted
            }
    }
}

private struct PendingConnection {
    var profileID: UUID?
    var draft: ConnectionProfileDraft?
    var passwordToSave: String?
    var certificateFingerprint: String?

    mutating func clearPassword() {
        passwordToSave = nil
    }
}

@MainActor
struct ConnectionLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var shortcutSettings: ShortcutSettingsStore
    @EnvironmentObject private var enhancedCapturePermission: EnhancedCapturePermissionModel
    @Query(sort: [SortDescriptor(\ConnectionProfile.displayName)]) private var profiles: [ConnectionProfile]

    @StateObject private var remoteWindowManager = RemoteSessionWindowManager()
    @StateObject private var sessionCoordinator = SessionCoordinator()
    @StateObject private var clipboardController = RemoteClipboardController()
    @StateObject private var libraryController: ProfileLibraryController

    @AppStorage(ApplicationPreferenceKeys.automaticHostStatusChecks) private var automaticHostStatusChecks = true
    @AppStorage(ApplicationPreferenceKeys.enhancedShortcutCapture) private var enhancedShortcutCapture = false
    @State private var selectedProfileID: UUID?
    @State private var activeProfileID: UUID?
    @State private var editorRequest: ProfileEditorRequest?
    @State private var credentialRequest: CredentialRequest?
    @State private var deletionRequest: ProfileDeletionRequest?
    @State private var pendingConnection: PendingConnection?
    @State private var notice: UserNotice?

    init(libraryController: ProfileLibraryController = ProfileLibraryController()) {
        _libraryController = StateObject(wrappedValue: libraryController)
    }

    var body: some View {
        libraryNavigation
        .sheet(item: $editorRequest, content: editorSheet)
        .sheet(item: $credentialRequest, content: credentialSheet)
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "删除电脑？",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionRequest
        ) { request in
            Button("删除电脑及其凭据", role: .destructive) {
                deleteProfile(id: request.profileID)
            }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text("将删除 \(findProfile(id: request.profileID)?.displayName ?? "此电脑")、保存的密码和该电脑的证书信任记录。")
        }
        .alert(
            certificateTitle,
            isPresented: Binding(
                get: { visibleCertificateChallenge != nil },
                set: { presented in
                    if !presented && sessionCoordinator.certificateChallenge != nil {
                        sessionCoordinator.resolveCertificate(FFR_CERTIFICATE_REJECT)
                    }
                }
            ),
            presenting: visibleCertificateChallenge
        ) { _ in
            Button("拒绝", role: .cancel) {
                sessionCoordinator.resolveCertificate(FFR_CERTIFICATE_REJECT)
            }
            Button("仅本次信任") {
                sessionCoordinator.resolveCertificate(FFR_CERTIFICATE_ACCEPT_FOR_SESSION)
            }
            Button("信任并记住") {
                rememberCertificateAndContinue()
            }
        } message: { challenge in
            Text(certificateMessage(challenge))
        }
        .onAppear(perform: configureSession)
        .onDisappear(perform: tearDownSession)
        .onReceive(NotificationCenter.default.publisher(for: .farframeWillClearLocalData)) { _ in
            tearDownSession()
            selectedProfileID = nil
            activeProfileID = nil
            pendingConnection?.clearPassword()
            pendingConnection = nil
        }
        .onChange(of: shortcutSettings.policies) { _, policies in
            remoteWindowManager.shortcutPolicies = policies
        }
        .modifier(EnhancedCaptureSynchronizationModifier(
            permission: enhancedCapturePermission,
            manager: remoteWindowManager,
            userEnabled: enhancedShortcutCapture
        ))
        .onChange(of: sessionCoordinator.phase) { _, phase in
            handleSessionPhase(phase)
        }
        .onChange(of: sessionCoordinator.certificateChallenge) { _, challenge in
            automaticallyResolveTrustedCertificate(challenge)
        }
        .onChange(of: automaticHostStatusChecks) { _, enabled in
            libraryController.refresh(profiles: profiles, automaticReachability: enabled)
        }
        .onChange(of: profileRefreshKey) { _, _ in
            if selectedProfileID == nil {
                selectedProfileID = profiles.first?.id
            }
            libraryController.refresh(
                profiles: profiles,
                automaticReachability: automaticHostStatusChecks
            )
        }
        .task {
            if selectedProfileID == nil {
                selectedProfileID = profiles.first?.id
            }
            libraryController.refresh(
                profiles: profiles,
                automaticReachability: automaticHostStatusChecks
            )
        }
    }

    private var libraryNavigation: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ZStack {
                FarframeWindowBackground()
                detail
            }
        }
        .navigationTitle("Farframe RDP")
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.sendAction(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        to: nil,
                        from: nil
                    )
                } label: {
                    Label("显示或隐藏侧边栏", systemImage: "sidebar.left")
                }
                .focusable(false)
                .help("显示或隐藏侧边栏")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    libraryController.refresh(
                        profiles: profiles,
                        automaticReachability: automaticHostStatusChecks
                    )
                } label: {
                    Label(
                        automaticHostStatusChecks ? "刷新状态" : "刷新凭据",
                        systemImage: "arrow.clockwise"
                    )
                }
                .help(
                    automaticHostStatusChecks
                        ? "刷新凭据与可达性状态"
                        : "刷新凭据状态"
                )

                Button {
                    editorRequest = ProfileEditorRequest(profileID: nil)
                } label: {
                    Label("添加电脑", systemImage: "plus")
                }
                .help("添加电脑")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedProfileID) {
            Section("电脑") {
                if profiles.isEmpty {
                    Text("尚未添加电脑")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        ProfileSidebarRow(
                            profile: profile,
                            reachability: libraryController.reachability[profile.id] ?? .unchecked,
                            showsReachability: automaticHostStatusChecks,
                            credential: libraryController.credentialAvailability[profile.id] ?? .unknown,
                            isActive: activeProfileID == profile.id && sessionCoordinator.isActive,
                            phase: sessionCoordinator.phase
                        )
                        .tag(profile.id)
                        .contextMenu {
                            Button("连接") { connect(profile) }
                            Divider()
                            Button("编辑…") {
                                selectedProfileID = profile.id
                                editorRequest = ProfileEditorRequest(profileID: profile.id)
                            }
                            Button("更新密码…") {
                                credentialRequest = CredentialRequest(profileID: profile.id, purpose: .update)
                            }
                            Button("删除保存的密码", role: .destructive) {
                                deleteSavedPassword(profileID: profile.id)
                            }
                            Divider()
                            Button("删除电脑…", role: .destructive) {
                                deletionRequest = ProfileDeletionRequest(profileID: profile.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedProfile {
            ProfileDetailView(
                profile: selectedProfile,
                reachability: libraryController.reachability[selectedProfile.id] ?? .unchecked,
                showsReachability: automaticHostStatusChecks,
                credential: libraryController.credentialAvailability[selectedProfile.id] ?? .unknown,
                isActive: activeProfileID == selectedProfile.id && sessionCoordinator.isActive,
                phase: sessionCoordinator.phase,
                failureMessage: activeProfileID == selectedProfile.id ? connectionFailureMessage : nil,
                onConnect: { connect(selectedProfile) },
                onCancel: cancelConnection,
                onEdit: { editorRequest = ProfileEditorRequest(profileID: selectedProfile.id) },
                onUpdatePassword: {
                    credentialRequest = CredentialRequest(profileID: selectedProfile.id, purpose: .update)
                }
            )
        } else {
            ContentUnavailableView {
                Label("添加第一台电脑", systemImage: "desktopcomputer.and.arrow.down")
            } description: {
                Text("保存连接配置后，在侧边栏选择电脑并从详情页发起连接。")
            } actions: {
                Button("添加电脑") {
                    editorRequest = ProfileEditorRequest(profileID: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var selectedProfile: ConnectionProfile? {
        guard let selectedProfileID else { return nil }
        return findProfile(id: selectedProfileID)
    }

    private var profileRefreshKey: String {
        profiles.map { "\($0.id.uuidString):\($0.modifiedAt.timeIntervalSinceReferenceDate)" }
            .joined(separator: "|")
    }

    private func findProfile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    private func editorSheet(_ request: ProfileEditorRequest) -> some View {
        let existing = request.profileID.flatMap(findProfile(id:))
        return ProfileEditorView(
            purpose: existing == nil ? .createAndConnect : .edit,
            draft: existing.map(ConnectionProfileDraft.init(profile:)) ?? ConnectionProfileDraft()
        ) { draft, password, savePassword in
            if let existing {
                updateProfile(existing, draft: draft)
            } else {
                beginConnection(
                    endpointDraft: draft,
                    profileID: nil,
                    password: password,
                    savePassword: savePassword
                )
            }
        }
    }

    private func credentialSheet(_ request: CredentialRequest) -> some View {
        let name = findProfile(id: request.profileID)?.displayName ?? String(localized: "电脑")
        return CredentialPromptView(purpose: request.purpose, profileName: name) { password, save in
            switch request.purpose {
            case .connect:
                guard let profile = findProfile(id: request.profileID) else { return }
                beginConnection(
                    endpointDraft: ConnectionProfileDraft(profile: profile),
                    profileID: profile.id,
                    password: password,
                    savePassword: save
                )
            case .update:
                updatePassword(password, save: save, profileID: request.profileID)
            }
        }
    }

    private func configureSession() {
        remoteWindowManager.shortcutPolicies = shortcutSettings.policies
        remoteWindowManager.enhancedCaptureEnabled = enhancedShortcutCapture
        remoteWindowManager.enhancedCapturePermissionGranted = enhancedCapturePermission.canUseEnhancedCapture
        remoteWindowManager.onWindowClosed = {
            sessionCoordinator.cancel()
        }
        remoteWindowManager.onInput = { command in
            sessionCoordinator.sendInput(command)
        }
        remoteWindowManager.onViewportLayout = { layouts in
            sessionCoordinator.requestMonitorLayout(layouts)
        }
        sessionCoordinator.localClipboardTextProvider = {
            clipboardController.currentText()
        }
        sessionCoordinator.onDesktopSizeChange = { size in
            remoteWindowManager.announceDesktopSize(size)
        }
        sessionCoordinator.onDynamicResolutionReady = {
            remoteWindowManager.displayControlDidBecomeReady()
        }
        sessionCoordinator.onFrameUpdate = { size, rect, pixels, bytesPerRow, sequenceNumber in
            remoteWindowManager.display(
                desktopSize: size,
                dirtyRect: rect,
                pixels: pixels,
                bytesPerRow: bytesPerRow,
                sequenceNumber: sequenceNumber
            )
        }
        sessionCoordinator.onCursorUpdate = { update in
            remoteWindowManager.applyCursorUpdate(update)
        }
    }

    private func tearDownSession() {
        remoteWindowManager.onWindowClosed = nil
        remoteWindowManager.onInput = nil
        remoteWindowManager.onViewportResize = nil
        remoteWindowManager.onViewportLayout = nil
        sessionCoordinator.onDesktopSizeChange = nil
        sessionCoordinator.onDynamicResolutionReady = nil
        sessionCoordinator.onFrameUpdate = nil
        sessionCoordinator.onCursorUpdate = nil
        sessionCoordinator.onClipboardTextReceived = nil
        sessionCoordinator.localClipboardTextProvider = nil
        clipboardController.stop()
        pendingConnection?.clearPassword()
        pendingConnection = nil
        sessionCoordinator.cancel()
        remoteWindowManager.closeRemoteWindow()
    }

    private func connect(_ profile: ConnectionProfile) {
        selectedProfileID = profile.id
        guard !sessionCoordinator.isActive else {
            if activeProfileID != profile.id {
                showNotice(
                    title: "已有活动会话",
                    message: "请先断开当前会话，再连接另一台电脑。"
                )
            }
            return
        }

        activeProfileID = profile.id
        Task {
            do {
                if let password = try await libraryController.vault.password(for: profile.id) {
                    beginConnection(
                        endpointDraft: ConnectionProfileDraft(profile: profile),
                        profileID: profile.id,
                        password: password,
                        savePassword: false
                    )
                } else {
                    libraryController.markCredential(.missing, for: profile.id)
                    credentialRequest = CredentialRequest(profileID: profile.id, purpose: .connect)
                }
            } catch {
                libraryController.markCredential(.unavailable, for: profile.id)
                showNotice(
                    title: "无法读取保存的密码",
                    message: error.localizedDescription + " 你仍可手动输入密码继续连接。"
                )
                credentialRequest = CredentialRequest(profileID: profile.id, purpose: .connect)
            }
        }
    }

    private func beginConnection(
        endpointDraft draft: ConnectionProfileDraft,
        profileID: UUID?,
        password: String,
        savePassword: Bool
    ) {
        guard !sessionCoordinator.isActive else {
            showNotice(title: "已有活动会话", message: "请先断开当前会话。")
            return
        }
        do {
            let result = try draft.validated()
            activeProfileID = profileID
            remoteWindowManager.monitorSelection = result.draft.desktopOptions.monitorSelection
            remoteWindowManager.resolution = result.draft.desktopOptions.resolution
            remoteWindowManager.presentationRate = result.draft.desktopOptions.presentationRate
            pendingConnection = PendingConnection(
                profileID: profileID,
                draft: profileID == nil ? result.draft : nil,
                passwordToSave: savePassword ? password : nil,
                certificateFingerprint: nil
            )
            if result.draft.redirectOptions.clipboardText {
                clipboardController.onLocalTextChange = { text in
                    sessionCoordinator.publishClipboardText(text)
                }
                sessionCoordinator.onClipboardTextReceived = { text in
                    clipboardController.applyRemoteText(text)
                }
                sessionCoordinator.localClipboardTextProvider = {
                    clipboardController.currentText()
                }
                clipboardController.start()
            } else {
                clipboardController.stop()
                sessionCoordinator.onClipboardTextReceived = nil
                sessionCoordinator.localClipboardTextProvider = nil
            }
            sessionCoordinator.connect(
                endpoint: result.endpoint,
                password: password,
                channelOptions: result.draft.channelOptions,
                reconnectPolicy: result.draft.reconnectOptions.policy
            )
        } catch {
            activeProfileID = nil
            showNotice(title: "连接配置无效", message: profileValidationMessage(error))
        }
    }

    private func cancelConnection() {
        pendingConnection?.clearPassword()
        pendingConnection = nil
        sessionCoordinator.cancel()
        remoteWindowManager.closeRemoteWindow()
    }

    private func handleSessionPhase(_ phase: SessionPhase) {
        remoteWindowManager.sessionIsConnected = phase == .connected
        switch phase {
        case .connected:
            remoteWindowManager.openRemoteWindow()
            finalizeSuccessfulConnection()
        case .failed:
            remoteWindowManager.closeRemoteWindow()
            clipboardController.stop()
            pendingConnection?.clearPassword()
            pendingConnection = nil
            recordConnectionWarning()
        case .disconnecting, .disconnected:
            remoteWindowManager.closeRemoteWindow()
            if phase == .disconnected {
                clipboardController.stop()
                pendingConnection?.clearPassword()
                pendingConnection = nil
            }
        default:
            break
        }
    }

    private func finalizeSuccessfulConnection() {
        guard var pending = pendingConnection else { return }
        pendingConnection = nil
        let now = Date()
        let profile: ConnectionProfile

        if let profileID = pending.profileID, let existing = findProfile(id: profileID) {
            profile = existing
        } else if let draft = pending.draft {
            profile = ConnectionProfile(
                draft: draft,
                certificateTrustReference: pending.certificateFingerprint,
                lastSuccessfulConnection: now,
                now: now
            )
            modelContext.insert(profile)
            activeProfileID = profile.id
            selectedProfileID = profile.id
        } else {
            pending.clearPassword()
            return
        }

        profile.lastSuccessfulConnection = now
        profile.lastConnectionWarning = nil
        profile.modifiedAt = now
        if let fingerprint = pending.certificateFingerprint {
            profile.certificateTrustReference = fingerprint
        }

        do {
            try modelContext.save()
            libraryController.markConnected(profileID: profile.id)
        } catch {
            modelContext.rollback()
            pending.clearPassword()
            showNotice(title: "无法保存电脑", message: error.localizedDescription)
            return
        }

        if let password = pending.passwordToSave {
            pending.clearPassword()
            Task {
                do {
                    try await libraryController.vault.save(password: password, for: profile.id)
                    libraryController.markCredential(.saved, for: profile.id)
                } catch {
                    libraryController.markCredential(.unavailable, for: profile.id)
                    showNotice(
                        title: "连接成功，但密码未保存",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func updateProfile(_ profile: ConnectionProfile, draft: ConnectionProfileDraft) {
        do {
            let validated = try draft.validated().draft
            let endpointChanged = profile.host != validated.host || profile.port != validated.port
            profile.apply(validated)
            if endpointChanged {
                profile.certificateTrustReference = nil
                profile.lastConnectionWarning = nil
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            showNotice(title: "无法保存电脑", message: profileValidationMessage(error))
        }
    }

    private func updatePassword(_ password: String, save: Bool, profileID: UUID) {
        guard save else {
            showNotice(title: "密码未保存", message: "打开“保存到 macOS 钥匙串”后才能更新保存的密码。")
            return
        }
        Task {
            do {
                try await libraryController.vault.save(password: password, for: profileID)
                libraryController.markCredential(.saved, for: profileID)
            } catch {
                libraryController.markCredential(.unavailable, for: profileID)
                showNotice(title: "无法更新密码", message: error.localizedDescription)
            }
        }
    }

    private func deleteSavedPassword(profileID: UUID) {
        Task {
            do {
                try await libraryController.vault.deletePassword(for: profileID)
                libraryController.markCredential(.missing, for: profileID)
            } catch {
                showNotice(title: "无法删除保存的密码", message: error.localizedDescription)
            }
        }
    }

    private func deleteProfile(id: UUID) {
        deletionRequest = nil
        guard let profile = findProfile(id: id) else { return }
        guard activeProfileID != id || !sessionCoordinator.isActive else {
            showNotice(title: "无法删除正在连接的电脑", message: "请先断开会话，再删除电脑。")
            return
        }

        Task {
            do {
                try await libraryController.vault.deletePassword(for: id)
            } catch {
                showNotice(
                    title: "未删除电脑",
                    message: "保存的密码删除失败，因此电脑配置仍被保留。\n\n\(error.localizedDescription)"
                )
                return
            }

            modelContext.delete(profile)
            do {
                try modelContext.save()
                libraryController.remove(profileID: id)
                if selectedProfileID == id {
                    selectedProfileID = profiles.first { $0.id != id }?.id
                }
            } catch {
                modelContext.rollback()
                showNotice(
                    title: "电脑删除不完整",
                    message: "密码已从钥匙串删除，但电脑配置未能删除。你可以重试。\n\n\(error.localizedDescription)"
                )
            }
        }
    }

    private var visibleCertificateChallenge: CertificateChallenge? {
        guard let challenge = sessionCoordinator.certificateChallenge else { return nil }
        let trusted = activeProfileID.flatMap(findProfile(id:))?.certificateTrustReference
        if RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: trusted,
            challengeFingerprint: challenge.fingerprint
        ) {
            return nil
        }
        guard let trusted, trusted != challenge.fingerprint else {
            return challenge
        }
        return CertificateChallenge(
            hostname: challenge.hostname,
            port: challenge.port,
            commonName: challenge.commonName,
            subject: challenge.subject,
            issuer: challenge.issuer,
            fingerprint: challenge.fingerprint,
            oldSubject: challenge.oldSubject,
            oldIssuer: challenge.oldIssuer,
            oldFingerprint: trusted,
            hostnameMismatch: challenge.hostnameMismatch,
            changed: true
        )
    }

    private func automaticallyResolveTrustedCertificate(_ challenge: CertificateChallenge?) {
        guard let challenge else {
            return
        }
        let trusted = activeProfileID.flatMap(findProfile(id:))?.certificateTrustReference
        guard RememberedCertificateTrustPolicy.canAutomaticallyTrust(
            storedFingerprint: trusted,
            challengeFingerprint: challenge.fingerprint
        ) else { return }
        sessionCoordinator.resolveCertificate(FFR_CERTIFICATE_ACCEPT_FOR_SESSION)
    }

    private func rememberCertificateAndContinue() {
        guard let challenge = visibleCertificateChallenge else { return }
        if let profileID = activeProfileID, let profile = findProfile(id: profileID) {
            profile.certificateTrustReference = challenge.fingerprint
            profile.lastConnectionWarning = nil
            profile.modifiedAt = Date()
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                showNotice(
                    title: "无法记住证书",
                    message: "本次仍可继续连接，但证书指纹没有保存。\n\n\(error.localizedDescription)"
                )
            }
        } else {
            pendingConnection?.certificateFingerprint = challenge.fingerprint
        }
        sessionCoordinator.resolveCertificate(FFR_CERTIFICATE_ACCEPT_FOR_SESSION)
    }

    private func recordConnectionWarning() {
        guard let profileID = activeProfileID,
              let profile = findProfile(id: profileID),
              let failure = sessionCoordinator.failure else {
            return
        }
        if failure.message.contains("认证") || failure.message.contains("证书") {
            profile.lastConnectionWarning = failure.message
            profile.modifiedAt = Date()
            try? modelContext.save()
        }
    }

    private var connectionFailureMessage: String? {
        guard let failure = sessionCoordinator.failure else { return nil }
        guard failure.nativeCode != 0 else { return failure.message }
        return "\(failure.message)（错误代码 0x\(String(failure.nativeCode, radix: 16, uppercase: true))）"
    }

    private var certificateTitle: String {
        visibleCertificateChallenge?.changed == true
            ? String(localized: "远程证书已更改")
            : String(localized: "验证远程证书")
    }

    private func certificateMessage(_ challenge: CertificateChallenge) -> String {
        var lines = [
            "\(String(localized: "主机"))：\(challenge.hostname):\(challenge.port)",
            "\(String(localized: "通用名称"))：\(challenge.commonName)",
            "\(String(localized: "主题"))：\(challenge.subject)",
            "\(String(localized: "签发者"))：\(challenge.issuer)",
            "\(String(localized: "指纹"))：\(challenge.fingerprint)",
        ]
        if challenge.hostnameMismatch {
            lines.append(String(localized: "警告：证书名称与请求的主机不匹配。"))
        }
        if challenge.changed {
            lines.append(String(localized: "警告：此证书与之前信任的证书不同。"))
            if let oldFingerprint = challenge.oldFingerprint {
                lines.append("\(String(localized: "先前的指纹"))：\(oldFingerprint)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func showNotice(title: String, message: String) {
        notice = UserNotice(title: title, message: message)
    }
}
