<!-- 叠在 pipeline-stream-and-referee 的 data-model delta 之上（role_config.kind={main,referee,extractor}）。
     本 delta 加 restructure 枚举值、role_config.label 列、referee 多行、campaign.routing_rules JSONB、
     pipeline_trace 多 referee + restructure 字段、call_record.prompt_versions referee_llms[]。 -->

## ADDED Requirements

### Requirement: role_config.kind 增加 restructure 且 referee 可多行

`role_config.kind` 枚举 SHALL 增加 `restructure`，完整集合为 `{main, referee, extractor, restructure}`。同一 campaign 下 `kind=referee` 的唯一性约束 MUST 放宽（允许 N 行）；`kind ∈ {main, extractor, restructure}` SHALL 各保持每 campaign ≤ 1 行。

#### Scenario: 一个 campaign 配多个 referee

- **WHEN** 为一个 campaign 创建 3 行 `kind=referee` role_config
- **THEN** 数据层 MUST 接受，MUST NOT 因唯一性约束拒绝

#### Scenario: restructure 单行约束

- **WHEN** 为一个 campaign 创建第 2 行 `kind=restructure`
- **THEN** 数据层 MUST 拒绝（每 campaign 至多一条重组流）

### Requirement: role_config.label 标识列

`role_config` SHALL 新增 `label`（字符串，≤ 64 字符，可空）列，用于被 routing_rules 稳定引用。同一 campaign 内 `kind=referee` 行的 `label` MUST 唯一且非空；`kind ∈ {main, extractor, restructure}` 的 label MAY 为空。label 跨 re-seed 稳定（不随 `role_config.id` 变化），routing_rules MUST 按 label 而非 id 引用 referee。

#### Scenario: referee label 唯一非空

- **WHEN** 同一 campaign 下两个 referee 用相同 label
- **THEN** 数据层 / api 层 MUST 拒绝

#### Scenario: 规则按 label 引用

- **WHEN** routing_rules 中一条规则 `referee="judge_reject"`
- **THEN** 该 label MUST 对应同 campaign 下某个 `kind=referee` 行；引用不存在的 label MUST 被 api 校验拒绝

### Requirement: campaign.routing_rules 路由规则 schema

`campaign` SHALL 新增 `routing_rules JSONB`（有序数组，默认空）。每个元素 SHALL 形如 `{referee: <label>, match: [<category>...], action: <action>}`。`action` SHALL 是以下之一：`{type: "transition", to: "goal_achieved"|"transfer"|"customer_decline", goal_type?: <str>}` 或 `{type: "restructure", source: "last_reply"|"interrupt_remaining"}`。数组顺序即匹配优先级（first-match-wins）。

#### Scenario: routing_rules 有序数组语义

- **WHEN** routing_rules 为一个 JSON 数组
- **THEN** 数组下标顺序 SHALL 定义规则匹配优先级，engine 按序匹配、第一个命中即生效

#### Scenario: transition action 携带 goal_type

- **WHEN** 一条规则 action 为 `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`
- **THEN** `to="goal_achieved"` 时 `goal_type` MUST 非空；其他 `to` 值时 `goal_type` SHALL 省略或为 null

#### Scenario: 规则引用合法性

- **WHEN** 校验一条 routing_rules
- **THEN** `referee` MUST 指向存在的 referee label；`action.to` MUST 是合法状态值；`action.source` MUST ∈ `{last_reply, interrupt_remaining}`

### Requirement: pipeline_trace 多 referee 与 restructure 字段

`pipeline_trace` SHALL 把单 referee 的 `referee_decision/referee_goal_type/referee_confidence/referee_duration_ms` 字段，改为承载 N 个 referee 结果的结构（JSONB 数组，每元素 `{label, category, confidence, duration_ms}`）。SHALL 新增 `matched_rule`（命中的规则快照或索引，可空）、`restructure_active`（bool）、`restructure_trigger`（`last_reply|interrupt_remaining|low_confidence|null`）、`restructure_source_text`（本轮 InterruptText，可空）。

#### Scenario: 多 referee 结果写入

- **WHEN** 一轮 PROCESSING 跑了 3 个 referee
- **THEN** pipeline_trace 该轮记录的 referee 结果 JSONB 数组 SHALL 含 3 个元素，各带 label/category/confidence/duration_ms

#### Scenario: restructure 轮的 trace

- **WHEN** 本轮命中 restructure action
- **THEN** pipeline_trace SHALL 置 `restructure_active=true`、记 `restructure_trigger` 与 `matched_rule`；referee 主回复字段按 restructure 语义留空或标记

### Requirement: call_record.prompt_versions 多 referee schema

`call_record.prompt_versions` JSONB 的 `referee_llm` 单值 SHALL 改为 `referee_llms[]`（数组，每元素含 label + model + prompt_version_id），并新增可空 `restructure_llm`（model + prompt_version_id）。`main_llm` / `extractor_llm` 不变。

#### Scenario: 通话快照记录所有 referee 版本

- **WHEN** 通话开始时快照 prompt_versions
- **THEN** `referee_llms` 数组 SHALL 含本通话每个 referee 的 label + model + prompt_version_id；配了重组流时 `restructure_llm` 非空
