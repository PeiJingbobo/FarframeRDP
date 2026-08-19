# Third-party components

Farframe RDP 的原生依赖必须锁定精确版本或提交，并能从仓库脚本确定性构建。运行时不得依赖开发者的
Homebrew 安装。

## 引入依赖前必须记录

- 组件名、上游地址、精确版本/提交；
- 实际启用和关闭的能力；
- 许可证及 notice 文件；
- 安全与 CVE 更新策略；
- 构建架构、产物形式和复现命令；
- 是否进入最终二进制及对应验证方法。

许可证原文放入 `third-party/licenses/`。当前实际静态链接 FreeRDP/WinPR 3.30.0、OpenSSL 3.5.7
和 OpenH264 2.6.0；
精确提交见 `versions.sh`，能力与安全决策见
`docs/task/phase-2-native-dependency-decision.md`，验证与链接审计见
`docs/task/phase-2-validation.md`。

可分发组件清单见 `sbom.spdx`。`scripts/verify-supply-chain.sh` 离线验证锁定值、SBOM、许可证和已有
原生产物清单；`scripts/audit-native-cves.sh` 独立执行联网 OSV 提交查询。完整更新与漏洞处置流程见
`docs/security/dependency-management.md`。
