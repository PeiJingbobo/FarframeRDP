# Farframe RDP 开发计划

> 项目定位：一个原生 macOS RDP 客户端，以标准 RDP 兼容性、安全的一键连接和可控的远程快捷键捕获为核心。

## 1. 项目目标与边界

### 1.1 核心目标

Farframe RDP 应当做到：

1. 在 macOS 上稳定连接启用了远程桌面的 Windows 客户端和 Windows Server。
2. 复用 FreeRDP 实现标准 RDP 协议栈，不自行重新实现加密、NLA、图形通道等高风险协议。
3. 支持常用的 RDP 基础能力：直接连接、TLS/NLA、图形显示、键鼠输入、剪贴板、音频、动态分辨率、全屏和必要的设备重定向。
4. 当远程画布获得焦点时，阻止所选 macOS 应用快捷键被本地执行，并按照用户策略将其转换为 Windows 按键。
5. 用 macOS Keychain 保存密码；用户点击在线主机后直接连接，不重复输入用户名和密码。
6. 即使不加入 Apple Developer Program，也能在开发者自己的 Mac 上构建和使用。

### 1.2 “RDP 兼容”的定义

本项目的兼容目标是“兼容 FreeRDP 当前稳定分支所支持的标准 RDP 能力”，而不是宣称复制微软 Windows App 的全部云服务。

首要兼容对象：

- Windows 10/11 Pro、Enterprise、Education
- 当前受支持的 Windows Server
- 本地账户、域账户
- TLS 与 NLA/CredSSP
- IPv4、IPv6、DNS 主机名和自定义端口
- 普通桌面会话

扩展兼容对象：

- RD Gateway
- RemoteApp
- 多显示器
- 音频输入
- 本地目录、打印机和智能卡重定向

不应在基础版本中承诺：

- Azure Virtual Desktop 工作区订阅
- Windows 365 管理与资源发现
- Microsoft Entra ID 的所有专有登录流程
- 所有厂商自定义 RDP 虚拟通道
- Windows Home 作为微软原生 RDP 主机

每项能力必须进入兼容性矩阵，标为“支持、部分支持、实验性、不支持”，不能只用“完全兼容”作为笼统结论。

## 2. 技术栈

### 2.1 应用层

- **语言**：Swift
- **界面框架**：SwiftUI 负责电脑列表、设置、表单和导航；AppKit 负责远程会话窗口、第一响应者、菜单快捷键、键盘事件和窗口生命周期
- **最低系统版本**：项目启动时固定一个明确版本；建议优先支持仍处于安全更新期、且覆盖目标用户的 macOS 版本
- **并发模型**：Swift Concurrency 管理 UI 状态和异步服务；FreeRDP 连接循环使用独立串行线程或队列
- **日志**：OSLog，所有用户名、主机、证书和认证字段按隐私级别输出，密码永不写日志

选择 AppKit 参与远程窗口实现是必要的。纯 SwiftUI 不适合精确控制 `performKeyEquivalent`、第一响应者、菜单快捷键优先级和低层输入事件。

### 2.2 RDP 协议层

- **核心库**：FreeRDP 3.x 稳定版本，锁定确切版本或提交
- **系统兼容层**：WinPR
- **构建系统**：CMake + Ninja
- **集成形式**：优先构建静态库并包装成内部 XCFramework；arm64 为首要架构，x86_64/Universal 作为可选目标
- **Swift 桥接**：使用窄接口的 C/Objective-C++ Bridge，不让 Swift 直接依赖大量 FreeRDP C 结构体
- **依赖管理**：FreeRDP 及 OpenSSL、zlib、OpenH264 等依赖必须固定版本，生成许可证清单和组件清单

桥接层只暴露稳定的 Farframe 接口，例如：

```text
FFRSessionCreate
FFRSessionConnect
FFRSessionDisconnect
FFRSessionResize
FFRSessionSendScanCode
FFRSessionSendUnicode
FFRSessionSendPointer
FFRSessionSetClipboard
FFRSessionSetEventCallback
```

所有 FreeRDP 指针由桥接层拥有；Swift 只持有不透明句柄，避免跨语言生命周期错误。

### 2.3 图形与音频

- **初始像素格式**：32 位 BGRA
- **渲染**：Metal + `CAMetalLayer`
- **更新策略**：脏矩形合并、纹理局部更新、显示刷新节流
- **缩放**：支持按窗口适配、原始像素、Retina 缩放和保持宽高比
- **光标**：本地光标缓存与远程光标形状更新
- **音频**：Core Audio/AVAudioEngine 承接 FreeRDP 音频输出
- **硬件视频解码**：作为性能增强评估 VideoToolbox；必须先确认与 FreeRDP 图形管线的集成边界，不能假设所有 RDP 图形更新都是可直接交给 VideoToolbox 的普通视频流

### 2.4 数据、安全与网络

- **非秘密配置**：SwiftData 或 SQLite
- **秘密数据**：Security.framework / Keychain Services
- **网络状态**：Network.framework 做本机网络状态和可选的目标端口探测
- **证书验证**：FreeRDP 证书回调 + macOS 信任界面；保存用户明确接受的证书指纹
- **本地目录授权**：若启用 App Sandbox，使用 `NSOpenPanel` 和 security-scoped bookmark

### 2.5 测试工具

- Swift 单元测试与 UI 测试
- C/C++ 桥接层测试
- Address Sanitizer、Undefined Behavior Sanitizer、Thread Sanitizer
- Instruments：Time Profiler、Allocations、Leaks、Metal System Trace
- Windows 测试机/虚拟机矩阵
- 网络故障模拟：延迟、丢包、断网、切网、服务端重启

## 3. 总体架构

```text
FarframeApp
├── AppShell                 SwiftUI 应用外壳
├── ProfileStore             连接配置和用户偏好
├── CredentialVault          Keychain 凭据
├── HostStatusService        在线状态探测
├── CertificateTrustStore    证书指纹与信任决策
├── SessionCoordinator       会话状态机
│   └── FarframeRDPBridge    C / Objective-C++ 边界
│       └── FreeRDP + WinPR
├── RemoteSessionWindow      AppKit 窗口
│   ├── RemoteCanvasView     Metal 画布、第一响应者
│   ├── InputRouter          键鼠与输入法
│   └── ShortcutController   本地拦截、转换、释放
├── ChannelServices
│   ├── Clipboard
│   ├── Audio
│   ├── Drive
│   └── Microphone
└── Diagnostics
```

### 3.1 会话状态机

必须定义单向、可测试的状态：

```text
idle
→ resolving
→ connecting
→ authenticating
→ connected
→ reconnecting
→ disconnecting
→ disconnected / failed
```

每次连接有独立 UUID。旧会话的迟到回调不得修改新会话 UI。断开连接必须释放网络、图形、音频、剪贴板、事件监视器和所有按键状态。

## 4. 分步实施与验收

## 步骤一：建立项目骨架和工程规则

### 工作

- 创建 Xcode macOS App 工程，确定 Bundle ID，例如 `com.farframe.rdp`。
- 建立 SwiftUI App Shell 和 AppKit 远程窗口承载方式。
- 建立模块目录、错误类型、日志分类和配置环境。
- 建立 Debug、Release、Sanitizer 构建配置。
- 明确代码格式、警告即错误策略和第三方许可证目录。
- 固定签名方式；Personal Team 或 `Sign to Run Locally` 下保持 Bundle ID 稳定。

### 工作目标

形成一个可持续扩展、可复现构建的空应用，而不是把协议、UI 和存储代码堆在同一 Target 中。

### 验收

- 干净环境中按照 README 可以完成构建。
- 应用可启动、打开设置窗口和一个空远程窗口。
- Debug/Release 均可构建。
- 日志中能区分 App、Session、Input、Render、Security、Channel。
- Bundle ID 和 Keychain service 名称已固定。

## 步骤二：构建并封装 FreeRDP

### 工作

- 选择 FreeRDP 稳定版本并记录提交。
- 为 arm64 构建最小客户端静态库及所需依赖。
- 关闭不使用的 server、proxy、测试工具和命令行客户端。
- 明确 OpenSSL、OpenH264、FFmpeg 等可选组件是否启用。
- 创建 XCFramework 或确定性构建脚本。
- 建立 `FarframeRDPBridge`，包装实例创建、连接、断开、回调和错误。
- 生成第三方许可证与版本清单。

### 工作目标

让 Xcode 应用只依赖 Farframe Bridge，不直接散布 FreeRDP 头文件和全局状态。

### 验收

- 应用成功链接，不依赖 Homebrew 安装路径。
- 删除开发机上的 Homebrew FreeRDP 后仍能构建和运行已打包版本。
- 能从桥接层读取 FreeRDP 版本。
- 创建和销毁空会话反复执行无泄漏、无崩溃。
- Release 包中没有意外的绝对动态库路径。

## 步骤三：实现最小连接闭环

### 工作

- 实现主机名、端口、用户名、域、密码到 FreeRDP settings 的映射。
- 实现 DNS、TCP、TLS、NLA/CredSSP 和认证回调。
- 实现证书验证界面：主机、签发者、指纹、错误原因。
- 对首次见到的自签名证书提供“仅此次连接”与“记住此证书”；禁止默认无条件忽略。
- 把 FreeRDP 错误转换为用户可读错误：网络不可达、认证失败、证书变化、服务端拒绝、协议不兼容。
- 实现取消连接和主动断开。

### 工作目标

建立从配置到 Windows 登录成功、再安全断开的完整协议链路。

### 验收

- 可连接 Windows 11 Pro 和至少一个 Windows Server 测试环境。
- 正确密码可进入会话；错误密码不会无限重试。
- 主机不存在、端口关闭、证书变化、NLA 失败都有不同错误。
- 连接中点击取消能退出，不留下后台线程。
- 断开后端口、线程和 FreeRDP context 全部释放。

## 步骤四：实现远程画面

### 工作

- 订阅 FreeRDP 图形更新和桌面尺寸回调。
- 创建线程安全的帧缓冲和脏矩形队列。
- 将 BGRA 数据上传到 Metal 纹理。
- 使用显示同步调度合并同一刷新周期内的脏区，并允许为每个连接选择自适应、30 FPS 或 60 FPS 的本地最高呈现频率。
- 普通桌面会话优先协商 FreeRDP RDPGFX；启用 Progressive 与 OpenH264 AVC420/AVC444 解码，服务端不支持时回退传统 GDI 图形更新。
- 支持窗口缩放、原始分辨率、全屏和 Retina。
- 服务端支持时发送动态分辨率/显示控制更新。
- 实现远程光标形状、热点和可见性。
- 在图形异常时保留 Core Graphics 调试回退路径。

### 工作目标

在持续变化的桌面内容下稳定显示，不阻塞协议线程或主线程。

### 验收

- 登录后能看到完整桌面，颜色、方向和光标热点正确。
- 拖动、缩放窗口不会出现越界、撕裂或旧帧覆盖。
- 从普通窗口进入/退出全屏后分辨率正确恢复。
- 视频播放、快速滚动和多窗口拖动过程中无持续内存增长。
- Retina 和非 Retina 显示器切换后画面比例正确。

## 步骤五：实现基础键鼠输入

### 工作

- `RemoteCanvasView` 实现第一响应者。
- 鼠标移动、左右键、中键、滚轮和扩展按钮转换为 RDP 输入。
- 用 macOS `keyCode` 建立物理键到 Windows scan code 的明确映射。
- 所有可映射键盘事件均使用物理 scan code，包括字符键、控制键和 Backspace。
- 不解释或转发 macOS 本地输入法的 marked/committed text；中文等输入法由受控端自行切换和处理。
- 处理左右 Command、Control、Option、Shift、Caps Lock、Num Lock 和功能键。
- 支持按键重复。
- 窗口失焦、切换应用、断线时向远端补发所有仍处于按下状态的 key-up/button-up。
- 为不同键盘布局建立测试样例。

### 工作目标

所有输入在远端可预测，并且绝不因为窗口失焦产生“卡住的 Ctrl/Alt/Windows 键”。

### 验收

- Windows 屏幕键盘显示的修饰键状态与 Mac 实际状态一致。
- 英文、数字、方向键、F1–F12、删除、Home/End/PageUp/PageDown 正确。
- macOS 切换到中文输入源时仍只发送物理 scan code；受控端输入法可正常处理字符和 Backspace。
- 长按按键产生重复；松开后立即停止。
- 按住修饰键时切出应用，Windows 端不会保持该键按下。
- 鼠标缩放坐标在窗口、全屏和 Retina 模式下均准确。

## 步骤六：实现可配置快捷键捕获

### 6.1 必须区分的两类能力

**应用内捕获**：

- 处理发送给 Farframe RDP 的按键。
- 远程画布聚焦时，由 local monitor 直接成对处理所有可映射的 `keyDown`/`keyUp`；未命中语义策略的事件不得再次绕经菜单等价键和 responder chain，以免丢失 key-up。
- 可以可靠阻止 `Command-W` 关闭窗口、`Command-Q` 退出应用、`Command-C/V/X/A/Z` 触发本地菜单。
- 不需要全局键盘监听权限。

**增强系统捕获**：

- 使用可修改事件的 `CGEventTap` 尝试拦截部分先被 macOS 系统快捷键处理的事件。
- 需要辅助功能/输入监控相关授权。
- 只在 Farframe 位于前台、会话已连接且远程画布拥有焦点时启用。
- 启用后由同一个 event tap 接收所有可映射的 `keyDown`、`keyUp` 和 `flagsChanged`，按原始顺序发送物理 scan code；不能让修饰键与普通键分别经过 event tap 和 responder chain。
- 未列入快捷键设置的组合保持 Windows 原生语义，例如 Command→Win 后，Command-方向键自然发送 Win-方向键。
- 系统安全组合键及部分系统保留组合不能承诺全部拦截。

`NSEvent` 的全局 monitor 只能观察事件，不能阻止事件，因此不能用它实现快捷键屏蔽。应用内使用 local monitor、`performKeyEquivalent` 和第一响应者链；增强模式才使用 active event tap。

### 6.2 快捷键策略模型

每个快捷键配置项至少包含：

```text
id
displayName
macChord
captureWhenRemoteFocused
remoteChord
scope: windowed / fullscreen / both
requiresEnhancedCapture
isSystemReserved
```

设置界面的每行提供：

- “远程画面聚焦时捕获”开关
- 将要发送的 Windows 组合键说明
- “仅全屏”或“窗口和全屏”范围
- 需要系统权限时的标记
- 恢复默认值

第一组预置项：

| Mac 输入 | 默认远端映射 | 说明 |
|---|---|---|
| Command-C | Ctrl-C | 复制 |
| Command-V | Ctrl-V | 粘贴 |
| Command-X | Ctrl-X | 剪切 |
| Command-A | Ctrl-A | 全选 |
| Command-Z | Ctrl-Z | 撤销 |
| Shift-Command-Z | Ctrl-Y 或 Ctrl-Shift-Z | 可配置重做策略 |
| Command-S | Ctrl-S | 保存 |
| Command-F | Ctrl-F | 查找 |
| Command-P | Ctrl-P | 打印 |
| Command-N | Ctrl-N | 新建 |
| Command-T | Ctrl-T | 新标签 |
| Command-W | Ctrl-W | 不关闭 Farframe 窗口，关闭远端当前标签/窗口 |
| Command-Q | 无默认远端动作或 Alt-F4 | 默认只屏蔽本地退出，防止误关整个客户端 |
| Command-Tab | Win-Tab | 需要增强捕获；对应 Windows 任务视图。Option-Tab 通过 Option→Alt 的物理映射自然发送 Alt-Tab |
| Command-Space | Win-S | 通常与 Spotlight 冲突，需要增强捕获 |
| Control-Command-左/右 | Ctrl-Win-左/右 | 切换 Windows 虚拟桌面；与 macOS Spaces/Mission Control 冲突，需要增强捕获 |

还需要提供物理修饰键映射：

- Command 作为 Windows Ctrl、Windows 键或自定义
- Option 作为 Windows Alt
- Control 作为 Windows Ctrl
- 左右修饰键可分别设置

只有设置列表中明确启用并精确命中的“语义快捷键覆盖”优先于物理映射；其他组合必须优先保留 Windows 原生的物理组合语义。否则 `Command-W` 的行为会因全局 Command 映射不同而不可预测，或导致 Win-方向键等 Windows 原生组合失效。

### 6.3 输入事件处理顺序

```text
收到按键
→ 当前会话是否连接
→ RemoteCanvas 是否为第一响应者
→ 是否命中始终本地的安全释放组合
→ 是否命中用户快捷键策略
   → 阻止本地菜单动作
   → 发送配置的远端按下/松开序列
→ 未命中策略
   → 在增强模式的单一有序队列中，按物理修饰键映射发送 scan code
   → Windows 原生快捷键由 Windows 根据完整的物理按下/松开序列解释
```

### 6.4 安全释放机制

- 保留一个不能被用户关闭的“释放远程键盘捕获”组合，例如 `Control-Option-Command-Escape`。
- 菜单栏持续显示捕获状态。
- 画布失焦、窗口关闭、应用退到后台或会话断开时立即关闭 event tap。
- event tap 被系统因超时禁用时自动恢复或降级，并明确显示状态。
- 永不尝试拦截锁屏、强制退出等安全相关系统组合。

### 工作目标

在远程画布中，用户选中的常见快捷键只影响 Windows；离开画布后，macOS 行为立即恢复。高级系统快捷键的限制必须透明可见。

### 验收

- 开启“捕获 Command-W”后，在远程画布按下不会关闭 Farframe 窗口，并在 Windows 收到配置的 `Ctrl-W`。
- 关闭该开关后，`Command-W` 恢复 Farframe 的正常本地关闭行为。
- 焦点在地址表单、设置窗口或其他应用时，不拦截对应快捷键。
- `Command-C/V/X/A/Z/S/F/P/N/T` 分别按配置到达 Windows，本地菜单不执行。
- 用户切换全屏/窗口范围时策略正确生效。
- 拒绝辅助功能权限时，基础应用内捕获仍正常；增强项显示不可用原因。
- 会话断开和应用失焦后 event tap 已移除，macOS 快捷键完全恢复。
- 任意捕获状态下，安全释放组合有效。
- 所有按键路径均成对产生 key-down/key-up，无卡键。
- 测试报告单独列出无法屏蔽的 macOS 保留组合，不把它们记为“已支持”。

## 步骤七：实现连接配置与安全凭据

### 7.1 数据模型

`ConnectionProfile` 保存：

```text
id: UUID
displayName
host
port
username
domain
gatewayProfileID
desktopOptions
redirectOptions
shortcutProfileID
certificateTrustReference
lastSuccessfulConnection
```

数据库可以保存主机、用户名和域，但不能保存密码、NTLM hash、可复用 token 或私钥。

### 7.2 Keychain 设计

- 使用 `SecItem` API。
- Keychain item 类型选择 `kSecClassGenericPassword`。
- `kSecAttrService` 固定为例如 `com.farframe.rdp.credentials`。
- `kSecAttrAccount` 使用连接 Profile UUID，而不是可变的主机名。
- 密码仅放入 `kSecValueData`。
- 新增、查询、更新和删除都在后台执行，不能阻塞主线程。
- FreeRDP 需要凭据时才从 Keychain 读取，交给桥接层后尽快释放内存引用。
- 日志、崩溃上下文、剪贴板和数据库中不得出现密码。
- 不使用 Keychain Sharing、iCloud 同步或共享 Access Group，确保 Personal Team 下保持简单稳定。
- 可选提供“每次用 Touch ID/系统密码解锁凭据”，但默认的一键连接模式不强制二次确认。

### 7.3 用户流程

首次连接：

1. 用户填写地址、用户名、域和密码。
2. “保存密码”默认开启但清楚标注保存到 macOS Keychain。
3. 提交有效表单后先保存非秘密连接配置，确保网络、证书或认证失败时仍可编辑和重试；只有认证成功后才把用户选择保存的密码写入 Keychain。
4. 首次证书信任与保存密码是两个独立决定。

后续连接：

1. 用户点击电脑卡片。
2. 异步读取 Keychain。
3. 凭据存在则直接开始 TLS/NLA。
4. 凭据缺失、Keychain 被锁定或认证失败才弹出凭据界面。
5. 用户可以更新密码、删除密码或删除整个连接。

删除连接时必须同时删除对应 Keychain item 和本地证书信任记录；如果删除失败，需要向用户报告并允许重试。

### 7.4 在线状态与直接进入

电脑卡片状态定义为：

- 未检查
- 检查中
- 可能在线
- 不可达
- 最近连接成功

在线探测使用短生命周期的 TCP 端口探测或网关探测。它只能说明目标端口可达，不能证明凭据正确或 RDP 协议一定可用，因此：

- 卡片始终允许点击连接。
- “可能在线”不能写成“已认证在线”。
- 实际 RDP 握手才是最终判断。
- 支持关闭自动探测，避免企业网络扫描敏感性。
- RD Gateway 配置下探测 Gateway，而不是误探测不可直接访问的内网主机。

### 工作目标

应用重启后，用户点击已保存电脑即可进入连接流程；密码始终受 Keychain 保护，错误凭据和证书变化不会被静默忽略。

### 验收

- 首次成功连接并保存后，退出并重新打开 Farframe，点击卡片无需重新输入用户名/密码。
- 使用数据库查看工具检查，找不到密码或可复用认证秘密。
- macOS“钥匙串访问”中可看到由 Farframe 创建、名称可识别的项目。
- 修改连接显示名称、主机别名不会让凭据意外丢失。
- 更新密码后旧密码不能再被应用读取。
- 删除连接后，对应 Keychain item 和信任记录消失。
- Keychain 被锁定、用户拒绝访问或项目缺失时，应用不崩溃并要求重新输入。
- 错误密码只产生一次清楚的认证失败，不无限自动重试或锁定 Windows 账户。
- 在线探测失败时仍可手动点击，适应防火墙阻止探测但允许网关连接的环境。

## 步骤八：实现 RDP 基础通道

### 工作

- 文本剪贴板双向同步，并提供会话级开关。
- 增加图片和文件剪贴板前先建立大小限制、格式白名单和取消机制。
- 实现远端音频播放及设备切换。
- 支持动态分辨率。
- 支持本地目录重定向；只暴露用户明确选择的目录。
- 处理会话内 Windows 时区、键盘布局和锁定键同步。
- 给每个重定向能力提供单独开关，默认采用最小权限。

### 工作目标

覆盖日常 RDP 使用的基础功能，同时防止剪贴板和文件映射成为不透明的数据通道。

### 验收

- 中英文纯文本双向复制正确。
- 关闭剪贴板后两个方向均不再传输。
- 远端音频连续播放，断线后音频设备正常释放。
- 窗口尺寸变化后 Windows 分辨率随策略改变。
- Windows 只能访问用户明确映射的本地目录。
- 大剪贴板和大文件传输可取消，UI 不冻结。

## 步骤九：增加高级 RDP 能力

### 工作

- RD Gateway：独立网关地址、认证方式、凭据和证书信任。
- 多显示器：显示器选择、布局、缩放和主屏映射。
- RemoteApp：资源启动、窗口生命周期和错误处理。
- 麦克风重定向：系统权限说明、设备选择和隐私指示。
- 打印机、智能卡等设备重定向按真实需求逐项实现。
- 自动重连：网络短暂中断时使用有限、可取消、带状态提示的重连策略。

### 工作目标

在不牺牲基本会话稳定性的前提下，扩展到企业和专业用户场景。

### 验收

- 每项高级能力都有独立测试环境和兼容性记录。
- RD Gateway 直连失败、网关认证失败和目标认证失败能被区分。
- 多显示器坐标和缩放正确，退出全屏后窗口可恢复。
- RemoteApp 退出不会错误关闭其他会话。
- 拒绝麦克风权限时只关闭麦克风重定向，不影响桌面连接。
- 网络恢复后的重连不会重复创建窗口或遗留旧输入状态。

## 步骤十：安全加固

### 工作

- 建立威胁模型：凭据窃取、中间人、恶意剪贴板、恶意文件名、服务端图形数据解析、日志泄密、依赖漏洞。
- 所有来自 RDP 服务端的数据视为不可信。
- 为尺寸、长度、像素缓冲、剪贴板和路径做边界检查。
- 禁止路径穿越和符号链接越权。
- 对 FreeRDP 与加密依赖建立更新和 CVE 处理流程。
- Release 开启 Hardened Runtime 的兼容性测试，即使个人自用阶段不公证。
- 测试崩溃报告是否包含凭据。
- 提供“一键清除全部本地数据和凭据”。

### 工作目标

远程服务端即使恶意或被攻陷，也不能轻易读取未授权本地文件、获得密码或控制 Farframe 之外的 Mac 输入。

### 验收

- 安全测试用例覆盖畸形尺寸、超大剪贴板、路径穿越和异常证书。
- Sanitizer 测试无已知越界、UAF、数据竞争。
- 日志和诊断包自动脱敏。
- 依赖清单能准确映射到应用中实际链接的版本。
- 清除数据后数据库、Keychain 和证书信任均无残留。
- 增强键盘捕获永远不会在 Farframe 失焦时继续运行。

## 步骤十一：稳定性、性能与体验验收

### 工作

- 持续连接、反复连接/断开、睡眠唤醒、切换 Wi-Fi、服务端重启测试。
- 测量协议线程、渲染线程、主线程、内存和 GPU 使用。
- 优化脏矩形合并、显示同步和帧丢弃策略：宁可丢弃过时中间帧，也不允许输入事件因渲染积压而延迟。
- 为所有错误提供恢复动作。
- 建立可导出的脱敏诊断包。
- 完成 VoiceOver 标签、键盘导航、对比度和缩放。

### 工作目标

Farframe 在真实办公会话中可以长期运行；断线、休眠和异常服务端不会迫使用户强制退出应用。

### 验收

- 重复连接和断开无持续线程、句柄或内存增长。
- Mac 睡眠唤醒后能明确重连或进入可恢复失败状态。
- UI 主线程在高频画面更新中仍响应窗口和菜单操作。
- 输入优先级高于非关键画面刷新。
- 诊断包足以定位阶段和错误，但不含密码、剪贴板内容或完整用户名。
- 所有支持功能都在兼容性矩阵中有对应测试结果。

## 5. 快捷键设置界面规格

建议设置路径：

```text
设置
└── 键盘与快捷键
    ├── 基础映射
    │   ├── Command 键发送为
    │   ├── Option 键发送为
    │   └── 左右修饰键分别设置
    ├── 常用快捷键
    │   ├── 复制、粘贴、剪切、撤销
    │   ├── 保存、查找、打印
    │   ├── 新建、关闭标签
    │   └── 退出/关闭保护
    ├── 系统快捷键
    │   ├── 应用切换
    │   ├── Spotlight/Windows 搜索
    │   └── Mission Control/虚拟桌面
    ├── 捕获范围
    │   ├── 仅全屏
    │   └── 窗口和全屏
    └── 增强捕获
        ├── 权限状态
        ├── 打开系统设置
        └── 测试键盘捕获
```

每个连接可以：

- 使用全局快捷键配置
- 复制一份作为该连接专用配置
- 随时恢复默认值

远程窗口工具栏显示一个键盘图标：

- 灰色：画布未聚焦
- 蓝色：基础捕获
- 紫色：增强捕获
- 黄色警告：权限缺失或 event tap 已降级

## 6. 连接列表和一键进入界面规格

每台电脑卡片显示：

- 名称
- 主机名或地址
- 用户名/域摘要
- 在线状态
- 上次成功连接
- 是否保存了凭据
- 证书变化或认证错误警告

交互：

- 单击侧边栏电脑：只切换右侧详情，不发起连接
- 从右侧详情页的明确“连接”按钮发起连接
- 卡片菜单：编辑、在新窗口连接、更新密码、删除保存的密码、删除电脑
- 双击是否连接由设置决定，避免与单击行为冲突
- 连接期间卡片展示阶段并允许取消
- 同一 Profile 默认禁止误开重复会话；需要时允许显式“在新窗口连接”

## 7. 兼容性测试矩阵

至少覆盖：

### Windows

- Windows 10/11 Pro
- Windows 11 Enterprise 或域环境
- 当前 Windows Server
- 本地账户
- Microsoft/域账户
- NLA 开启
- 自签名证书
- 受信任 CA 证书
- 非默认端口

### Mac

- Apple Silicon
- 项目声明支持的最低 macOS
- 当前 macOS
- Retina 内屏
- 外接非 Retina 和不同缩放显示器
- 中文、英文键盘布局和输入法

### 网络

- 局域网
- 高延迟
- 丢包
- IPv6
- DNS 变化
- 网络切换
- RD Gateway

### 快捷键

- 每个预置快捷键的开/关
- 画布聚焦/失焦
- 窗口/全屏
- 权限允许/拒绝
- 应用切后台
- 突然断线
- 多种物理键盘布局

## 8. 发布门槛

即使只供开发者本人使用，每次可交付构建也必须满足：

1. 连接、认证、断开和重连没有已知高危崩溃。
2. 密码只存 Keychain。
3. 证书不会被静默接受。
4. `Command-W` 等启用的快捷键在远程焦点内不会触发本地动作。
5. 离开远程焦点后所有 macOS 快捷键恢复。
6. 没有卡住的修饰键。
7. 第三方许可证完整。
8. 兼容性矩阵与实际测试一致。
9. 不能捕获的系统快捷键已明确披露。
10. 可以从应用内删除连接及其全部凭据。

## 9. 推荐实施优先级

开发顺序应保持以下依赖关系：

```text
工程骨架
→ FreeRDP Bridge
→ 最小连接
→ 图形
→ 基础键鼠
→ 应用内快捷键捕获
→ Profile + Keychain 一键连接
→ 剪贴板/音频/动态分辨率
→ 增强系统快捷键捕获
→ RD Gateway/多显示器/RemoteApp
→ 安全、性能和发布验收
```

不要在最小连接和输入状态机尚未稳定前，同时开发所有虚拟通道。快捷键捕获必须建立在正确的 scan code、修饰键状态和焦点生命周期之上；一键连接必须建立在正确的证书验证和认证失败处理之上。

## 10. 最终完成定义

Farframe RDP 达到项目当前目标，需要同时满足：

- 用户可以创建连接、保存凭据、退出应用后重新打开并单击进入 Windows。
- 密码不出现在数据库、偏好设置、日志和崩溃诊断中。
- TLS/NLA 和证书变化处理正确。
- 远程画面、键鼠、输入法、剪贴板、音频、动态分辨率和全屏达到兼容性矩阵要求。
- `Command-W` 及设置中启用的常用快捷键，在远程画布聚焦时只执行配置的远程行为。
- 画布失焦、断线或应用切后台后，macOS 快捷键立即恢复。
- 增强捕获权限被拒绝时可以安全降级。
- 系统保留快捷键的限制如实显示。
- 反复连接、断开、睡眠和网络变化不产生凭据泄漏、卡键、后台事件捕获或持续资源增长。

---

## 参考资料

- [FreeRDP 官方仓库](https://github.com/FreeRDP/FreeRDP)
- [FreeRDP macOS 构建说明](https://github.com/FreeRDP/FreeRDP/wiki/Compilation)
- [FreeRDP API 文档](https://pub.freerdp.com/api/)
- [Microsoft RDP 协议总览](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdsod/072543f9-4bd4-4dc6-ab97-9a04bf9d2c6a)
- [Apple NSEvent 文档](https://developer.apple.com/documentation/appkit/nsevent)
- [Apple CGEventTapCreate 文档](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple Keychain Services 文档](https://developer.apple.com/documentation/security/keychain-services)
- [Apple：Adding a password to the keychain](https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain)
