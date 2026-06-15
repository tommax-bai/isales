## Why

`engine-auto-restructure-on-interrupt`（2026-06-15 archived）让"被打断 → 让 AI 把刚被切断的话顺过来接着说"（restructure）成为一个 campaign 一键开关 `auto_restructure_on_interrupt`。它的 proposal 把意图写得很清楚——"只有**没营养的插话**落到缺省位时才自动续说"——但**实现并没有真去判断"有没有营养"**：它把**所有**未命中显式 routing rule、落到 `decide()` 缺省 `continue` 的打断都改判为 restructure。

这留下一个缺口：客户用**实质问题 / 反对**打断（如"那一共多少钱""我不需要"），而该 campaign 又**恰好没有**一条对应的显式 routing rule 命中时，这次打断也落到缺省位 → 被错误重组（AI 顺着说完上一句，而不回答客户的问题）。`routing_rules` 通常只配了 `goal_achieved` / `customer_decline` / `transfer` 这类终态规则，覆盖不到"问价格""提疑虑"这类实质打断，所以这个误重组在真实通话里很常见。

本变更兑现 auto_restructure 原本写明、却没做到的意图：让**主门控（gate）referee** 真正去判"这次打断有没有营养"，只有判为"无营养垫词"时才自动续说；判为实质提问 / 反对时仍由常规路由正面作答。

## What Changes

- **门控保留类别 `FILLER`**：主门控 referee 的输出枚举新增一个保留类别 `FILLER`（"无营养的插话 / 垫词 / 随口附和 / 口头催促"，仅在打断场景成立）。引擎新增 `PipelineConfig.restructure_gate_category`（默认 `"FILLER"`）作为识别该信号的单点契约——engine 仍 MUST NOT 解释门控其余枚举语义，只把这**单一保留类别值**当作重组信号（等价于一条隐式 `match==FILLER → restructure` 的开关，刻意**不**复活已删除的 restructure routing action）。
- **override 收紧**：`run_loop.py` 在 `decide()` 调用点的自动重组改判，触发条件从"无显式规则命中（`action.kind=="continue"`）"再 AND 上"主门控本轮 category == `restructure_gate_category`"。主门控判实质（非 FILLER）→ 不改判、正常作答。`decide()` 仍保持纯函数（override 在调用点）。
- **门控打断信号注入**：engine 在调用主门控前，向其 prompt 注入两个占位符 `{{was_interrupted}}`（本轮 `session.interrupt_remaining_text` 非空 → "是"，否则"否"）与 `{{interrupted_reply}}`（被打断、尚未说完的那句 AI 残句）。门控 prompt 未含占位符时注入为 no-op（向后兼容旧 prompt）。
- **跨轮残句清理（不变量）**：当本轮有 `interrupt_remaining_text` 但**未**改判 restructure（门控判实质、已正常作答）时，engine 清空该字段，避免上一轮残句泄漏到后续轮被误用于重组。
- **seed 门控 prompt 改写**：`seed_pipeline_stream_campaign.py` 的 `REFEREE_PROMPT` 改写为 FILLER-aware 版本（在 campaign 实际枚举基线上新增 FILLER + 引用两个占位符 + FILLER/实质判别准则 + 对照 few-shot）。

复用现有 `auto_restructure_on_interrupt` 开关 / `kind=restructure` slot / `max_continuous_restructure` 封顶 / restructure route 执行路径，全部不变。`auto_restructure_on_interrupt` 为 OFF（默认）的存量 campaign 行为逐字节不变。

无 **BREAKING**：`restructure_gate_category` 默认 `"FILLER"`、引擎侧默认值（v1 不暴露 campaign 列）；门控 prompt 未含 FILLER / 占位符的存量 campaign 注入为 no-op、行为不变。

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `ai-pipeline`：MODIFIED「被打断自动重组开关 auto_restructure_on_interrupt」——缺省出口改判 restructure 的触发条件由"所有未命中"**收紧**为"主门控判 `restructure_gate_category`（默认 FILLER）"；新增门控打断占位符 `{{was_interrupted}}` / `{{interrupted_reply}}` 注入约定；新增"未重组则清空 `interrupt_remaining_text`"的跨轮不变量。

## Impact

- **isales-engine**：
  - `referee.py`（`run_referee`，已持有 `session` 首参）：注入 `{{was_interrupted}}` / `{{interrupted_reply}}` 占位符（读 `session.interrupt_remaining_text`，只读不清）。
  - `pipeline/prompt_builder.py`（`PipelineConfig`）：新增 `restructure_gate_category: str = "FILLER"`。
  - `run_loop.py` `decide()` 调用点：override 条件 AND 主门控 `effective_category() == config.pipeline.restructure_gate_category`；新增"未改判 restructure 但有残句 → 清空 `interrupt_remaining_text`"分支。
  - `providers/llm_mock.py`：`_referee` 能在被打断 + 垫词输入下产出 `FILLER`（端到端测试需要）。
  - `tests/`：`test_run_loop`（FILLER 才 fire / 实质不 fire 且清残句 / 非打断不 fire）、`test_referee`（占位符注入断言）。
- **isales-api**：`scripts/seed_pipeline_stream_campaign.py` 的 `REFEREE_PROMPT` 改写为 FILLER-aware。
- **无 isales-common / alembic / isales-web 改动**：不加 campaign 列（`restructure_gate_category` 引擎默认）；不加 UI（门控 prompt 走现有 PromptTierEditor，`auto_restructure_on_interrupt` 开关 UI 已存在）。
- **Deploy**：scp engine + 重启；生产 campaign 把门控 prompt 重写为 FILLER-aware（含 FILLER + 占位符）、确认 `auto_restructure_on_interrupt=ON` + restructure slot 存在；真机抽验合并到 `pipeline-stream-realmachine-acceptance`。
