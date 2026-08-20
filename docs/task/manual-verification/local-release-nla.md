# 本地 Release NLA 人工验证

## 范围

验证 Xcode Release 构建在当前 ad-hoc、未公证发布阶段可以完成 FreeRDP NLA 连接，并确认关闭
Hardened Runtime 没有改变 TLS、NLA 或证书信任策略。

## 前置条件

- 已登录且解锁的 macOS 图形会话。
- Xcode 与项目固定的原生依赖已准备完成。
- 一台由测试人员提供且允许测试的 Windows RDP 主机。
- 使用专用测试账户；不要在截图、日志、命令参数或仓库中记录真实地址和凭据。

## 环境

- 配置：Release，保持 Swift `-O` 与 C/Objective-C `-Os` 优化。
- 签名：ad-hoc，未公证，无 Developer ID Application 证书。
- Hardened Runtime：关闭。
- App Sandbox：关闭。

## 操作与预期结果

1. 在 Xcode 中选择 FarframeRDP scheme 和 Release 配置，执行 Build。
   - 预期：构建成功，App 的签名标记为 ad-hoc，且不包含 runtime 标记。
2. 完全退出其他 Farframe RDP 实例，从 `Build/Products/Release` 启动 App。
   - 预期：App 正常启动，现有连接资料仍可读取。
3. 连接局域网中的测试主机，并按测试策略处理证书提示。
   - 预期：证书决定后 NLA 继续执行，不再出现由该构建差异引起的 `0x2000D`。
4. 验证远程桌面窗口出现并保持连接至少 30 秒。
   - 预期：可以看到远程画面，连接不会在初始化阶段退出。
5. 断开后再次连接一次。
   - 预期：保存的资料和证书信任按既有策略生效，连接再次成功。

## 应记录证据

- Release App 的版本、架构和 codesign flags。
- 连接成功/失败结果及脱敏错误阶段。
- TLS、NLA 和证书验证构建检查结果。

## 清理与恢复

- 断开测试会话并退出 App。
- 删除仅为本次验证创建的测试资料；如保存了密码，同时删除对应钥匙串项目。

## 当前执行状态

- 二分验证：已执行。优化 Release + Hardened Runtime 失败，优化 Release + ad-hoc 且无 Hardened
  Runtime 的 App 由测试人员确认可以正常连接。
- 正式配置重建：已执行。指定的 Xcode DerivedData `Build/Products/Release/FarframeRDP.app`
  已按 Swift `-O`、C `-Os`、ad-hoc 且无 Hardened Runtime 重建；严格签名校验通过。
- 自动化测试与安全设置检查：已通过。Core、App 和 Bridge 共 131 项测试通过；Release 检查确认
  TLS/NLA/证书弱化模式不存在，本地网络与麦克风用途说明仍然存在。
- 按正式配置重建后的真实会话：已由测试人员复验，确认可以正常连接和使用。
- `v0.1.8` 本地 Universal DMG：已构建并完成结构校验。DMG 内 App 版本为 `0.1.8`，包含
  `x86_64` 与 `arm64`，严格签名校验及 SHA-256 校验通过；签名仅含 ad-hoc 标记，不含
  Hardened Runtime 标记，本地网络用途说明存在。

## 已知限制与后续门槛

- 当前产物不是 Developer ID 签名且没有公证，Gatekeeper 体验不代表正式签名版本。
- 尚未单独执行“从 DMG 拖入 Applications 后再次连接”的人工验证；本次真实会话验证使用的是
  同一正式 Release 配置重建的 App，DMG 仅完成包内容与签名结构验证。
- Apple 公证要求 Developer ID 签名和 Hardened Runtime。取得证书后不得直接沿用当前设置；必须恢复
  Hardened Runtime，审计 FreeRDP/WinPR 所需的最小 runtime exception，并重新运行真实 NLA 验收。
