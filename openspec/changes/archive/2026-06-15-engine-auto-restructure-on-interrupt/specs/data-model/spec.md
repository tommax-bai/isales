## ADDED Requirements

### Requirement: campaign.auto_restructure_on_interrupt 被打断自动重组开关

`campaign` 表 SHALL 持有 `auto_restructure_on_interrupt` 列（`Boolean`，NOT NULL，`server_default=sa.false()` / Python 默认 `False`）。该列为布尔开关：ON 时引擎在门控 decider 缺省（无显式 routing rule 命中）、本轮存在 barge-in 残留（`session.interrupt_remaining_text` 非空）且配置了 `kind=restructure` role_config 时，把缺省出口由 continue 改判为 `restructure(source=interrupt_remaining)`（语义见 ai-pipeline § 被打断自动重组开关）。默认 `False` → 行为与引入前一致；该列与既有 `routing_rules` / `max_continuous_restructure` / `interruption_*` 列同属 campaign 的打断与重组配置面。

#### Scenario: 新列加性迁移回填默认值

- **WHEN** isales-common Alembic 迁移在已有数据的 `campaign` 表上新增 `auto_restructure_on_interrupt` 列（down_revision 接当前 head `f7a8b9c0d1e2`）
- **THEN** 迁移 MUST 以 `server_default=sa.false()` 回填所有存量行，列 NOT NULL 不产生 NULL 窗口
- **AND** 存量 campaign 默认关闭，被打断后的决策行为 MUST 与迁移前逐字节一致

#### Scenario: schema 暴露与 PATCH 写入

- **WHEN** 客户端通过 campaign API 读取或 PATCH `auto_restructure_on_interrupt`
- **THEN** `CampaignBase` / `CampaignRead` MUST 含该字段（`bool`，默认 `False`），`CampaignUpdate` MUST 以可选字段（`bool | None`）支持部分更新；isales-api MUST NOT 在字段白名单层（`CampaignNestedUpdate`）静默丢弃该字段

## MODIFIED Requirements

### Requirement: routing_rules action 扩展：route / tool / then_state

`campaign.routing_rules` 的 `action` 联合 SHALL 含以下成员，并保持 iSales 既有 `category in match[]` first-match-wins 语义不变：

- `RoutePersonaAction{type: "route", to: <persona-label | closing | recovery>, then_state?: ThenState}`
- `RouteToolAction{type: "tool", tool: <alias>, then_state?: ThenState, closing_phrase?: str}`

`RouteToolAction.closing_phrase` 为可选**单句**，仅对 `tool: hangup` 有意义：命中规则携带它时 SHALL **覆盖** `HangupToolConfig.closing_phrase`，使多条不同关键字（referee category）的规则复用**同一个** hangup 工具、各带不同结束语；省略时回落到工具配置的 `closing_phrase`，**两者皆空 / 缺省时直接挂断、不播话术**。

`ThenState` SHALL 为 Literal `{LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}`。legacy `{type: transition}` 成员 SHALL 经 **removal-tracked shim** 保留（removal trigger = 后续全量迁移后的清理 change）。**legacy `{type: restructure}` action 已删除**（engine-auto-restructure-on-interrupt）：restructure 不再是 routing action，也不再是 route 目标（`to=restructure` 经 api `422 routing_rule_unknown_persona` 拒绝）；restructure 只由 `campaign.auto_restructure_on_interrupt` 开关触发（见 ai-pipeline § 被打断自动重组开关）。生产 0 campaign 使用 restructure action，删除无数据影响。

#### Scenario: route 动作引用 persona / 内置对话路由

- **WHEN** 路由规则 action 为 `{type: route, to: "<persona-label>", then_state: "LISTENING"}`
- **THEN** 系统 MUST 校验 `to` 指向同 campaign 已定义的 persona label 或内置 `closing/recovery`；未定义的 persona label 或 `restructure` MUST 在保存时以 `422 routing_rule_unknown_persona` 拒绝；engine 选中后按 `then_state` 投影（见 ai-pipeline / call-state-machine spec）

#### Scenario: tool 动作引用工具 alias

- **WHEN** 路由规则 action 为 `{type: tool, tool: "hangup", then_state: "END"}`
- **THEN** 系统 MUST 校验 `tool` 指向 campaign `tools` 已定义 alias；未定义 MUST 在保存时拒绝（api `422 routing_rule_unknown_tool`）

#### Scenario: 同一 hangup 工具按关键字携带不同结束语

- **WHEN** 同一 referee 下两条规则分别为 `{match: ["OFFENSIVE"], action: {type: "tool", tool: "hangup", closing_phrase: "不打扰了，再见"}}` 与 `{match: ["HANGUP"], action: {type: "tool", tool: "hangup", closing_phrase: "那再见"}}`
- **THEN** 两条规则 MUST 校验通过、复用同一个 hangup 工具 alias；engine 选中时 SHALL 取**命中规则**的 `closing_phrase`（覆盖工具配置）；`closing_phrase` 若提供 MUST 为单句字符串，省略或空串表示直接挂断

#### Scenario: legacy transition action 经 shim 向后兼容

- **WHEN** 存量 campaign 的规则仍为 `{type: transition, ...}`
- **THEN** 系统 MUST 经 shim 原样接受并按既有语义执行；决策结果 MUST NOT 因本 change 改变

#### Scenario: restructure action 不再合法

- **WHEN** 提交一条 action 为 `{type: "restructure", ...}` 或 `{type: "route", to: "restructure"}` 的 routing rule
- **THEN** api 校验 MUST 拒绝（schema 层无 `RestructureAction`；`to=restructure` 经 route 层 `422 routing_rule_unknown_persona`）
