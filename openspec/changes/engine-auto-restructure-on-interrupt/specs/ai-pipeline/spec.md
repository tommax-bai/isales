## ADDED Requirements

### Requirement: 被打断自动重组开关 auto_restructure_on_interrupt

campaign SHALL 持有布尔开关 `auto_restructure_on_interrupt`（默认 `false`）。该开关 ON 时，engine SHALL 在门控 decider 对本轮**未命中任何显式 routing rule**（即 `decide()` 缺省落到 `continue` / fail-open）且同时满足下列全部条件时，把该缺省出口**改判为 `restructure(source=interrupt_remaining)`** 而非 continue：

1. `campaign.auto_restructure_on_interrupt` 为 ON；
2. campaign 配置了 `kind=restructure` 的 role_config（restructure slot 存在）；
3. 本轮 `session.interrupt_remaining_text` 非空（= 上一轮 main 被 barge-in 打断、引擎已捕获残留未送 TTS 文本）。

该改判 MUST 在 gate-first 门控**之后、`_select_gated_route` 之前**于 `decide()` 调用点完成；`decide()` SHALL 保持纯函数（MUST NOT 在 `decide()` 内读 session / 开关 / 合成假规则）。referee 仍按 gate-first 在前运行——任一显式 routing rule 命中（first-match-wins，如 `judge_reject=OPERATOR → tool:transfer`、`judge_intent=NEGATIVE → recovery`）SHALL 优先生效并**否决**本自动重组（即开关只在"无显式规则命中"的缺省位接管，referee + 显式规则是其 veto）。

未配置 restructure slot 时开关 SHALL 无效（缺省仍走 continue），MUST NOT 报错。自动改判产生的 restructure 仍 SHALL 受 `max_continuous_restructure` 连续封顶约束（见 § 重组流连续触发封顶），与显式 restructure 走同一封顶逻辑。`auto_restructure_on_interrupt` 为 OFF（默认）时，decider 缺省行为 MUST 与本开关引入前逐字节一致。自动改判与显式规则触发的 restructure 在 trace 上 SHALL 复用同一 `restructure_trigger="interrupt_remaining"`，MUST NOT 引入新 trigger 枚举值；二者由 `matched_rule is None` 区分。

#### Scenario: 开关开启 + 被打断 + 无显式规则命中 → 自动重组

- **WHEN** `auto_restructure_on_interrupt` 为 ON、campaign 有 restructure slot、上一轮 main 被 barge-in 打断使 `session.interrupt_remaining_text` 非空，且本轮所有 referee 结果均未命中任何显式 routing rule（decider 本应缺省 continue）
- **THEN** engine SHALL 在 `decide()` 调用点把出口改判为 `DeciderAction(kind="restructure", source="interrupt_remaining")`，走 restructure route（then_state=LISTENING，referee-skipped），按 `interrupt_remaining` 取 `session.interrupt_remaining_text` 构造 InterruptText（取用后清空）

#### Scenario: 显式 routing rule 命中否决自动重组

- **WHEN** `auto_restructure_on_interrupt` 为 ON 且 `interrupt_remaining_text` 非空，但某 referee 命中了显式 routing rule（如 `judge_intent=NEGATIVE → recovery` 或 `judge_reject=OPERATOR → tool:transfer`）
- **THEN** engine SHALL 按 first-match-wins 选中该显式规则的 route，MUST NOT 因开关改判为 restructure（显式规则 = veto，referee 仍是判官）

#### Scenario: 未配 restructure slot 时开关无效

- **WHEN** `auto_restructure_on_interrupt` 为 ON 但 campaign 无 `kind=restructure` role_config
- **THEN** decider 缺省 SHALL 仍走 continue（回 LISTENING），MUST NOT 报错，MUST NOT 产生 restructure route

#### Scenario: 无 barge-in 残留时开关不接管

- **WHEN** `auto_restructure_on_interrupt` 为 ON 但本轮 `session.interrupt_remaining_text` 为空（本轮未发生 barge-in，或残留已被取用清空）
- **THEN** decider 无命中时 SHALL 走 fail-open continue（回 LISTENING），MUST NOT 自动改判 restructure

#### Scenario: 开关关闭时行为不变

- **WHEN** `auto_restructure_on_interrupt` 为 OFF（默认）
- **THEN** 无论 `interrupt_remaining_text` 是否非空，decider 无命中时 SHALL 走 fail-open continue（回 LISTENING），与本开关引入前逐字节一致

#### Scenario: 自动重组仍受连续封顶约束

- **WHEN** 开关开启致连续多轮自动 restructure，连续次数达到 `max_continuous_restructure`
- **THEN** engine SHALL 停止 restructure，改播 campaign default_replies 或按既有连续打断策略处置（与显式 restructure 走同一封顶逻辑）；连续计数在正常 main 回复后 SHALL 清零

## MODIFIED Requirements

### Requirement: 路由规则引擎（decider）

engine SHALL 在门控 referee 返回后，按 campaign 配置的有序 `routing_rules` 列表逐条匹配，**第一个命中的规则即生效**（first-match-wins），把命中规则的 action 映射为**一条 route**（由 `SelectRouter` 放行），然后停止匹配。无任何规则命中时 SHALL 默认放行 `referee_fail_open_route`（默认 main，即 continue/回 LISTENING）——**例外**：当 `campaign.auto_restructure_on_interrupt` 开启、配置了 restructure slot 且本轮 `session.interrupt_remaining_text` 非空时，该"无命中缺省出口" SHALL 改判为 `restructure(source=interrupt_remaining)`（见 Requirement: 被打断自动重组开关）；该改判 MUST 在 `decide()` 调用点（gate 之后、`_select_gated_route` 之前）完成，`decide()` SHALL 保持纯函数（MUST NOT 在 `decide()` 内读 session / 开关）。每条规则绑定一个 referee（按 label）+ 匹配值集合 + 一个 action。`decide()` 复用 verbatim；engine MUST NOT 让 route / decider 直接调用 `transition_to` 写状态——状态一律经被选 route 的 `then_state` 由 StatusProjector 投影（见 call-state-machine spec）。

#### Scenario: 规则级联匹配，第一个命中即生效

- **WHEN** referee 结果为 `{judge_intent: "NEGATIVE", judge_reject: "OPERATOR"}` 且 routing_rules 顺序为 [规则A 绑 judge_reject 匹配 OPERATOR → tool:transfer, 规则B 绑 judge_intent 匹配 NEGATIVE → restructure]
- **THEN** engine SHALL 选中规则A 映射的 `tool:transfer` route 并停止匹配，MUST NOT 再执行规则B

#### Scenario: action 类型 — route / tool（新）

- **WHEN** 命中规则的 action 为 `{type: route, to: <persona|closing|recovery|restructure>, then_state?}` 或 `{type: tool, tool: <alias>, then_state?}`
- **THEN** engine SHALL 经 selector 映射到对应 route（dialogue route 放行 eager 缓冲的生成；tool route lazy `execute()`），被选 route 的 `then_state` 由 StatusProjector 投影；MUST NOT 在 decider/route 内直接 `sm.transition_to`

#### Scenario: action 类型 — legacy transition（shim → route + then_state）

- **WHEN** 命中规则的 action 为 legacy `{type: "transition", to: "goal_achieved", goal_type: "appointment"}`（或 `to: "transfer"` / `to: "customer_decline"`）
- **THEN** engine SHALL 经 removal-tracked shim 把它映射为等价 route + then_state：`goal_achieved` → `closing` route（then_state=WRAPPING_UP，`goal_type` 仍取自 action 携带）；`transfer` → `tool:transfer`（then_state=TRANSFERRING，复用 `_perform_handoff`）；`customer_decline` → `recovery` route（then_state=ACTIVATING）；状态一律由 StatusProjector 投影，MUST NOT 直接 `sm.transition_to`，决策结果 MUST NOT 因本映射改变

#### Scenario: action 类型 — 切重组流

- **WHEN** 命中规则的 action 为 `{type: "restructure", source: "last_reply" | "interrupt_remaining"}`（或 route to=restructure）
- **THEN** engine SHALL 走 restructure route（then_state=LISTENING，referee-skipped），按 source 构造 InterruptText（见 § 重组流）

#### Scenario: 无命中默认放行 fail-open 路由

- **WHEN** 所有 routing_rules 均未命中（含全部 referee fail-open），且 `auto_restructure_on_interrupt` 为 OFF（或无 restructure slot / `interrupt_remaining_text` 为空）
- **THEN** engine SHALL 放行 `referee_fail_open_route`（默认 main → continue/回 LISTENING），MUST NOT 误触发任何状态转移

#### Scenario: 无命中 + 开关开启 + 被打断 → 缺省改判 restructure

- **WHEN** 所有 routing_rules 均未命中，但 `auto_restructure_on_interrupt` 为 ON、配置了 restructure slot 且本轮 `session.interrupt_remaining_text` 非空
- **THEN** engine SHALL 在 `decide()` 调用点把缺省出口由 continue 改判为 `restructure(source=interrupt_remaining)`（详见 Requirement: 被打断自动重组开关），MUST NOT 误触发任何状态转移

### Requirement: 重组流触发场景的 InterruptText 来源

engine SHALL 按命中规则的 `source` 字段构造 restructure 的 InterruptText，对应两个产品场景：

- `source="last_reply"`（用户没接住）→ InterruptText = 上一轮 AI 回复（dialog_history 最后一条 assistant utterance）；
- `source="interrupt_remaining"`（barge-in 重说）→ InterruptText = 被打断时 main 残留未送 TTS 的句子文本。

`restructure_trigger` 取值集 SHALL 仅含上述两类来源对应的标记，MUST NOT 含 `low_confidence`——原"主裁判低置信兜底 → restructure" 内置分支已删除（该分支因 referee 输出契约把 bare-token referee 的 `confidence` 固定为 1.0 而恒不触发，是死代码；见 change `engine-interruption-rule-tree`）。无任何 routing rule 命中时 engine SHALL 走 fail-open continue（回 LISTENING）——**除非** `campaign.auto_restructure_on_interrupt` 开启、配置了 restructure slot 且本轮 `interrupt_remaining_text` 非空（见 Requirement: 被打断自动重组开关），此时缺省出口为 `restructure(source=interrupt_remaining)`、`restructure_trigger="interrupt_remaining"`。无论开关开关与否，engine MUST NOT 因 referee confidence / 低置信走任何内置 restructure 兜底，MUST NOT 产生 `restructure_trigger="low_confidence"` 的 trace。

#### Scenario: 用户没接住 → 复述上一句

- **WHEN** 某 referee 判用户输入无意义（如返回 NEGATIVE）且规则 action 为 `restructure source=last_reply`
- **THEN** engine SHALL 取 dialog_history 末条 assistant utterance 作为 InterruptText，口语化重说

#### Scenario: barge-in 残留捕获后重说

- **WHEN** 上一轮用户 barge-in 打断 main，engine 捕获了 `interrupt_remaining_text`，本轮规则 action 为 `restructure source=interrupt_remaining`（或经 `auto_restructure_on_interrupt` 缺省改判）
- **THEN** engine SHALL 取 `interrupt_remaining_text` 作为 InterruptText 重组成顺畅一句补上；取用后 MUST 清空该字段
- **AND** 若 `interrupt_remaining_text` 为空，restructure SHALL 退化为复述 last_reply

#### Scenario: 主裁判低置信不再触发 restructure

- **WHEN** 所有 routing_rules 均未命中（含主裁判返回的 category 未匹配任何规则），且 `auto_restructure_on_interrupt` 为 OFF（或无 restructure slot / `interrupt_remaining_text` 为空）
- **THEN** engine SHALL 走 fail-open continue（回 LISTENING），MUST NOT 因 referee confidence 走任何内置 restructure 兜底；MUST NOT 产生 `restructure_trigger="low_confidence"` 的 trace
