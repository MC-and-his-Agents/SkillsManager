# Skills Manager 代码审查规范

本文档定义 Skills Manager 实现 PR 的语义代码审查标准。审查目标是发现会影响正确性、用户数据、安全、兼容性和发布质量的问题，而不是复述 diff 或只检查格式。

## 审查前提

最小输入包括：

- 唯一 GitHub Work Item、上位 FR、范围、非目标与依赖关系。
- 当前 PR、branch、正式 worktree 与当前 head SHA。
- 已通过的规格审查，或 formal spec `not-applicable` 的理由和替代验证。
- 当前 diff、受影响调用链、测试与验证证据。
- 涉及数据或发布时的迁移、回滚、签名、公证和发布后验证方案。

缺少唯一 Work Item、当前 head 或必要规格时，不继续猜测实现意图，返回 `fallback`。CI 通过、`loom pre-review` 通过或文件齐全都不等于代码审查通过。

## 审查原则

- 先验证行为与风险，再看风格和命名。
- 只报告由当前变更引入或暴露、且作者可以采取行动的问题。
- Finding 必须包含具体文件和最小行范围、触发条件、影响与修复方向。
- 不因“测试通过”忽略测试未覆盖的边界，也不提出与当前 Work Item 无关的重构。
- 相同根因只报告一次，并说明其他受影响位置。

## 审查维度

| 维度 | 必查内容 |
| --- | --- |
| Work Item 范围 | diff 是否只实现已登记范围，是否遗漏验收项或夹带相邻需求 |
| 规格一致性 | 行为、身份、状态、错误与迁移语义是否忠实实现已批准规格 |
| 正确性 | 主流程、异常、边界、重复执行、取消和恢复是否产生正确结果 |
| 文件系统安全 | 规范化路径、NFC/大小写冲突、ZIP 条目、Symlink/Hardlink、根目录证明、资源上限、原子移动和安全删除 |
| 内容指纹 | 相对路径、长度、原始字节、稳定排序、排除项和 SHA-256 是否完全遵守合同 |
| SQLite 与一致性 | schema migration、事务、单写者、journal 阶段、幂等恢复和 DB/文件系统故障注入 |
| 身份与去重 | UUID、slug、来源 key、Provider 别名和本地 Fork 是否保持各自责任边界 |
| 分发与冲突 | 全局/Agent 专属互斥、Symlink/Copy 行为、外部修改、启用/停用及本体删除是否安全 |
| 并发与生命周期 | Swift concurrency 隔离、取消、重入、观察刷新和 App 重启是否会竞态或丢状态 |
| SwiftUI 边界 | View 是否只负责展示与交互，业务、文件、数据库和网络逻辑是否留在独立层；加载、空、错误与冲突状态是否可见 |
| Provider 与网络 | 真实来源去重、输入校验、分页、限流、离线、重试、超时和错误呈现是否正确 |
| 测试有效性 | 测试是否能在实现错误时失败，是否覆盖二进制、恶意路径、中断、冲突、迁移和恢复 fixture |
| 性能与资源 | 大目录扫描、哈希、SQLite 查询、网络和主线程工作是否受控，是否遵守数量与容量上限 |
| 可维护性 | UI、业务、数据访问和外部 API 是否分离；是否存在重复规则、无收益抽象、死代码或过大文件/函数 |
| 签名与发布 | Bundle ID、版本、签名、公证、Sparkle appcast、secret 边界、产物校验与升级路径是否一致 |

## Finding 优先级

- `P0`：确定或高概率导致任意文件删除、越权、密钥泄漏、不可恢复数据损坏或危险发布。
- `P1`：核心功能错误、状态不一致、身份破坏、迁移失败或广泛回归。
- `P2`：特定条件下的真实错误、恢复缺口、明显测试盲区或可维护性风险。
- `P3`：非阻断的小幅质量改进；不得用 P3 堆积偏好性意见。

存在 P0–P2 时结论必须为 `block`。没有 actionable finding 时明确写“未发现阻断问题”，但仍列出未验证风险。

## 审查结论

正式结论只能是：

- `allow`：当前 head 未发现未解决的 P0–P2，可进入 merge-ready。
- `block`：当前 head 存在必须修复的问题。
- `fallback`：事实链、规格或验证证据不足，应退回明确入口。

结论必须包含：

- `review_kind: code`
- `decision: allow | block | fallback`
- Work Item、PR、branch 与完整 `reviewed_head`
- 按优先级排列的 findings 和证据 locator
- 已执行验证、未执行验证及剩余风险
- 是否可以进入 merge-ready，或应退回 spec/build/pre-review 的哪一层

## 修复、复审与合并

- 修复 finding 后先排查同类根因，再请求复审。
- 任何代码或审查输入变化都会使旧 head 结论过期；必须针对新 head 重审。
- GitHub review 状态、语义 review artifact、CI 与 Loom gate 是不同证据，不得混写。
- `allow` 不等于 merge-ready；后者还需当前 head 的 host attestation、required checks、delivery gate 和 mergeability。
- 合并后仍须核对 merge commit、Issue 状态、目标分支、发布或 no-release 证据，并安全清理 branch/worktree。
- 不以 `.loom/reviews/**`、current、progress、shadow 或 repo-local closeout 文件替代 GitHub 与当前 head 事实。
