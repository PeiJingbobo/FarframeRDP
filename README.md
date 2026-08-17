# Farframe RDP

Farframe RDP 是一个原生 macOS RDP 客户端，核心目标是可靠的标准 RDP 兼容性、安全的一键凭据，
以及远程画布聚焦时可控的 macOS 快捷键处理。

当前已完成至 Phase 7 的代码和自动化验证：项目包含固定版本 FreeRDP/WinPR、窄 C Bridge、
Metal 画面、基础输入、应用内快捷键、SwiftData Profile、异步 Keychain 和一键连接界面。
Phase 7 的真实 Windows、Keychain 系统交互和 GUI 人工验收仍按验证记录执行。

## 项目根目录

`Coding/FarframeRDP` 是项目根目录。源代码、构建脚本、测试和项目文档都以此目录为相对路径基准。

## 文档入口

- 产品与工程计划：[`docs/Farframe-RDP-Development-Plan.md`](docs/Farframe-RDP-Development-Plan.md)
- 行动计划：[`docs/task/README.md`](docs/task/README.md)
- 主行动计划：[`docs/task/00-master-action-plan.md`](docs/task/00-master-action-plan.md)
- 可执行任务清单：[`docs/task/01-executable-backlog.md`](docs/task/01-executable-backlog.md)
- 架构决策记录：[`docs/adr/README.md`](docs/adr/README.md)
- Phase 7 验证记录：[`docs/task/phase-7-validation.md`](docs/task/phase-7-validation.md)
- 兼容性矩阵：[`docs/compatibility/README.md`](docs/compatibility/README.md)
- 第三方组件与许可证：[`third-party/README.md`](third-party/README.md)

## 工程结构

- **FarframeRDP**：SwiftUI 应用外壳与 AppKit 远程窗口装配。
- **FarframeCore**：稳定标识、错误类型、日志分类和诊断脱敏。
- **FarframeRDPBridge**：唯一拥有 FreeRDP instance/context 的窄 C ABI；Swift 只接触不透明句柄。
- **FarframeCoreTests**、**FarframeRDPTests**、**FarframeRDPBridgeTests**：对应模块测试。

## Mac 构建与测试

需要 Xcode CLI、Git、CMake、Ninja、Perl 和 Make。CMake/Ninja 不在 PATH 时，可通过
FARFRAME_CMAKE 与 FARFRAME_NINJA 指定可执行文件。首次执行会获取固定提交并构建项目内静态依赖。

在项目根目录执行：

~~~sh
/bin/sh scripts/build.sh
/bin/sh scripts/test.sh
/bin/sh scripts/test-native-bridge.sh
FARFRAME_CONFIGURATION=Release /bin/sh scripts/build.sh
FARFRAME_CONFIGURATION=Sanitizer /bin/sh scripts/build.sh
~~~

脚本默认使用 arm64、FarframeRDP scheme、项目内已忽略的 .derivedData，并为无头构建设置
CODE_SIGNING_ALLOWED=NO。可以通过 FARFRAME_DERIVED_DATA_PATH 指定其他 Derived Data 目录。

Xcode Sanitizer 应用构建仍受 Phase 1 记录的 XCTest 引导限制；Phase 2 已增加独立原生
ASan/UBSan harness 并验证 Bridge 所有权。详情见
[Phase 2 验证记录](docs/task/phase-2-validation.md)。

## 开发与验证边界

- Windows 电脑用于浏览和修改共享项目文件。
- macOS 应用的构建和测试必须在 Mac 上执行。
- 每次构建前应从仓库现状探测真实的 Xcode project/workspace、scheme、SDK、架构和 destination。
- 命令行构建成功不代表 GUI、Keychain、Accessibility、Input Monitoring、Metal、全屏或物理键盘验收通过。
- 真实 Windows 端点和凭据只放在本地未跟踪配置中，不得写入仓库、日志、截图或命令参数。

## 当前工作顺序

```text
Phase 0–6 已完成的基础能力
→ Phase 7 Profile 与一键连接（已完成）
→ Phase 8 基础 RDP 通道
→ Phase 9 高级兼容性
```

具体依赖和验收条件见任务清单。任务完成时必须记录实际执行的命令、通过的测试、未运行项、
人工验收和残余风险。
