## MODIFIED Requirements

### Requirement: 路由规则引擎（decider）

engine SHALL 在所有 referee 返回后，按 campaign 配置的有序 `routing_rules` 列表逐条匹配，**第一个命中的规则即生效**（first-match-wins），执行其 action 后停止匹配。无任何规则命中时 SHALL 默认 `continue`（回 LISTENING）。每条规则绑定一个 referee（按 label）+ 匹配值集合 + 一个 action。action SHALL 是 `transition` / `restructure` / `hangup` 三者之一。

#### Scenario: 规则级联匹配，第一个命中即生效

- **WHEN** referee 结果为 `{judge_intent: "NEGATIVE", judge_reject: "OPERATOR"}` 且 routing_rules 顺序为 [规则A 绑 judge_reject 匹配 OPERATOR → transfer, 规则B 绑 judge_intent 匹配 NEGATIVE → restructure]
- **THEN** engine SHALL 执行规则A 的 transfer action 并停止匹配，MUST NOT 再执行规则B

#### Scenario: action 类型 — 状态转移

- **WHEN** 命中规则的 action 为 `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`
- **THEN** engine SHALL `sm.transition_to(WRAPPING_UP, reason="appointment")`，与现有 referee 驱动状态机逻辑一致
- **AND** action 为 `to: "transfer"` → `_perform_handoff(trigger_type="referee_decision")`；`to: "customer_decline"` → 现有 customer_decline 处置

#### Scenario: action 类型 — 切重组流

- **WHEN** 命中规则的 action 为 `{type: "restructure", source: "last_reply" | "interrupt_remaining"}`
- **THEN** engine SHALL 走重组流（见 § 重组流），按 source 构造 InterruptText

#### Scenario: action 类型 — 主动挂断

- **WHEN** 命中规则的 action 为 `{type: "hangup", closing_phrase: <str|null>}`
- **THEN** engine SHALL 返回 `DeciderAction(kind="hangup", closing_phrase=...)`，MUST NOT 再继续对话、MUST NOT spawn 后续 referee
- **AND** `closing_phrase` 非空时 engine SHALL 先经定值 TTS 播放该句（不新增对话轮）再驱动状态机进入 `END`；为空时 SHALL 立即进入 `END`
- **AND** 通话以 `hangup_cause = referee_hangup` 终结（见 call-state-machine § hangup_cause 单一来源）

#### Scenario: hangup 与 customer_decline 的区别

- **WHEN** 运营需要「再争取一轮」vs「当场结束」
- **THEN** `customer_decline` SHALL 表示软拒绝、AI 继续兜底挽留（不挂断）；`hangup` SHALL 表示硬终止、AI 结束并挂断（可选先告别）

#### Scenario: 无命中默认 continue

- **WHEN** 所有 routing_rules 均未命中（含全部 referee fail-open）
- **THEN** engine SHALL 默认回 LISTENING（continue），MUST NOT 误触发任何状态转移
