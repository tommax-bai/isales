## Why

复盘 campaign 1 发现「目标达成」从未被记录:160 通 `call_summary` 全部 `goal_achieved=false`,看板达成率(`/analytics/goal-rate`)恒为 0,谈成的客户也无法进入 `COMPLETED`。根因不是 spec 写错,而是**多处代码漂移于现有 `goal-achievement` / `transcript` spec**,叠加 campaign 配置缺口:

- worker 汇总在找一个引擎根本不写的事件类型(`bot_speech`),而引擎写的是规范类型 `ai_reply` → `goal_achieved` 对每通电话被无条件清成 false,且通话摘要正文也丢失全部 AI 回复;
- engine `route` 动作丢弃 `goal_type`,违反 spec「`goal_type` SHALL 取自命中规则 action」;
- campaign 1 的 referee prompt 从不输出成功类 category,且对应 routing rule 用 `tool:hangup`(不进 closing route),即便前两项修好也不会触发达成。

该 bug 被测试 fixture(用旧名 `bot_speech`)掩盖,单测全过、生产全错;`bot_speech` 是 2026-05-06 `impl-worker` 旧事件名,`2026-06-10-fix-transcript-schema-drift` 已把契约规范成 `ai_reply`,但 worker 是那次修复漏掉的一条尾巴。

## What Changes

- **[isales-worker]** `_last_role_markers` 与 `_stitch_text` 改读 `ai_reply` 事件(对齐 `transcript` 权威契约),不再读 `bot_speech`;更新 `base.py` 中 stale 的契约 docstring。修复 `goal_achieved` / `goal_type` 标记读取与摘要正文拼接。
- **[isales-engine]** `pipeline/decider.py` 的 `route` 动作对称补齐 `goal_type` 提取(与 `transition` 动作一致),使 `{type: route, to: closing, goal_type: X}` 能把 `X` 真正落进 `goal_achieved` 事件。
- **[config / data]** campaign 1 的 referee(`main_judge`)prompt 增补「已达成」判定语义与输出 category;对应 routing rule 由 `{type: tool, tool: hangup}` 改为 `{type: route, to: closing, then_state: WRAPPING_UP, goal_type: <待定>}`。此为 `goal-achievement` spec 既定正路,无需 DB schema 变更。
- **[cleanup]** 删除 campaign `tools` 中 orphan 的 `end_call`(零代码引用的 seed 残留);**[isales-web]** `RoutingRulesTab.vue` + `types/campaign.ts` 动作类型下拉移除 `transition(旧)` / `restructure(旧)` 两个 legacy 选项(0 campaign 在用,engine 保留 removal-tracked shim 仍执行存量规则,仅收口编辑入口)。
- **[spec 硬化]** 在 `goal-achievement` spec 补 scenario,把「worker 从哪个 transcript 事件类型读取 goal 标记」钉死为 `ai_reply`(+ 独立 `goal_achieved` 事件),并明确 `route` 与 legacy `transition` 动作的 `goal_type` 提取对称——把上述两个代码 bug 锁进 spec,防止此类漂移再次发生。`transcript` spec 已正确定义 `ai_reply` 承载 goal 标记(枚举中本就无 `bot_speech`),无需改动。

注:除 spec 硬化外,代码改动均为**回归现有 spec 的 bug fix**,不引入新行为。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `goal-achievement`: 修订「实时目标达成判定」requirement,新增两条 scenario——(a) 钉死 worker 读取 goal 标记的 transcript 事件类型为 `ai_reply`(/ 独立 `goal_achieved` 事件),消除 `bot_speech` 这一已废弃事件名残留导致的读取漂移;(b) 明确 `route` 与 legacy `transition` 动作的 `goal_type` 提取对称。

<!-- transcript spec 已正确定义 ai_reply 承载 goal 标记、枚举中无 bot_speech,无需 delta -->
<!-- decider route goal_type 提取、worker 读 ai_reply 均为回归现有 spec 的 bug fix,不单列 capability -->
<!-- web legacy 选项移除、end_call 清理为纯实现/数据清理,无 spec 行为变更 -->
<!-- referee prompt + routing rule 改 = goal-achievement spec line 26-29 既定机制的 campaign 配置应用,非 spec 变更 -->
- `data-model` / `ai-pipeline` / `retry-followup` / `web-admin-ui`: 不修改,仅受益于上述 bug fix 后行为恢复正常。

## Impact

- **isales-worker**: `isales_worker/llm/mock.py`(`_last_role_markers`、`_stitch_text`)、`isales_worker/llm/base.py`(docstring)。修复后 `call_summary.goal_achieved` / `goal_type` / 摘要正文恢复正确;下游 `lead_state`(COMPLETED 判定)与 `process_callbacks`(webhook trigger)随之恢复。
- **isales-engine**: `isales_engine/pipeline/decider.py`(`route` 动作 `goal_type` 提取)。下游 `goal_achieved` 事件的 `goal_type` 字段恢复正确。
- **isales-web**: `src/views/Campaigns/Tabs/RoutingRulesTab.vue`、`src/types/campaign.ts`(移除 legacy 动作类型选项)。
- **数据 / 配置**: campaign 1 的 referee prompt(`prompt_version`)、`routing_rules`、`tools`(删 `end_call`)。无 DB schema / alembic 变更。
- **指标**: 看板 `/analytics/goal-rate` 修复后将反映真实达成率(此前恒 0)。
- **测试**: worker 现有测试 fixture 使用旧名 `bot_speech`,需同步改为 `ai_reply`,否则新代码下测试会反向失败(此前是它们掩盖了 bug)。
