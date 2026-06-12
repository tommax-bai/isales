## Why

iSales 的"被打断后让 AI 把刚被切断的话顺过来接着说"（restructure / 重组）今天**只能**靠运营在 campaign 上手写一对 `referee + routing_rule`（某 referee 判 NEGATIVE → `restructure source=interrupt_remaining`）才能触发。这对配置不直观、门槛高，且每个 campaign 都要重配。

但"被打断 → 重组复述残留"所需的引擎状态本身已经齐备：barge-in 检测（确定性规则树 `_partial_monitor`）、残留捕获（`session.interrupt_remaining_text`）、restructure route、连续封顶都现成，唯独缺一个让运营**一键启用**的开关。

本变更加一个 campaign 布尔开关 `auto_restructure_on_interrupt`：开启后，当本轮被 barge-in 打断、**没有任何显式 routing rule 命中**（decider 本应缺省 continue）、且配了 restructure slot 时，engine 自动把缺省出口改判为 `restructure(interrupt_remaining)`。门控 referee 仍按 gate-first 在前运行、显式规则仍 first-match-wins——它们是这个自动重组的 **veto**：客户真异议 / 要转人工时对应规则先命中、正常接管；只有"没营养的插话"落到缺省位时才自动续说。

**刻意不**采用用户最初设想的"引擎报状态就直接调重组、referee 放后面"拓扑，原因有二：

1. **时序**：重组音频必须等用户 ASR final 才能出声，否则会盖在还在说话的用户身上 = 二次抢话；而一旦等到 ASR final，referee 本来就要为本轮出话跑一遍（gate-first），把它放后面既违反 gate-first（放音前审）又丢掉"这次插话有没有营养"这条唯一能让重组用对的信息。
2. **成本**：referee 每轮都跑，restructure 只是它路由的一个出口，搭便车 0 额外 LLM 调用；跳过它不省钱，只让重组变傻。

故保留 referee 在前、把 restructure 作为**开关控制的缺省出口（fall-through）**，referee + 显式规则作 veto。

## What Changes

- 新增 campaign 字段 `auto_restructure_on_interrupt`（bool，NOT NULL，默认 `false`）。
- **engine**：在 `decide()` 调用点（gate 之后、`_select_gated_route` 之前），当 `action.kind == "continue"`（无显式规则命中）+ 开关 ON + restructure slot 存在 + `session.interrupt_remaining_text` 非空时，把 action 改判为 `DeciderAction(kind="restructure", source="interrupt_remaining")`。`decide()` 保持纯函数（override 在调用点，不进 `decide()`）。自动 restructure 仍受 `max_continuous_restructure` 封顶。开关 OFF（默认）时行为逐字节不变。
- **web**：「打断配置」卡片下新增该开关（`el-switch`），作为**与高级 / 非高级模式无关**的字段，渲染在模式切换器下方；文案说明作用与代价。
- bump `isales-common` 0.8.10 → 0.8.11（后续 0.8.13）；consumers（engine / api）bump pin。
- **同一变更内退役被取代的 restructure 路由动作**（开关一旦存在，"用规则触发 restructure" 即冗余——避免多路径兜底）：删除 legacy `type=restructure` action（common `RestructureAction`/`RestructureSource`）+ `route to=restructure` 目标（api `_BUILTIN_ROUTES`、web 下拉/source 选择器）+ engine decider 的 restructure 分支与 `restructure_enabled` 参数 + `_BUILTIN_THEN` 的 restructure。restructure 从此**纯开关驱动**（保留 restructure 角色 / route 执行路径 / `max_continuous_restructure` 封顶）。生产 0 campaign 使用该动作，删除无数据影响。

无 **BREAKING**：新列默认 `false`，存量 campaign 行为不变；restructure 路由动作生产无人使用，移除不影响在跑 campaign。

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `ai-pipeline`：新增 Requirement「被打断自动重组开关 auto_restructure_on_interrupt」；MODIFIED「路由规则引擎（decider）」——无命中缺省出口在开关下可改判 restructure，且 restructure 不再是 routing action；MODIFIED「重组流 restructure」——触发改为开关驱动；MODIFIED「重组流触发场景的 InterruptText 来源」——restructure source 固定 interrupt_remaining（switch），last_reply 仅退化兜底，去除 routing-rule source 字段。
- `data-model`：campaign 表新增 `auto_restructure_on_interrupt`（bool，NOT NULL，default false）；MODIFIED「routing_rules action 扩展」——删除 legacy `restructure` action + `route to=restructure` 目标。
- `web-admin-ui`：「打断配置」卡新增模式无关的自动重组开关。

## Impact

- **isales-common**：`models/campaign.py`（新列）、`schemas/campaign.py`（`CampaignBase` / `CampaignUpdate`）、新 Alembic 迁移（down_revision `f7a8b9c0d1e2`）、版本 0.8.10 → 0.8.11。
- **isales-engine**：运行时 `PipelineConfig`（`pipeline/prompt_builder.py`）+ `runtime_config.py` 读 campaign 字段 + `run_loop.py` `decide()` 调用点 override；`isales-common` pin bump；`test_run_loop` / `test_decider` 新增用例。
- **isales-api**：pin bump + `CampaignNestedUpdate` allowlist 补字段（否则 PATCH 静默丢弃该字段）。
- **isales-web**：`types/campaign.ts` + `CAMPAIGN_DEFAULTS` + `InterruptionTab.vue`（开关 + 文案）+ `campaignTabs.test.ts`。
- **Deploy**：RDS `alembic upgrade head` + 重部署 api / engine / web on ECS，smoke 一次 `auto_restructure_on_interrupt` 的 PATCH round-trip。
