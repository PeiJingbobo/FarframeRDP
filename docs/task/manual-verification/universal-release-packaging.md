# Universal Release 打包人工验证手册

## 元数据

- 任务标识：universal-release-packaging
- 范围：Farframe RDP 0.1.x Universal 2、未公证 DMG 和 tag 触发 GitHub Action
- 当前状态：0.1.3 本地自动化与 DMG 结构验证通过；Action 已发现并修复 OpenH264 工具、Xcode runner 与可选系统依赖探测差异；0.1.3 Action 与 Intel 实机待执行

## 前置条件与安全测试数据

1. 一台运行受支持 macOS、安装完整 Xcode、CMake 和 Ninja 的测试 Mac。
2. 一个不含真实 RDP 端点、账号、凭据、证书或签名身份的干净源码检出。
3. 本流程不需要 Apple Developer 账号或 Developer ID 证书。
4. 验证 GitHub Action 时使用版本匹配的测试标签；不要在验证通过前公开 draft Release。

## 操作和预期结果

| 步骤 | 操作 | 预期结果 | 状态 |
| --- | --- | --- | --- |
| 1 | 运行 `/bin/sh scripts/validate-release-version.sh v0.1.3` | 标签与 App `MARKETING_VERSION=0.1.3` 一致，校验通过 | 通过 |
| 2 | 使用一个不匹配标签运行版本校验 | 在构建原生依赖前失败，不产生 DMG | 通过；使用 `v0.1.0` 验证 |
| 3 | 运行 `/bin/sh scripts/package-release.sh v0.1.3` | 生成 DMG 和 SHA-256 文件，命令无警告性失败 | 通过 |
| 4 | 对 App 主程序和 Universal 原生静态库运行 `lipo -archs` | 均同时包含 `arm64` 与 `x86_64` | 通过；App、FarframeCore 和原生聚合库均含两个架构 |
| 5 | 运行 `codesign --verify --deep --strict` 和 `hdiutil verify` | ad-hoc 签名和 DMG 结构有效 | 通过 |
| 6 | 挂载 DMG，将 App 拖入 Applications 并启动 | App 能启动；系统可能因未公证显示 Gatekeeper 警告，该限制如实披露 | 待执行 |
| 7 | 在 Apple Silicon Mac 上完成基本启动、创建非秘密测试 Profile、关闭和重新打开 | 没有架构加载错误或启动崩溃 | 待执行 |
| 8 | 在可运行 macOS 14 的 Intel Mac 上重复步骤 6–7 | 没有架构加载错误或启动崩溃 | 待执行 |
| 9 | 推送版本匹配的新标签 | Action 成功，并创建包含 DMG 与 SHA-256 的 draft Release | 待执行 |
| 10 | 推送版本不匹配的隔离测试标签 | Action 在版本校验阶段失败且不创建发布产物 | 待执行 |

## 证据记录

- 记录 commit 和标签，不记录账号、签名身份或机器特定路径。
- 保存 `lipo` 架构摘要、测试命令结果、Action URL 和 draft Release 资产名称。
- 分别标记 Apple Silicon、Intel、GitHub Action 步骤为通过、失败或未执行。

## 本次执行记录

- 执行日期：2026-08-20。
- `/bin/sh scripts/package-release.sh v0.1.0`：通过；生成 `FarframeRDP-0.1.0-universal.dmg` 与 SHA-256。
- Xcode 测试：通过，共 128 项，0 失败（Core 14、App 105、Bridge 9）。
- 原生 ASan/UBSan Bridge harness：通过。
- Release 安全设置、静态 channel add-in、ad-hoc 签名和 DMG 校验：通过。
- Apple Silicon 与 Intel slice 均成功编译、链接；Apple Silicon GUI 安装验收与 Intel 实机运行尚未执行。
- GitHub `v0.1.0` tag Action 已执行并失败：CMake 选择 Ninja 后，脚本错误地用 Ninja 调用 OpenH264 的 Makefile；版本校验和工具检查均已通过。失败运行：`32323923548`。
- 修复策略：OpenH264 始终使用 `make`，FreeRDP 的 CMake 构建工具仍由生成器决定；不改写已推送的 `v0.1.0` 标签，使用 `v0.1.1` 重新验证。
- `/bin/sh scripts/package-release.sh v0.1.1`：通过；双架构原生依赖从新配方完整重建，生成 `FarframeRDP-0.1.1-universal.dmg` 与 SHA-256。
- 0.1.1 App 架构：`x86_64 arm64`；严格 codesign 校验、DMG 校验和 SHA-256 校验均通过。
- GitHub `v0.1.1` Action 已越过双架构原生依赖构建，在 Xcode 编译阶段失败。runner 的 Xcode 16.4/SDK 15.5 无法编译项目使用的 SDK 26 SwiftUI API，且 Swift 6 诊断与本地 Xcode 26.2 不一致；失败运行：`32324493771`。
- runner 修复：Release 改用提供 Xcode 26 的 `macos-26`，与项目实际最低编译工具链对齐；不改写 `v0.1.1`，使用 `v0.1.2` 验证。
- `/bin/sh scripts/package-release.sh v0.1.2`：通过；生成 `FarframeRDP-0.1.2-universal.dmg` 与 SHA-256，Xcode 26.2 Release 构建和 DMG 校验通过。
- GitHub `v0.1.2` Action 已通过 Xcode 26 源码编译，在 x86_64 最终链接失败：runner 预装的 `json-c` 被 FreeRDP 自动探测并引用，但未进入项目聚合静态库；失败运行：`32324960145`。
- 原生依赖修复：显式设置 `WITH_JSON_DISABLED=ON`。当前集成不使用该可选能力，禁用环境相关的自动探测可保证本地和 CI 产物配置一致；不改写 `v0.1.2`，使用 `v0.1.3` 验证。
- `/bin/sh scripts/package-release.sh v0.1.3`：通过；双架构依赖按禁用 JSON 自动探测的新配方完整重建，Release App 链接、签名与 DMG 校验通过。

## 清理与恢复

1. 卸载测试 DMG，删除测试安装的 App 和测试 Profile。
2. 删除 `.release/`、任务专用 `.derivedData-*` 和已忽略的原生构建产物。
3. 删除只用于失败路径验证的隔离标签和对应 draft Release；不得改写正式发布标签历史。

## 已知限制

- 当前产物仅有 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证。
- 自动构建证明两个架构可链接，不替代 Intel 实机的 GUI、Keychain、Metal、权限和 RDP 验收。
- DMG 不应在完成项目发布门槛审查前标记为正式稳定版本。
