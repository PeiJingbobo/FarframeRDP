# App 图标人工验证手册

## 1. 元数据

- 任务 ID：app-icon
- 任务标题：使用 Icon Composer 配置 Farframe RDP App 图标
- 关联开发计划：步骤一“建立项目骨架和工程规则”
- 手册状态：部分通过（自动化构建产物检查通过，GUI 待执行）
- 最近更新日期：2026-08-20

## 2. 验证目标

验证 Icon Composer 文件能够在 Debug、Release 和 Sanitizer 配置中作为 Farframe RDP 的 App Icon 被 Xcode 编译，并确认最新构建在 Finder、Dock 和应用切换器中显示预期图标，而不是 macOS 默认应用图标或旧缓存图标。

## 3. 前置条件

- 使用包含 `Sources/FarframeRDP/AppIcon.icon` 的待验证提交构建 App。
- 使用支持 Icon Composer 的 Xcode 版本。
- Mac 处于已解锁的图形会话。
- 关闭所有正在运行的 Farframe RDP 实例。
- 不需要 Windows 主机、网络端点、账号或凭据。

## 4. 验证步骤

| 编号 | 操作 | 预期结果 | 证据 | 状态 |
|---|---|---|---|---|
| 1 | 在 Xcode 中选择 FarframeRDP target，检查 General > App Icons and Launch Screen | App Icon 名称为 `AppIcon`，不包含 `.icon` 后缀 | 脱敏后的 Xcode 设置截图 | 未执行 |
| 2 | 执行 Product > Clean Build Folder，然后构建并运行 Debug App | 构建成功；应用启动时 Dock 显示设计图标，不显示默认应用图标 | Dock 截图 | 未执行 |
| 3 | 在 Xcode 的 Products 中选择 FarframeRDP.app 并执行 Show in Finder | Finder 中的 App Bundle 显示设计图标 | Finder 截图 | 未执行 |
| 4 | 保持 App 运行并打开应用切换器 | 应用切换器显示与 Finder、Dock 一致的设计图标 | 应用切换器截图 | 未执行 |
| 5 | 构建 Release 配置并检查生成的 App Bundle | Release App 显示与 Debug 一致的设计图标 | Finder 截图或观察记录 | 未执行 |

## 5. 失败与边界场景

| 编号 | 操作 | 预期安全行为 | 状态 |
|---|---|---|---|
| F1 | 构建成功但 Dock 仍显示旧图标时，从 Dock 移除旧项目并重新运行最新构建 | 新实例显示当前图标；无需修改 Bundle ID、签名设置或清除用户数据 | 未执行 |
| F2 | 检查最新 App Bundle 的 `Contents/Resources` 与 `Info.plist` | Bundle 包含 `AppIcon.icns` 和 `Assets.car`；`CFBundleIconFile` 与 `CFBundleIconName` 均指向 `AppIcon` | 未执行 |
| F3 | 在较旧的受支持 macOS 部署目标上检查图标 | Xcode 生成的兼容图标可显示；Liquid Glass 外观可能与当前 macOS 不完全相同 | 未执行 |

## 6. 清理与恢复

1. 退出测试中的 Farframe RDP 实例。
2. 如为验证缓存而临时从 Dock 移除图标，可按需重新固定最新构建。
3. 无需删除 Profile、Keychain 项目、权限或用户数据。

## 7. 本次执行记录

- 执行日期：2026-08-20
- 执行人：Codex（自动化构建产物检查）
- 环境摘要：macOS 26.5.2、arm64、Xcode 26.2；无账号或机器标识
- 结果：部分通过。Debug 与 Release 无签名构建成功；两种配置均生成 `AppIcon.icns` 和 `Assets.car`，且生成的 `Info.plist` 中 `CFBundleIconFile` 与 `CFBundleIconName` 均为 `AppIcon`。
- 失败项与脱敏证据：无
- 尚未验证项：第 1 至 5 步 GUI 检查，以及 F1、F3；F2 的构建产物检查已通过。
- 残余风险/兼容限制：Finder、Dock、应用切换器的图标显示及缓存行为必须在已解锁的 macOS 图形会话中人工观察；命令行构建无法替代该检查。

## 8. 不适用说明（仅在确实无人工验证价值时填写）

- 不适用理由：不适用；本改动包含必须人工观察的 macOS GUI 行为。
- 替代自动化测试及命令：无。
- 自动化证据位置：无。
