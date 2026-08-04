# Skills Manager 0.2.1

中文

- 保留“左侧 Skill 列表 + 右侧详情”两栏布局，将已管理 Skill、本机发现候选、ClawHub Latest Drops 和 skills.sh 搜索结果收敛到同一列表。
- 在列表行内显示管理状态与来源标签，选择任意结果时，右侧详情和工具栏会与当前对象保持一致。
- 空搜索会显示本机 Skill 和 ClawHub 最新内容；输入关键词时会同时搜索本机、ClawHub 与 skills.sh。
- 改善远程结果的加载更多与错误隔离；单个 Provider 不可用不会影响其他来源或本地 Skill。
- 修复快速搜索、刷新或切换 Skill 时可能残留旧详情与错误操作的问题。

已知限制

- skills.sh 使用未文档化公共接口，可能临时或永久不可用；失败不会影响本地、ClawHub 或已管理 Skill。
- 本版本不通过 Mac App Store 分发。

English

- Keeps the two-column Skill list and detail layout while bringing managed skills, on-device discoveries, ClawHub Latest Drops, and skills.sh search results into one list.
- Shows management status and source labels in each row; the detail pane and toolbar now stay aligned with the selected result type.
- Shows local skills and ClawHub latest content for an empty query, then searches local skills, ClawHub, and skills.sh together when a query is entered.
- Improves remote pagination and failure isolation so one unavailable provider does not hide other sources or local skills.
- Fixes stale details and incorrect actions that could remain after rapidly searching, refreshing, or switching skills.

Known limitations

- skills.sh uses an undocumented public endpoint that may become temporarily or permanently unavailable; failures do not affect local, ClawHub, or managed skills.
- This release is not distributed through the Mac App Store.
