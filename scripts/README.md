# Scripts

本目录存放可复现的项目命令，不存放机器地址、账号、证书、签名身份、密钥路径或真实测试端点。

脚本应：

- 从仓库状态探测 project/workspace、scheme、SDK、架构和 destination；
- 把 Derived Data 和原生依赖产物写入已忽略的明确目录；
- 非交互执行并在失败时返回非零状态；
- 输出足够定位问题但已脱敏的日志；
- 不以关闭 TLS、证书验证、Hardened Runtime 或修改 Bundle ID/Team ID 来绕过错误。

## 当前脚本

- **build-native-dependencies.sh**：按 `FARFRAME_ARCH=arm64|x86_64` 获取固定提交并构建单架构静态 FreeRDP/WinPR/OpenSSL/OpenH264。
- **build-universal-native-dependencies.sh**：构建两套单架构依赖并合并为 Universal 2 静态库。
- **validate-release-version.sh**：校验 `vX.Y.Z` 发布标签与 App Release `MARKETING_VERSION` 完全一致。
- **package-release.sh**：生成 ad-hoc 签名、未公证的 Universal 2 DMG 和 SHA-256 文件。
- **test-native-bridge.sh**：使用 ASan/UBSan 运行独立 Bridge 所有权与线程 harness。
- **test-rdp-integration.sh**：只从 Git 忽略的本地 JSON 读取端点、临时凭据和证书决定，编译并运行真实连接 harness。
- **build.sh**：先确保原生依赖存在，再构建 FarframeRDP scheme；默认 Debug。
- **test.sh**：先确保原生依赖存在，再运行 Core、App 和 Bridge 三个测试 target；默认 Debug。
- **FARFRAME_CONFIGURATION**：可选 Debug、Release 或 Sanitizer。
- **FARFRAME_DERIVED_DATA_PATH**：可覆盖默认的项目内 .derivedData。
- **FARFRAME_CMAKE**、**FARFRAME_NINJA**：工具不在 PATH 时指定其可执行文件；未显式指定生成器且
  Ninja 不存在时，原生依赖构建自动使用系统 `make`。
- **FARFRAME_RELEASE_TAG**：打包时必须提供的稳定标签，例如 `v0.1.0`。

## Universal Release 打包

首个版本基数为 `0.1.0`，对应标签必须是 `v0.1.0`。本地打包命令：

~~~sh
/bin/sh scripts/package-release.sh v0.1.0
~~~

产物写入 `.release/`。当前流程没有 Developer ID 证书，因此只进行 ad-hoc 签名且不提交 Apple
公证；从网络下载后可能被 Gatekeeper 阻止，不能把该产物描述为已签名公证版本。

推送格式为 `vX.Y.Z` 的标签会触发 GitHub Action。Action 在任何编译前读取 Xcode Release
构建设置；标签去掉 `v` 后与 `MARKETING_VERSION` 不一致时立即失败。成功后创建或更新 draft
GitHub Release，不自动公开发布。

## 真实连接配置

默认配置路径是 config/local/integration.json，且脚本会先用 git check-ignore 拒绝任何可能被跟踪的配置。
本地 profile 在 config/integration.example.json 的非秘密字段之外，还需提供仅存在于本地文件的 password
和 certificateDecision（reject、once 或 store）。可选 cancelDelayMilliseconds 用于连接阶段取消测试。

脚本不会输出配置值，也不会把密码放入命令参数。不要使用 shell 跟踪模式运行该脚本。

Phase 2 验证见 docs/task/phase-2-validation.md。Phase 3 已验证 17 项 Xcode 测试、原生
sanitizer、Release 构建和真实 NLA 连接，结果见 docs/task/phase-3-validation.md。
