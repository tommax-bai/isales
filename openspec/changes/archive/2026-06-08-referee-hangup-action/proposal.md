<!-- SUPERSEDED 2026-06-08 by `engine-tools-multidialogue-gating`（§0.1）。hangup 未按本提案的独立 DeciderAction 实现，而是被 gating 重构吸收为 `tool:hangup` 懒路由并已部署（engine b3f79b1）。本提案 spec delta 为废弃设计，归档 --skip-specs 不并入 specs/。 -->

## Why

裁判（referee）目前无法让 AI 主动挂断通话。路由动作只有 `transition`（goal_achieved / transfer / customer_decline）和 `restructure`：其中 `customer_decline` 是「兜底恢复、继续挽留」而非终止，`goal_achieved` 是正向收尾。真实外呼场景里，客户骂人、明确说「别打了 / 别再打了」、或反复表达强烈拒绝时，正确的产品行为是**当场礼貌结束并挂断**，而不是继续兜底纠缠——这既是合规要求也是体验底线。当前 campaign 的路由配置无法表达「裁判判定某情况 → 主动挂断」。

## What Changes

- 在 campaign 路由规则的动作类型里**新增 `hangup`（主动挂断）动作**，与 `transition` / `restructure` 并列。裁判某个 category 命中该规则时，AI 主动结束并挂断本通电话。
- `hangup` 动作带一个**可选的 `closing_phrase`（挂断前话术）**：非空则先经 TTS 播这一句再挂；为空则立即挂断（不新增对话轮次）。
- 新增挂断原因 **`HangupCause.REFEREE_HANGUP`**，记录这种「AI 依裁判判定主动挂断」的终态；retry-followup 将其归类为**不自动重拨**的终态桶（AI 主动结束，重拨与该决定矛盾）。
- 引擎 decider 在命中 hangup 规则时返回新的 `DeciderAction(kind=hangup, closing_phrase=...)`；run_loop 据此（可选播话术后）驱动状态机到 `END`，cause 记为 `referee_hangup`。
- web「多流路由」配置页的动作编辑器新增第三个选项「挂断」(含可选话术输入)。
- **顺带修复**同一动作编辑器的已知 bug：规则目标从 `goal_achieved` 切到其它目标时 `goal_type` 未清空，导致后端 422 保存失败。
- **BREAKING**（数据契约）：`RoutingAction` union 新增成员 `HangupAction`；`HangupCause` 枚举新增值。isales-common 升版本、下游 pin 同步。v1 无真实生产数据，旧 campaign 不含 hangup 规则、行为不变（纯增量）。

非目标（本次不做）：① 把 hangup 动作的处置桶（do-not-call vs 普通不重拨）做成每条规则可配——v1 固定为「不自动重拨」，per-rule disposition 留作后续；② RoutingRulesTab 更大范围的「字符串型 422/409 报错可读化」——独立 usability 改动，本次只修上面那个会导致保存失败的 goal_type bug。

## Capabilities

### New Capabilities
<!-- 无新增 capability —— 复用现有路由/状态机/数据模型能力 -->

### Modified Capabilities
- `ai-pipeline`: 路由 decider 的动作集合新增 `hangup`；定义裁判命中 hangup 规则时引擎 MUST 返回挂断决策、不再继续对话。
- `data-model`: `RoutingAction` 新增 `HangupAction{type:'hangup', closing_phrase?}`；`HangupCause` 新增 `REFEREE_HANGUP`。pipeline_trace 复用既有 `matched_rule`，不新增列。
- `call-state-machine`: 新增「裁判驱动的主动挂断」转移——hangup 动作 MUST 使通话进入 `END`（可选先播单句 closing_phrase），cause=`referee_hangup`；明确与 customer_decline（恢复继续）、goal_achieved（正向收尾）的边界。
- `web-admin-ui`: 「多流路由」动作编辑器 MUST 支持配置 hangup 动作及可选话术；并修复目标切换时 goal_type 残留导致保存失败的缺陷。
- `retry-followup`: 新挂断原因 `referee_hangup` MUST 被归类为不触发自动重拨的终态。

## Impact

- **isales-common**：`schemas/jsonb/routing_rule.py`（加 `HangupAction` + union 成员）、`enums.py`（`HangupCause.REFEREE_HANGUP`）；版本 bump + 下游 pin（engine/api/scheduler）。pipeline_trace 无 schema 变更。
- **isales-engine**：`pipeline/decider.py`（命中 hangup → `DeciderAction(kind=hangup)`）、`run_loop.py`（执行：可选播 closing_phrase → END）、`call_lifecycle.py`（`referee_hangup` cause 解析与归类）。
- **isales-api**：`routing_validation.py` / schemas 对 hangup action 的校验（动作形状主要由 common schema 管；closing_phrase 长度等）。
- **isales-web**：`views/Campaigns/Tabs/RoutingRulesTab.vue`（动作编辑器加「挂断」+ 话术 + 修 goal_type bug）、`types/campaign.ts`（`HangupAction` 类型 + 默认值）、`tests/routingRulesTab.test.ts`（新增用例）。
- **迁移**：无 DDL（routing_rules 为 JSONB；HangupCause 为 String 列，无 PG enum DDL）。retry-followup 分类表新增一条 `referee_hangup → 不重拨` 映射。
- **运营文档**：说明「挂断」与「客户拒绝」如何选用。
