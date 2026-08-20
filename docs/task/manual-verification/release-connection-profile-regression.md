# Release 连接与 Profile 回归人工验证手册

## 元数据

- 任务标识：release-connection-profile-regression
- 范围：0.1.5 中已保存连接的证书自动信任、新连接持久化和 Release DMG 连接回归
- 当前状态：自动化测试、本地 Universal DMG 与 Apple Silicon 启动验证通过；真实 Windows 主机和 Intel Mac 人工验证待执行

## 前置条件与安全测试数据

1. 使用受支持的 macOS 图形会话和从正式 Release 下载的 App。
2. 使用操作者提供的测试 Windows 主机、本地或域测试账号以及可撤销密码；不得将端点、账号、证书或密码写入文档、命令行、截图和日志。
3. 测试主机启用 TLS/NLA，并允许测试账号通过 RDP 登录。
4. 测试前备份需要保留的 Profile；本流程会创建和删除专用测试 Profile。

## 操作和预期结果

| 步骤 | 操作 | 预期结果 | 状态 |
| --- | --- | --- | --- |
| 1 | 启动 0.1.5，从旧版本保留的 Profile 发起连接 | Profile 仍存在，应用不会把已匹配的证书自动信任误判为拒绝；不再因该竞态出现 `0x2000D` | 待执行 |
| 2 | 新建一个有效 Profile，并填写测试密码发起连接 | 点击提交后，该 Profile 立即出现在电脑列表；即使后续连接失败也不会消失 | 待执行 |
| 3 | 首次证书提示中选择“信任并记住” | 指纹仅绑定到当前 Profile，连接继续；退出并重启后相同证书不再弹窗 | 待执行 |
| 4 | 使用错误密码重复步骤 2 | Profile 保留且可编辑；错误密码不写入 Keychain，不发生无限重试 | 待执行 |
| 5 | 更新为正确密码并连接 | TLS/NLA 登录成功，远程窗口出现；选择保存时密码写入 Keychain | 待执行 |
| 6 | 断开、退出 App、重新启动并再次连接 | Profile 和证书信任仍存在，保存的凭据可用于一键连接 | 待执行 |
| 7 | 删除测试 Profile | Profile、对应 Keychain 项和证书信任记录均被删除，或明确报告部分失败 | 待执行 |
| 8 | 在 Apple Silicon 与 Intel Mac 分别从 0.1.5 DMG 重复步骤 1–7 | 两个架构行为一致，无加载或连接回归 | 待执行 |

## 自动化证据

- `Phase7Tests` 覆盖新 Profile 在连接成功前落库，以及证书检查目录存在、权限为 `0700` 且可清理。
- `/bin/sh scripts/test.sh` 覆盖 Swift、Bridge、Keychain 测试替身和静态 FreeRDP add-in 检查。
- Release 打包还需通过版本匹配、Universal 架构、ad-hoc 签名、DMG 和 GitHub Action 校验。

## 本次执行记录

- 执行日期：2026-08-20。
- `Phase7Tests`：17 项通过，0 失败。
- `/bin/sh scripts/test.sh`：Swift 107 项、Bridge 9 项通过，0 失败；静态 FreeRDP add-in 检查通过。
- `/bin/sh scripts/package-release.sh v0.1.5`：通过；版本匹配、Universal `x86_64 arm64`、严格 ad-hoc 签名和 DMG 校验均通过。
- 从本地 DMG 复制 App 后在 Apple Silicon 上直接启动并保持运行 8 秒：通过，无启动崩溃或 stderr。
- GitHub `v0.1.5` Action：通过；运行 `32329175849`，耗时 7 分 46 秒，版本校验、Universal DMG 打包和正式 Release 发布均成功。
- 正式 Release：`draft=false`、`prerelease=false`；DMG 与 SHA-256 两个资产均为 `uploaded`。
- 重新下载远端 DMG 后：SHA-256 与 `hdiutil verify` 通过，App 为 `x86_64 arm64`，严格签名校验通过；Apple Silicon 启动保持运行 8 秒且无 stderr。
- 真实 Windows TLS/NLA、旧 Profile、首次证书、错误/正确密码流程：未执行，等待操作者使用安全测试环境验证。

## 证据记录

1. 仅记录版本、测试步骤状态、错误类别和脱敏后的错误码。
2. 不记录完整主机名、IP、用户名、域、密码或证书指纹。
3. 如连接失败，记录发生阶段和错误代码，并单独保存经脱敏检查的诊断材料。

## 清理与恢复

1. 删除专用测试 Profile，并确认对应密码和证书信任随之删除。
2. 卸载测试 DMG，删除只用于本次验证的 App 副本。
3. 如果旧 Profile 验证失败，不删除原始 Profile；先保留现场并导出脱敏诊断。

## 已知限制

- 自动化测试无法证明真实 Windows TLS/NLA 登录成功，步骤 1、3、5、6 必须在真实主机上执行。
- 当前 App 仍为 ad-hoc 签名且未公证，首次启动可能需要用户明确允许。
- Intel slice 可由 CI 编译验证，但不能替代 Intel 实机的 Keychain、网络和 GUI 验收。
