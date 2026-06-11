## MODIFIED Requirements

### Requirement: routing_rules action 扩展：route / tool / then_state

`campaign.routing_rules` 的 `action` 联合 SHALL 新增两个成员，并保持 iSales 既有 `category in match[]` first-match-wins 语义不变：

- `RoutePersonaAction{type: "route", to: <persona-label | closing | recovery | restructure>, then_state?: ThenState, goal_type?: <str>}`
- `RouteToolAction{type: "tool", tool: <alias>, then_state?: ThenState, closing_phrase?: str}`

`RoutePersonaAction.goal_type` 为可选标签，**仅当 `to == "closing"` 时有效**（goal-achieved 软结局收尾路由）；`to` 为 persona label 或其他内置路由（recovery/restructure）时 `goal_type` MUST 省略或为 null，否则保存 SHALL 拒绝。它是 legacy `TransitionAction.goal_type`（`transition to=goal_achieved`）的 modern 对等物：engine decider 从命中规则 action 提取 `goal_type` 并透传，使 `goal_achieved` 事件 + `call_summary.goal_type` 记录该标签——`route` 与 `transition` 两种形态的提取 MUST 对称（不得只对 `transition` 提取而在 `route` 丢弃）。

`RouteToolAction.closing_phrase` 为可选**单句**，仅对 `tool: hangup` 有意义：命中规则携带它时 SHALL **覆盖** `HangupToolConfig.closing_phrase`，使多条不同关键字（referee category）的规则复用**同一个** hangup 工具、各带不同结束语；省略时回落到工具配置的 `closing_phrase`，**两者皆空 / 缺省时直接挂断、不播话术**。

`ThenState` SHALL 为 Literal `{LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}`。legacy `{type: transition}` / `{type: restructure}` 成员 SHALL 经 **removal-tracked shim** 保留（removal trigger = 后续全量迁移后的清理 change），MUST NOT 在本 change 删除以免破坏存量。

#### Scenario: route 动作引用 persona / 内置对话路由

- **WHEN** 路由规则 action 为 `{type: route, to: "<persona-label>", then_state: "LISTENING"}`
- **THEN** 系统 MUST 校验 `to` 指向同 campaign 已定义的 persona label 或内置 `closing/recovery/restructure`；未定义的 persona label MUST 在保存时以 `422 routing_rule_unknown_persona` 拒绝；engine 选中后按 `then_state` 投影（见 ai-pipeline / call-state-machine spec）

#### Scenario: route:closing 动作携带 goal_type

- **WHEN** 路由规则 action 为 `{type: route, to: "closing", then_state: "WRAPPING_UP", goal_type: "intent_confirmed"}`
- **THEN** schema MUST 校验通过（`goal_type` 仅 `to="closing"` 时合法）；engine decider MUST 从该 action 提取 `goal_type` 并使最终 `goal_achieved` 事件携带 `goal_type="intent_confirmed"`，与 legacy `transition to=goal_achieved` 形态结果一致
- **AND** 同一 action 若 `to` 非 `"closing"` 而携带 `goal_type`，保存 MUST 被拒绝（schema validation error）

#### Scenario: tool 动作引用工具 alias

- **WHEN** 路由规则 action 为 `{type: tool, tool: "hangup", then_state: "END"}`
- **THEN** 系统 MUST 校验 `tool` 指向 campaign `tools` 已定义 alias；未定义 MUST 在保存时拒绝（api `422 routing_rule_unknown_tool`）

#### Scenario: 同一 hangup 工具按关键字携带不同结束语

- **WHEN** 同一 referee 下两条规则分别为 `{match: ["OFFENSIVE"], action: {type: "tool", tool: "hangup", closing_phrase: "不打扰了，再见"}}` 与 `{match: ["HANGUP"], action: {type: "tool", tool: "hangup", closing_phrase: "那再见"}}`
- **THEN** 两条规则 MUST 校验通过、复用同一个 hangup 工具 alias；engine 选中时 SHALL 取**命中规则**的 `closing_phrase`（覆盖工具配置）；`closing_phrase` 若提供 MUST 为单句字符串，省略或空串表示直接挂断
