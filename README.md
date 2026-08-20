# Farframe RDP

Farframe RDP 是一个原生 macOS RDP 客户端，核心目标是可靠的标准 RDP 兼容性、安全的一键凭据，
以及远程画布聚焦时可控的 macOS 快捷键处理。

当前已完成 Phase 0–9 的主要实现与阶段验收：项目包含固定版本 FreeRDP/WinPR、窄 C Bridge、
Metal 画面、键鼠输入与快捷键策略、SwiftData Profile、异步 Keychain、基础 RDP 通道，以及
RD Gateway、多显示器、RemoteApp、麦克风重定向和有限自动重连。这里的“已实现”仅指 Farframe
已经完成集成的路径；具体测试覆盖、人工证据和限制仍以兼容性矩阵及任务验证记录为准。

## 项目根目录

`Coding/FarframeRDP` 是项目根目录。源代码、构建脚本、测试和项目文档都以此目录为相对路径基准。

## 文档入口

- 产品与工程计划：[`docs/Farframe-RDP-Development-Plan.md`](docs/Farframe-RDP-Development-Plan.md)
- 行动计划：[`docs/task/README.md`](docs/task/README.md)
- 主行动计划：[`docs/task/00-master-action-plan.md`](docs/task/00-master-action-plan.md)
- 可执行任务清单：[`docs/task/01-executable-backlog.md`](docs/task/01-executable-backlog.md)
- 架构决策记录：[`docs/adr/README.md`](docs/adr/README.md)
- 阶段人工验收手册：[`docs/task/manual-verification/`](docs/task/manual-verification/)
- 兼容性矩阵：[`docs/compatibility/README.md`](docs/compatibility/README.md)
- 第三方组件与许可证：[`third-party/README.md`](third-party/README.md)

## 工程结构

- **FarframeRDP**：SwiftUI 应用外壳与 AppKit 远程窗口装配。
- **FarframeCore**：稳定标识、错误类型、日志分类和诊断脱敏。
- **FarframeRDPBridge**：唯一拥有 FreeRDP instance/context 的窄 C ABI；Swift 只接触不透明句柄。
- **FarframeCoreTests**、**FarframeRDPTests**、**FarframeRDPBridgeTests**：对应模块测试。

## RDP 实现进度

状态含义：**已支持**表示已有实现和对应验收证据；**部分支持**表示主路径可用，但仍有明确的
协议、对象模型或设备范围缺口；**实验性**表示已接入构建或协商路径，但真实环境覆盖仍不足；
**未实现**表示当前构建未启用或 Farframe 尚未完成集成。FreeRDP 上游具备某项能力不等于
Farframe 已经支持该能力。

| 能力 | 当前状态 | 已实现范围 | 仍缺失或限制 |
|---|---|---|---|
| 连接、安全与生命周期 | 已支持 | IPv4/DNS/自定义端口、TLS/NLA、证书显式决策、会话 UUID 隔离、取消与完整清理 | Windows/Server/域、IPv6、高延迟和丢包仍需扩大兼容矩阵 |
| 普通桌面图形 | 部分支持 | BGRA 更新、Metal/CAMetalLayer、脏区、缩放、光标；普通桌面可协商 RDPGFX Progressive 和 AVC420/AVC444 | RDPGFX/AVC 仍属实验性，真实高动态画面、性能与更多服务端组合待验证 |
| 键盘、鼠标与快捷键 | 部分支持 | scan code 键盘、鼠标/滚轮、锁定键、远端输入法策略、焦点/断线释放、应用内快捷键策略 | 非美式物理键盘、扩展鼠标键和增强 CGEventTap 捕获仍需完整人工验收 |
| Profile、凭据与信任 | 已支持 | SwiftData 非秘密配置、Keychain 密码、目标/网关证书信任、一键连接与删除清理 | 仍需持续覆盖 Keychain/TCC 异常和证书轮换场景 |
| 剪贴板 | 部分支持 | 双向文本；HTML/RTF、PNG/DIB、普通文件对象和按需文件流已实现并有自动化测试 | HTML/图片/文件互操作仍待统一人工收口；文件对象目前不支持目录、Package、符号链接、alias 或路径文本 |
| 音频播放 | 已支持 | `rdpsnd`/Core Audio、会话开关、跟随系统输出切换和断线释放 | Profile 尚不能指定首选本机输出设备，也没有“设备不存在时降级到系统默认”的会话级策略 |
| 动态分辨率与多显示器 | 已支持 | `disp` 通道、窗口 resize、当前窗口/全部显示器、布局、DPI 与主屏映射 | 仍需扩大不同 macOS、Retina/非 Retina 组合覆盖 |
| 本地目录重定向 | 已支持 | 每个 Profile 可显式授权一个本地目录；路径规范化和越界检查已接入 | 暂不支持多个独立映射目录；真实部署仍需遵守最小授权原则 |
| RD Gateway | 已支持 | 独立网关配置、凭据、证书信任，以及网关/目标连接和认证错误分层 | 更多网关产品、代理和企业策略组合待兼容验证 |
| RemoteApp | 部分支持 | RAIL 启动、参数/工作目录、错误恢复、窗口和会话生命周期已验收 | RemoteApp 当前未接入 RDPGFX Progressive/AVC 图形路径，仍使用兼容回退路径 |
| 麦克风重定向 | 已支持 | `audin`、TCC 权限、设备选择、不可用设备降级及断线清理 | 更多输入设备与服务端应用组合待验证 |
| 自动重连 | 部分支持 | 网络类失败后有限、可取消、有状态提示地重建 FreeRDP 会话；认证/证书错误不循环重试 | 尚未实现 RDP Auto-Reconnect Cookie 驱动的协议级会话续接 |
| 设备重定向 | 未实现 | 当前版本有意保持打印机、智能卡、USB、串口、并口和摄像头关闭 | URBDRC、serial、parallel、RDPECAM 尚未集成；触控/笔输入的 RDPEI 路径也未实现 |

### 下一阶段协议任务

| TangoForge 任务 | 工作内容 | 关键完成标准 |
|---|---|---|
| T088 | RDP 协议级自动重连与会话续接 | 优先续接原会话，失败后安全降级到现有有限重建策略；cookie 不持久化、不记录日志 |
| T090 | RemoteApp 的 RDPGFX Progressive/AVC 图形路径 | RAIL 窗口与 surface 生命周期正确；协商失败可回退且不影响输入响应 |
| T086、T091–T094 | USB、串并口、摄像头、触控/笔设备重定向 | 默认关闭、Profile 显式授权、权限最小化、热插拔和单项失败隔离 |
| T087、T095–T097 | 文件剪贴板完整对象模型 | 为目录、Package、链接/alias 和路径文本定义支持/转换/拒绝策略，并实现有界流式传输 |
| T089 | Profile 首选远端音频播放设备 | 保存稳定设备标识；设备缺失或打开失败时降级到系统默认且不覆盖用户选择 |

详细测试状态和限制见[兼容性矩阵](docs/compatibility/matrix.md)，阶段人工验收记录见
[`docs/task/manual-verification/`](docs/task/manual-verification/)。

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

脚本默认构建 arm64 与 x86_64 原生依赖和 Universal 2 App，使用 FarframeRDP scheme、项目内已忽略的
.derivedData，并为普通无头构建设置 CODE_SIGNING_ALLOWED=NO。可以通过
FARFRAME_DERIVED_DATA_PATH 指定其他 Derived Data 目录。

首个发布版本为 `0.1.0`。在没有 Developer ID 证书时，可生成 ad-hoc 签名、未公证的 Universal DMG：

~~~sh
/bin/sh scripts/package-release.sh v0.1.0
~~~

推送 `vX.Y.Z` 标签会触发 GitHub Action；标签版本必须与 App 的 `MARKETING_VERSION` 完全一致，
成功后会创建包含 DMG 与 SHA-256 校验文件的正式 GitHub Release。

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
Phase 0–9 主要能力（已完成阶段实现与验收）
→ 协议级会话续接与 RemoteApp 高级图形路径
→ 文件剪贴板完整对象模型
→ Profile 音频输出设备选择
→ 按需求和平台可行性逐项启用设备重定向
→ 扩大安全、稳定性、性能与兼容性矩阵
```

具体依赖和验收条件见任务清单。任务完成时必须记录实际执行的命令、通过的测试、未运行项、
人工验收和残余风险。
