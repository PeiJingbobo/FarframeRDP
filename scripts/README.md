# Scripts

本目录存放可复现的项目命令，不存放机器地址、账号、证书、签名身份、密钥路径或真实测试端点。

脚本应：

- 从仓库状态探测 project/workspace、scheme、SDK、架构和 destination；
- 把 Derived Data 和原生依赖产物写入已忽略的明确目录；
- 非交互执行并在失败时返回非零状态；
- 输出足够定位问题但已脱敏的日志；
- 不以关闭 TLS、证书验证、Hardened Runtime 或修改 Bundle ID/Team ID 来绕过错误。

## 当前脚本

- **build-native-dependencies.sh**：获取固定提交并构建 arm64 静态 FreeRDP/WinPR/OpenSSL。
- **test-native-bridge.sh**：使用 ASan/UBSan 运行独立 Bridge 所有权与线程 harness。
- **test-rdp-integration.sh**：只从 Git 忽略的本地 JSON 读取端点、临时凭据和证书决定，编译并运行真实连接 harness。
- **build.sh**：先确保原生依赖存在，再构建 FarframeRDP scheme；默认 Debug。
- **test.sh**：先确保原生依赖存在，再运行 Core、App 和 Bridge 三个测试 target；默认 Debug。
- **FARFRAME_CONFIGURATION**：可选 Debug、Release 或 Sanitizer。
- **FARFRAME_DERIVED_DATA_PATH**：可覆盖默认的项目内 .derivedData。
- **FARFRAME_CMAKE**、**FARFRAME_NINJA**：工具不在 PATH 时指定其可执行文件。

## 真实连接配置

默认配置路径是 config/local/integration.json，且脚本会先用 git check-ignore 拒绝任何可能被跟踪的配置。
本地 profile 在 config/integration.example.json 的非秘密字段之外，还需提供仅存在于本地文件的 password
和 certificateDecision（reject、once 或 store）。可选 cancelDelayMilliseconds 用于连接阶段取消测试。

脚本不会输出配置值，也不会把密码放入命令参数。不要使用 shell 跟踪模式运行该脚本。

Phase 2 验证见 docs/task/phase-2-validation.md。Phase 3 已验证 17 项 Xcode 测试、原生
sanitizer、Release 构建和真实 NLA 连接，结果见 docs/task/phase-3-validation.md。
