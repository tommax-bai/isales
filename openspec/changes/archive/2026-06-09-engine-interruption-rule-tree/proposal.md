## Why

iSales 的 barge-in 决策（`evaluate_partial`）目前是**写死的三条件序列**：whitelist（精确匹配）→ min_text_length（prototype 硬编码 2）→ min_duration_ms。它等价于 voxen 可组合规则树中 `keyword(not) + length + time` 的一个**不可配置子集**——客户无法按场景自由组合「忽略哪些语气词、多长才算打断、要不要正则/分隔符触发、条件如何 AND/OR/NOT 嵌套」。voxen（`~/codes/voxen-main/core/interruption/`）已实证一棵从 JSON 递归构建的可组合规则树在生产可行，是本 change 的参照。

同时清两笔技术债：（1）已有 active change `interruption-detection-text-length-gate` 动的就是同一块 `evaluate_partial`，应被本 change 吸收而非平行推进；（2）`decider.py` 的「主裁判低置信 → restructure」内置兜底因 bare-token referee 硬编码 `confidence=1.0`（`referee.py`）已成**死分支**，恒不触发，应删除。

## What Changes

- **可组合打断规则树（核心）**：新建 engine 打断规则模块（port voxen `core/interruption/`）——`Rule` 协议 `should_interrupt(text) -> verdict`；叶子 `keyword`（**子串**匹配，区别于现 whitelist 的精确匹配）/ `length`（rune 数）/ `time_interval`（去抖）/ `regex` / `split_by_delimiter` / `none`；组合 `and` / `or` / `not`；factory 从 dict 递归构建。`evaluate_partial` 的写死序列**替换**为「跑这棵规则树」。喂入仍是 `_partial_monitor` 拿到的 ASR partial text；`_asr_pump → asr_partials_q → _partial_monitor` 链路不变。
- **规则树存 campaign JSONB（`interruption_rules`）**：`runtime_config` 装配进 `InterruptionConfig`。向后兼容：缺配置时**默认树 = `AND(NOT keyword[沿用现 whitelist], length≥2, duration≥min_duration_ms)`**，让现有 campaign 行为与当前完全一致（单棵默认树即现状，不叠加兜底分支）。
- **吸收 `interruption-detection-text-length-gate`**：min_text_length 并为 `length` 叶子规则；`_vad_monitor` 的 VAD-source `speaking_task.cancel()` + `source="vad"` transcript 写入删除，VAD 仅留 `vad_voice_active_ms` mirror 作 corroboration（防自环）。该 change 标 SUPERSEDED 并随本 change 一起 archive。
- **移除 `low_confidence` 死分支**：删 `decider.py` 的低置信内置兜底 + `streaming/types.py::FAILOPEN_LOW_CONFIDENCE` + `restructure_trigger` 的 `"low_confidence"` 取值 + `pipeline_trace` / `routing_rule.py` 文档注释里的 low_confidence 措辞。低置信场景退回普通 continue（功能上无变化——本就是死分支）。
- **重组流取材语义不变**（**非** breaking）：本 change 不动 restructure 的 `last_reply` / `interrupt_remaining` 取材，只删那条永不触发的 low_confidence 触发场景；`last_reply` 仍是「上一条 AI 原话作重说素材」。

## Capabilities

### New Capabilities
<!-- 规则树落在既有 interruption-detection capability 内，不新建 capability -->
无。

### Modified Capabilities

- `interruption-detection`: 把「双条件打断判定」（whitelist + duration）改为「**可组合规则树打断判定**」（叶子 keyword/length/time_interval/regex/split_by_delimiter/none + and/or/not，campaign JSONB 配置，缺省树等价现状）；吸收 text-length-gate 的「VAD-source cancel deprecate，VAD 仅作 corroboration mirror」要求；Configuration 段新增 `interruption_rules` 列。
- `ai-pipeline`: 「重组流三触发场景的 InterruptText 来源」由**三触发收缩为两触发**——删除 `low_confidence`（主裁判低置信兜底）触发场景及相关措辞；`last_reply` / `interrupt_remaining` 两个来源语义保留。
- `web-admin-ui`: 场景配置新增「打断规则」可组合编辑（and/or/not + 各叶子规则）。**实现分阶段**（engine + 默认树先上，web 编辑面后续 task section），但规则树 schema 与编辑契约在本 change 设计内定下。

## Impact

- **isales-common**：`schemas/jsonb/` 加递归规则树 Pydantic schema；alembic migration 加 `campaign.interruption_rules` JSONB 列 + data migration（给现有 campaign seed 等价默认树，从现 `interruption_whitelist` / `interruption_min_duration_ms` 推导）；`pipeline_trace.py` / `routing_rule.py` 注释去 low_confidence。**alembic revision id 不能撞现有 head**（手编滚动 id，commit 前跑 `alembic heads/history` 确认）。
- **isales-engine**：新增 interruption rule-tree 模块 + factory；`evaluate_partial` 改走规则树；`runtime_config` 读 `interruption_rules` 装配默认树；`run_loop._vad_monitor` 去 cancel 副作用（保留 mirror）；`decider.py` 删 low_confidence 分支；`streaming/types.py` 去 `FAILOPEN_LOW_CONFIDENCE`；单测。
- **isales-api**：`interruption_rules` 校验 endpoint（递归规则树合法性 + 类型/字段校验）。
- **isales-web**：场景配置「打断规则」编辑界面（分阶段）。
- **spec**：`interruption-detection`（MODIFIED）、`ai-pipeline`（MODIFIED）、`web-admin-ui`（MODIFIED）。
- **不受影响**：restructure 取材逻辑、scheduler / worker / telephony；`_asr_pump` / `asr_partials_q` / `_partial_monitor` 调用框架；call_record / 跨服务 message contract（schema-additive）。
