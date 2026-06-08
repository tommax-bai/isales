## MODIFIED Requirements

### Requirement: campaign.routing_rules 路由规则 schema

`campaign` SHALL 新增 `routing_rules JSONB`（有序数组，默认空）。每个元素 SHALL 形如 `{referee: <label>, match: [<category>...], action: <action>}`。`action` SHALL 是以下之一：`{type: "transition", to: "goal_achieved"|"transfer"|"customer_decline", goal_type?: <str>}` 或 `{type: "restructure", source: "last_reply"|"interrupt_remaining"}` 或 `{type: "hangup", closing_phrase?: <str>}`。数组顺序即匹配优先级（first-match-wins）。`action` SHALL 是按 `type` 区分的 discriminated union。

#### Scenario: routing_rules 有序数组语义

- **WHEN** routing_rules 为一个 JSON 数组
- **THEN** 数组下标顺序 SHALL 定义规则匹配优先级，engine 按序匹配、第一个命中即生效

#### Scenario: transition action 携带 goal_type

- **WHEN** 一条规则 action 为 `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`
- **THEN** `to="goal_achieved"` 时 `goal_type` MUST 非空；其他 `to` 值时 `goal_type` SHALL 省略或为 null

#### Scenario: hangup action 形状与可选话术

- **WHEN** 一条规则 action 为 `{type: "hangup", closing_phrase: "感谢您的时间，再见"}` 或 `{type: "hangup"}`（话术省略）
- **THEN** `closing_phrase` SHALL 可选（字符串或省略/null）；非空时长度 MUST ≤ 512 字符（与 `silence_hangup_phrase` 对齐）
- **AND** `hangup` action MUST NOT 携带 `to` / `goal_type` / `source` 字段

#### Scenario: 规则引用合法性

- **WHEN** 校验一条 routing_rules
- **THEN** `referee` MUST 指向存在的 referee label；`action.to` MUST 是合法状态值；`action.source` MUST ∈ `{last_reply, interrupt_remaining}`；`action.type` MUST ∈ `{transition, restructure, hangup}`

### Requirement: hangup_cause 枚举新增 referee_hangup

`HangupCause` 枚举 SHALL 新增应用层值 `REFEREE_HANGUP = "referee_hangup"`，表示 engine 依裁判路由判定的本端主动挂断。该值 MUST 与 call-state-machine § hangup_cause 单一来源的枚举清单保持一致，并由 retry-followup 归类为不自动重拨。

#### Scenario: 引擎落 referee_hangup

- **WHEN** decider 命中 hangup action 并完成挂断
- **THEN** `call_record.hangup_cause` SHALL 记为 `referee_hangup`，且该字符串 MUST 是 `HangupCause` 枚举成员（非平行词汇表）

#### Scenario: pipeline_trace 复用 matched_rule 记录挂断

- **WHEN** 本轮命中 hangup action
- **THEN** pipeline_trace SHALL 通过既有 `matched_rule` 字段记录命中的 hangup 规则快照；MUST NOT 为 hangup 新增专用列
