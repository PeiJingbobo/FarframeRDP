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
- 发布工具链：Xcode 26.2（17C52），macOS SDK 26.2。

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
- `v0.1.8` GitHub Release 回归：失败。远端 App 仍在 NLA 阶段返回 `0x2000D`。二进制审计确认
  workflow 使用了 runner 的浮动默认 Xcode 26.6（17F113）和 macOS SDK 26.5，而本机通过验收的
  App 使用 Xcode 26.2（17C52）和 macOS SDK 26.2；签名及 Hardened Runtime 标记没有差异。
- 固定工具链候选：已使用 Xcode 26.2、SDK 26.2 和全量重建的双架构 OpenSSL/OpenH264/FreeRDP
  生成本地 Universal App；131 项测试、Release 安全检查、严格签名及 DMG 校验通过。测试人员已
  分别从候选 App 与 DMG 安装版本完成真实 NLA 连接，均可正常建立会话。
- `v0.1.9` 本地发布候选：版本、Xcode build `17C52`、SDK `macosx26.2`、`x86_64`/`arm64`
  架构、ad-hoc 签名和 SHA-256 均已校验通过；功能行为由上一项相同工具链候选的真实连接覆盖。
- `v0.1.9` GitHub Action：已成功完成并创建非 Draft、非 prerelease 的正式 Release。下载后的远端
  DMG 已通过 SHA-256、版本、Xcode build `17C52`、SDK `macosx26.2`、Universal 架构与严格签名
  校验；远端产物的真实 NLA 连接已由测试人员执行，结果为失败，仍返回 `0x2000D`。
- `v0.1.9` 安装产物诊断：系统日志确认本地网络路径最终为可用，目标 RDP 端口的 TCP 握手成功，
  因此失败不在权限、DNS 或端口可达性阶段。CI 二进制包含构建机 OpenSSL 安装目录和 provider
  目录的绝对路径，但 App 未携带 OpenSSL provider；运行进程也未加载 NLA/NTLM 所需的 legacy
  provider。本地可用构建则能从仍存在的本地依赖目录加载该 provider。当前证据将故障定位到
  TLS 建立后的 NLA/NTLM 密码摘要初始化阶段。
- 自包含 NLA 修复候选：已将 OpenSSL 改为固定逻辑前缀、无 legacy provider、无动态 module 的
  静态构建，并明确启用 WinPR 内置 MD4 与 RC4。原生 ASan/UBSan harness 在
  `OPENSSL_MODULES` 指向不存在目录时通过已知 NTLM hash 与 RC4 向量；131 项 Debug Xcode 测试、
  Release 安全设置检查、Universal Release 构建、严格签名、运行时依赖检查与 DMG 校验均通过。
  本地候选 DMG 的真实 NLA 连接已由测试人员执行，确认可以正常运行并建立连接。

## 已知限制与后续门槛

- 当前产物不是 Developer ID 签名且没有公证，Gatekeeper 体验不代表正式签名版本。
- 固定 Xcode 26.2 不能单独解决 CI 产物的 NLA 失败；自包含加密候选已通过本地 DMG 的真实连接
  验收，随后生成的 CI DMG 仍需完成同样的真实 NLA 连接验收。
- Apple 公证要求 Developer ID 签名和 Hardened Runtime。取得证书后不得直接沿用当前设置；必须恢复
  Hardened Runtime，审计 FreeRDP/WinPR 所需的最小 runtime exception，并重新运行真实 NLA 验收。
