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

### 发布影响

每个 Work Item 和 PR 必须声明一种发布影响：

- `release_impact: none`：纯文档、测试、CI 或行为不变的内部重构。
- `release_impact: patch`：Bug、兼容性、UI 调整或已有功能完善。
- `release_impact: minor`：新增用户可见功能或改变产品行为。
- `release_impact: bundled #<release-issue>`：不单独发布，归入指定的开放 Release Issue。

影响已发布 App 行为、界面或用户数据的变更不得使用 `none`，除非明确使用
`bundled` 绑定已有 Release Issue。Release PR 本身使用 `bundled` 绑定它要完成的
Release Issue；该 Issue 使用 `patch` 或 `minor` 表达版本级别，不递归创建下一个版本。

PR 合并后，Owner 必须按声明收口：

- `none`：完成 no-release readback。
- `bundled`：将 PR 登记到指定 Release Issue。
- `patch` / `minor`：若没有待发布 Release Issue，立即创建；主分支 CI 全绿且没有开放
  `release-blocker` 后，创建只修改 `version.env` 与 `RELEASE_NOTES.md` 的发布 PR。

版本递增规则固定：`patch` 将 `0.2.0` 升为 `0.2.1`，`minor` 将 `0.2.x` 升为
`0.3.0`；每次发布 `BUILD_NUMBER` 恰好加一，不使用 pre-release。发布 PR 合并后由
自动化创建 tag，现有 Release workflow 继续负责签名、公证、Sparkle、GitHub Release
和公开安装验证；验证通过后才关闭 Release Issue。

## 变更纪律

- 修改范围应与当前 issue 或任务一致。
- 除非任务明确要求，否则保持 SwiftPM 优先的项目结构。
- 行为发生变化时，新增或更新相应测试。
- 不要提交构建产物、打包应用、归档文件或临时文件。
- 使用功能分支和 pull request，不要直接在 `main` 上实施修改。
- 规格审查和代码审查必须分别遵循 `spec_review.md` 与 `code_review.md`；两者的结论不能互相替代。

## GitHub 原生执行

1. 每项实现绑定唯一 GitHub Work Item、功能分支、正式 worktree 和 PR。
2. PR 必须声明发布影响，并通过 main 分支保护要求的 `build`、`test` 和
   `release-impact` 检查。
3. 规格审查、代码审查和 CI 是不同证据；代码或审查输入变化后，重新确认当前 PR head。
4. 合并前回读 Work Item、PR、branch、head、required checks、review 与 mergeability。
5. 合并后回读 merge commit、main CI、Issue 状态和发布或 no-release 结果，再清理现场。
6. GitHub Issue、PR、Actions、Release 与本地 Git 现场是执行事实来源；不要创建平行状态载体。
