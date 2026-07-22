# Skills Manager 开发规范

## 仓库范围

Skills Manager 是一款基于 SwiftPM 构建的 macOS SwiftUI 应用，不使用 Xcode 工程。

本文件只记录稳定的开发约束和事实来源入口。不要在此重复产品功能、界面结构、支持的平台、源码文件清单或发布实现细节；这些内容会随着产品变化，应维护在对应的事实来源中。

## 事实来源

- 产品介绍和面向用户的要求：`README.md`
- 支持的 macOS 版本、Swift 工具版本、target 和依赖：`Package.swift`
- marketing version 和 build number：`version.env`
- 应用行为和架构：`Sources/`、`Tests/`
- CI 和自动发布行为：`.github/workflows/`
- 本地构建、打包、签名和 appcast 实现：`Scripts/`
- 规格与合同审查标准：`spec_review.md`
- 实现代码审查标准：`code_review.md`

修改行为前先阅读相关事实来源。不要把这些信息复制到本文件；事实发生变化时，应更新所属文件。

## 构建与验证

- 构建：`swift build`
- 测试：`swift test`
- 开发期间运行可执行文件：`swift run SkillsManager`
- 打包并启动临时签名的本地应用：`./Scripts/compile_and_run.sh`

每次修改代码后运行 `swift build`，发现编译错误时先修复再继续。涉及行为、模型、解析、文件系统、导入或平台发现的改动，还应运行 `swift test`。只修改文档时不要求运行 Swift 构建。

修改打包或发布自动化时，还应运行适用的检查：

- Shell 语法：`bash -n Scripts/*.sh`
- GitHub Actions 语法：工具可用时运行 `actionlint .github/workflows/*.yml`
- 打包应用：检查本次改动涉及的 bundle 元数据、代码签名和内置资源

## 打包与发布

正式 GitHub 发布由 `.github/workflows/release.yml` 定义。发布 tag 必须与 `version.env` 中的 `MARKETING_VERSION` 一致；具体触发条件和步骤以 workflow 为准。

复用现有脚本，不要重新实现打包逻辑。证书、私钥、API 凭据和机器相关的发布配置必须放在仓库外。严禁提交 `release.env`、`.p8`、`.p12`、Sparkle 私钥或临时签名 keychain。

## 变更纪律

- 修改范围应与当前 issue 或任务一致。
- 除非任务明确要求，否则保持 SwiftPM 优先的项目结构。
- 行为发生变化时，新增或更新相应测试。
- 不要提交构建产物、打包应用、归档文件或临时文件。
- 使用功能分支和 pull request，不要直接在 `main` 上实施修改。
- 规格审查和代码审查必须分别遵循 `spec_review.md` 与 `code_review.md`；两者的结论不能互相替代。

<!-- LOOM_BOOTSTRAP_START -->
## Loom Execution

本仓库使用 Loom 编排 Work Item、build、review、merge-ready 与 host closeout。Loom
消费 GitHub 与工作现场事实，不用 repo current、progress、review、shadow 或 closeout
carrier 替代宿主真相。

开始改文件前：

1. 用 `loom route --target . --issue <issue> --json` 判断规划或执行入口。
2. 实现必须显式绑定 Work Item 与 issue-scoped branch；PR 创建前可直接运行
   `loom build --target . --issue <work-item> --branch <branch> --json`。
3. 一次只推进一个有界目标；不要创建空提交、空 PR 或治理载体来满足 admission。
4. PR 存在后再运行 `loom pre-review`、`loom review`、`loom merge-ready` 或 `loom ship`；
   这些入口从 GitHub readback 取得 branch、head、review、checks 与 merge 状态。
5. 验证证据记录命令、结果、时间或 head/run id；变更代码或 PR review 输入后重新确认
   current-head attestation 与 gate freshness。
6. merge 不等于产品完成；用 `loom attestation closeout` 消费宿主 closeout，用
   `loom release readback` 消费发布事实，不创建 closeout/current-retire PR。

环境或 provider 问题由 `loom doctor --target . --json` 分类；退役命令返回
`unsupported_command_surface`，不得通过 compatibility flag 恢复。
<!-- LOOM_BOOTSTRAP_END -->
