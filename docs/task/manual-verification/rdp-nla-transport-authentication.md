# RDP NLA 身份兼容人工验证手册

## 元数据

- 任务标识：rdp-nla-transport-authentication
- 范围：0.1.6 的 Windows 身份格式规范化，以及 NLA 阶段 `0x2000D` 的错误分类
- 当前状态：自动化验证通过；真实 Windows TLS/NLA 登录待操作者执行

## 前置条件与安全测试数据

1. 使用 0.1.6 Universal DMG 中的 App，并在已解锁的 macOS 图形会话中运行。
2. 准备启用了 TLS/NLA 的 Windows 测试主机，以及权限可撤销的本地或域测试账号。
3. 不得把真实端点、用户名、域、密码或证书指纹写入命令、截图、日志或本文档。
4. 测试账号应同时准备一个正确密码和一个明确错误的临时密码输入。

## 操作和预期结果

| 步骤 | 操作 | 预期结果 | 状态 |
| --- | --- | --- | --- |
| 1 | 新建 Profile，在用户名填写 `DOMAIN\user` 形式，域留空，输入正确密码并连接 | 接受证书后完成 NLA 登录并打开远程桌面；Profile 保持可见 | 待执行 |
| 2 | 编辑同一 Profile，把用户名改为 `user`，域填写为 `DOMAIN`，再次连接 | 与步骤 1 使用相同身份完成登录 | 待执行 |
| 3 | 对支持 UPN 的测试账号填写 `user@domain`，域留空并连接 | UPN 保持为完整用户名，不被错误拆分，登录成功 | 待执行 |
| 4 | 使用错误密码连接 | 不发生无限重试；如果 FreeRDP 原生码为 `0x2000D` 且失败发生于 NLA，界面明确提示身份认证失败和检查用户名、域、密码 | 待执行 |
| 5 | 使用不可达地址或关闭的端口连接 | 仍显示网络不可达类错误，不被误归类为身份认证失败 | 待执行 |
| 6 | 从旧版本保留的 Profile 连接，然后退出并重新启动 App 再连接 | Profile、证书信任和 Keychain 凭据保持有效 | 待执行 |

## 自动化证据

- Native Bridge Sanitizer harness 验证 `DOMAIN\user` 被拆分为 `DOMAIN` 与 `user`。
- Native Bridge 单元断言验证仅 NLA 状态的 `0x2000D` 映射为认证失败，协商阶段的同一码仍映射为网络失败。
- 完整 Xcode 测试覆盖 Profile、证书、Keychain、Bridge 生命周期及现有连接设置回归。

## 本次执行记录

- 执行日期：2026-08-20。
- `/bin/sh scripts/test-native-bridge.sh`：通过。
- `xcodebuild ... test`：FarframeCore 14 项、FarframeRDP 107 项、Bridge 9 项通过，0 失败。
- `/bin/sh scripts/package-release.sh v0.1.6`：通过；版本匹配、Universal `x86_64 arm64`、严格 ad-hoc 签名、静态 add-in 与 DMG 校验均通过。
- 从本地 DMG 直接启动 Apple Silicon slice 并保持运行 8 秒：通过；Bundle 版本为 0.1.6，签名严格校验通过。
- GitHub `v0.1.6` Action：通过；运行 `32333113258`，耗时 5 分 53 秒，版本校验、Universal DMG 打包和正式 Release 发布均成功。
- 正式 Release：`draft=false`、`prerelease=false`；DMG 与 SHA-256 两个资产均为 `uploaded`。
- 重新下载远端 DMG 后：SHA-256 与 `hdiutil verify` 通过，App 为 `x86_64 arm64`，Bundle 版本为 0.1.6，严格签名校验通过；Apple Silicon 启动保持运行 8 秒。
- 真实 Windows TLS/NLA：未执行；本地环境没有可安全自动使用的测试端点和凭据。

## 证据记录

1. 记录 App 版本、输入身份格式类型、连接阶段、脱敏错误类别与错误码。
2. 成功时记录远程桌面是否出现；失败时只记录“认证 / 网络 / TLS / 协议”类别。
3. 不记录完整端点、账号、密码或证书材料。

## 清理与恢复

1. 删除专用测试 Profile，并确认关联 Keychain 密码和证书信任同时删除。
2. 卸载测试 DMG，删除测试 App 副本。
3. 若旧 Profile 仍失败，保留 Profile，不要反复覆盖凭据；记录脱敏后的错误类别和代码用于下一轮定位。

## 已知限制

- 自动化测试不能证明特定 Windows 主机的账号策略、NLA 配置或网络路径正确。
- App 仍为 ad-hoc 签名且未公证，首次启动需要用户明确允许。
- Intel slice 的构建检查不能替代 Intel Mac 上的真实 GUI、Keychain 和网络验收。
