## Context

Slice 1 已上线收尾期「客户静默 → 主动挂断」。本 change（Slice 2）补另一正交场景：进入收尾（goal achieved / WRAPPING_UP）后客户**又开口**但**没有实质新问题**时提前挂断。

当前 `_gated_wrap_up_turn`（run_loop.py）跑简化管线：`run_pipeline_stream(..., is_wrap_up=True)` → `_play_streaming` → `wrap_up_round_count += 1` → `evaluate_wrap_up`（计数器）。`orchestrator.PipelineStream.start()` 在 `is_wrap_up` 时直接 `return`、**不 spawn 任何 referee**（orchestrator.py:152）。normal turn 的 `referee → decide → tool:hangup → END` 路径完整（run_loop.py：`_await_referees` → `decide` → `sel.kind=="tool"` 且 `tool_type=="hangup"` → 设 `REFEREE_HANGUP` + `transition_to(END)` + `append_event("hangup")` + `RETURN`）。

用户决策（本 change 锁定）：①**精简内建开关式**（campaign bool + 引擎内建 prompt/类别，不走 routing_rules）；②裁判判「无问题」后**直接挂断、不加话**。

## Goals / Non-Goals

**Goals:**
- 收尾期 `wrap_up_referee_enabled=true` 时，客户开口回复经旁路裁判判「无问题」→ 复用现有 hangup→END 直接挂。
- 旁路=**非门控**：收尾回复照常播出，裁判与播放并行，播完后才消费结论。
- fail-open=不挂；barge-in=取消裁判+不挂。
- 默认关、opt-in，对存量 campaign 零影响。
- 计数器 + Slice 1 静默挂断原样保留。

**Non-Goals:**
- 裁判 prompt / 类别 operator 可配（本 change 内建固定；可配化另起 change 迁 `wrap_up_routing_rules`）。
- 收尾期门控（绝不门控收尾回复）。
- 给收尾裁判单独的 model/provider 选择（复用收尾回复同款 `providers.llm`）。

## Decisions

### D1：精简内建——一个 campaign bool + 引擎内建常量
新增 `campaign.wrap_up_referee_enabled`（bool NOT NULL default false）。裁判 prompt（`WRAP_UP_REFEREE_PROMPT`）+ 挂断类别（`WRAP_UP_HANGUP_CATEGORIES = frozenset({"无问题"})`）是 **engine 模块级常量**（precedent：`restructure_gate_category`）。不进 routing_rules、不新增 role_config 项、不碰 api routing 校验。
**备选**（否决，用户已选 A 弃 B）：`wrap_up_routing_rules` JSONB + operator 配规则——灵活但 blast radius 大（common JSONB 列 + api routing 校验 + web 路由编辑器），对「一个裁判一个动作」过度工程。

### D2：旁路并行——spawn 在播放前，消费在 played 后
`_gated_wrap_up_turn` 内：若 `config.wrap_up.referee_enabled` → 在 `_play_streaming` **之前** `ref_task = asyncio.create_task(run_referee(session, user_text, recent_dialog_rounds(session.dialog_history), <built-in spec>, providers.llm))`（与播放并行，近零额外延迟）。`_play_streaming` 照常播收尾回复（**不**传 referee、**不**门控）。
- `not played`（barge-in）→ `ref_task.cancel()` + 现有 `CONTINUE`。
- `played` → `try: result = await asyncio.wait_for(ref_task, referee_timeout_ms/1000); cat = result.category` `except (TimeoutError, Exception): ref_task.cancel(); cat = None`。
- `cat in WRAP_UP_HANGUP_CATEGORIES` → 复用 hangup→END（设 `REFEREE_HANGUP` + `transition_to(END, reason="wrap_up_referee_hangup")` + `append_event("hangup", reason="wrap_up_referee_hangup", initiated_by="ai")` + `RETURN`），并把 result 写进本轮 trace 的 `referee_results`。
- 否则落现有 `wrap_up_round_count += 1` + `evaluate_wrap_up`（计数器兜底）。
**备选**（否决）：复用 `decide()`/routing_rules——本 change 内建单动作，直接 `cat in 集合` 成员判定更省；fail-open 仍安全（`run_referee` 异常/空→`category=None`→不在集合→不挂）。

### D3：LLM 复用 `providers.llm`
收尾裁判用 `providers.llm`（与收尾回复同一 LLM，prod 已验证可用），built-in `RefereeSpec`（label `wrap_up_referee`，temperature/top_p 取默认 1.0）。不引入 per-slot model 选择。

### D4：挂断 reason / cause——零 schema 漂移
`HangupEvent(reason="wrap_up_referee_hangup", initiated_by="ai")`（free-form str）+ 复用 `HangupCause.REFEREE_HANGUP`（语义=referee 裁决挂断，精确匹配）。**不**碰封闭 `wrap_up_completed.reason` Literal、**不**加枚举（沿用 Slice 1）。

### D5：类别二分——`有问题` / `无问题`，挂断仅 `无问题`
内建 prompt 让裁判只输出一个词：客户这句有需 AI 回答的实质新问题→`有问题`；只是附和/客套/同意结束/无内容→`无问题`。挂断集合 `{"无问题"}`。bare-token 解析会 strip 标点（referee.py:141），`无问题。`→`无问题` 仍命中。fail-open（None/空/超时/其它词）→ 不在集合 → 不挂。

### D6：放宽 ai-pipeline「简化管线」spec
现 req 明文 `MUST NOT 启动 referee`。MODIFIED 为：`MUST NOT 门控收尾回复`；`MAY` 在 played 后并行跑**一个**非门控旁路裁判（唯一动作挂断）；fail-open=不挂。

## Risks / Trade-offs

- [裁判误判把想继续的客户挂了] → **缓解**：挂断只在显式 `无问题`；fail-open 不挂;barge-in 取消;默认关、需 operator 主动开;内建 prompt 强约束「只有确无实质问题才输出无问题」。
- [内建 prompt 不可调，措辞/语言不贴某 campaign] → **缓解**：分类任务窄、词汇稳定;若真需可配，另起 change 迁 routing_rules（已在 Non-Goals 标注移除/升级路径）。
- [api `CampaignNestedUpdate` 镜像漏改→PATCH 422]（Slice 1 踩过 hotfix `673697a`）→ **缓解**：tasks 显式列「补 api 镜像」+ 部署后 `/openapi.json` 探针验字段在。
- [收尾回复很短时 played 后 await 加延迟] → 上限 `referee_timeout_ms`(默认 600ms)，且仅在该轮触发;裁判与播放并行通常已完成 → 近零。
- [裸 await 卡死] → MUST `wait_for(timeout)` 包裹 + except→fail-open（绝不裸 await、绝不 else→挂）。

## Migration Plan

1. common：加 bool 列 + schema + alembic（down_revision `b3d5f7a9c1e2`，commit 前 `alembic heads`）+ 0.8.22 + CHANGELOG。
2. api：补 `CampaignNestedUpdate` 镜像字段。
3. engine：内建常量 + `WrapUpConfig.referee_enabled` + `_gated_wrap_up_turn` 旁路 + runtime_config 装配。
4. 部署：common scp + `alembic upgrade head`（列 server_default false，对在途安全）→ engine scp + restart → api scp + restart（拾镜像）→ web build + nginx reload。
5. **回滚**：行为回滚=不开 `wrap_up_referee_enabled`（默认关，部署即默认不触发）；代码回滚=scp 旧 engine/api/common + 重启；DB `alembic downgrade b3d5f7a9c1e2`。

## Open Questions

- 内建 prompt 具体措辞——实装时定稿（约束输出仅 `有问题`/`无问题`、给「无问题」的判据：附和/客套/同意结束/无实质内容）。
- 是否给收尾裁判独立 `referee_timeout_ms`——本 change 复用 `pipeline.referee_timeout_ms`（默认 600ms），不新增。
