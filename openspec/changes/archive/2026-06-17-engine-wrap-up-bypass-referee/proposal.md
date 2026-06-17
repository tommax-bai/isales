## Why

Slice 1（`engine-wrap-up-silence-hangup`）只处理「客户在收尾告别后**沉默不说话**」→ 静默挂断。但还有一个正交场景没覆盖：**客户在告别后又应了一句**（如「嗯好的」「行吧拜拜」「没事了」），此时引擎仍会走简化管线**再回一句**，把对话不必要地拖长，直到轮数/秒数兜底耗尽才挂。用户想要的是：进入收尾（SUCCESS / goal achieved）后，若客户的回复**没有实质性新问题**（或明确同意结束），就提前挂断、不再硬聊。

根因（已代码核实）：收尾轮 `_gated_wrap_up_turn`（run_loop.py）跑的是**简化管线，不启动任何 referee / decider**（ai-pipeline spec「简化管线（WRAPPING_UP）」明文 `MUST NOT 启动 referee`），所以收尾期没有任何「客户这句还值不值得继续」的语义判定。

## What Changes

- 收尾轮新增一个**旁路（bypass，非门控、并行）收尾裁判**：与收尾回复**并行**运行，回复**照常播出**（绝不门控、不延迟告别语），播完**之后**才读裁判结论。裁判对客户这句回复二分类：`有问题`（有需 AI 回答的实质新问题）/ `无问题`（只是附和/客套/同意结束/无实质内容）。判定 `无问题` → 复用现有 `tool:hangup → END` 路径**直接挂断、不再多播一句话**。
- **精简内建开关式**：新增 campaign 布尔 `wrap_up_referee_enabled`（默认 **false**、opt-in）。裁判的 prompt 与类别词汇是**引擎内建常量**（不进 routing_rules、不新增 role_config 配置项、不碰 api routing 校验）。开关关闭 → 收尾轮行为与 Slice 1 完全一致（静默挂断 + 计数器兜底）。
- **fail-open 方向**：裁判超时 / 报错 / 空输出 → 视为「非 `无问题`」→ **不挂断**，继续走计数器兜底（绝不 else→挂）。挂断**只在**裁判显式输出 `无问题` 时发生。
- **barge-in 安全**：客户打断收尾回复（`not played`）→ **取消裁判任务**并 CONTINUE，绝不因裁判结论挂断一个正在提问的客户。
- 挂断走 `HangupEvent(reason="wrap_up_referee_hangup", initiated_by="ai")`（free-form reason）+ 复用 `HangupCause.REFEREE_HANGUP`；**不**碰封闭的 `wrap_up_completed.reason` Literal、**不**新增枚举（沿用 Slice 1 的零 schema 漂移做法）。
- 计数器 `wrap_up_max_rounds` / `wrap_up_max_seconds` 与 Slice 1 的静默挂断**原样保留**——三者覆盖互斥输入（有实质问题→继续聊到兜底；无问题→裁判提前挂；不说话→静默挂）。

非目标：让裁判 prompt / 类别词汇 operator 可配（本 change 走内建固定；如需可配化另起 change，迁到 `wrap_up_routing_rules` 模型）；收尾期门控（裁判**绝不**门控收尾回复）。

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `ai-pipeline`: 「简化管线（WRAPPING_UP）」requirement 从「`MUST NOT 启动 referee`」放宽为「`MUST NOT` 门控收尾回复；`MAY` 在收尾回复播出后并行跑**一个**非门控旁路裁判，其唯一动作是挂断；该裁判结论 `MUST` 在 `played` 之后才消费，fail-open 方向 `MUST` 为不挂断」。
- `goal-achievement`: 「收尾期间的特殊情况处理」requirement 新增场景「客户回复无实质新问题 → 收尾裁判判定 → 主动挂断」（与 Slice 1 的「客户静默 → 主动挂断」并列）。

## Impact

- **isales-common**：`models/campaign.py` 新增 `wrap_up_referee_enabled` 布尔列（NOT NULL default false）；`schemas/campaign.py` CampaignBase + CampaignUpdate；alembic ADD COLUMN（down_revision = `b3d5f7a9c1e2`，commit 前重跑 `alembic heads`）；版本 0.8.21→0.8.22 + CHANGELOG。
- **isales-api**：⚠️ `isales_api/schemas.py` 的**手维护镜像 `CampaignNestedUpdate`**（`extra="forbid"`、不继承 CampaignBase）必须补 `wrap_up_referee_enabled`，否则 web PATCH 带该字段会 422（见 2026-06-17 Slice 1 同类 hotfix `673697a`）。`CampaignNestedCreate` 继承 CampaignBase 自动带、无需改。
- **isales-engine**：`wrapup/manager.py` `WrapUpConfig` 加 `referee_enabled`；新增内建 `WRAP_UP_REFEREE_PROMPT` + `WRAP_UP_HANGUP_CATEGORIES={"无问题"}` 常量；`run_loop.py` `_gated_wrap_up_turn` 旁路跑裁判（spawn→播回复→played 后 `wait_for` 消费→命中即复用 hangup→END 路径，否则落计数器）；`runtime_config.py` 装配 `referee_enabled`。复用现有 `run_referee` + `providers.llm`（与收尾回复同一 LLM）。
- **isales-web**：`WrapUpTab.vue` 加「收尾裁判（无实质问题即挂）」开关 + `types/campaign.ts`。
- **specs**：`ai-pipeline` + `goal-achievement` MODIFIED delta。transcript 不动（free-form reason）。
- **行为变更**：仅对**显式开启** `wrap_up_referee_enabled` 的 campaign 生效；默认关、对存量零影响。
