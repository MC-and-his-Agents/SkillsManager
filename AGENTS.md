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

修改行为前先阅读相关事实来源。不要把这些信息复制到本文件；事实发生变化时，应更新所属文件。

## 构建与验证

- 构建：`swift build`
- 测试：`swift test`
- 开发期间运行可执行文件：`swift run CodexSkillManager`
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
