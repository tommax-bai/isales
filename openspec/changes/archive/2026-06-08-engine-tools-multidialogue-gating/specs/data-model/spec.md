## ADDED Requirements

### Requirement: RoleKind.PERSONA 与 persona 角色配置

`isales_common.enums.RoleKind` SHALL 新增成员 `PERSONA`，`PromptScopeType` SHALL 新增对应 `PERSONA`。`kind=persona` 的 `role_config` 表示一个**可推测并行**的对话人设，其 `label` MUST 非空且在同一 campaign 内唯一（与 referee label 命名空间隔离，互不冲突）。persona 复用 main 对话的 model / prompt 结构，参与 eager 多人设门控（见 ai-pipeline spec）。

#### Scenario: persona role_config 落库

- **WHEN** 管理员为 campaign 添加一个 `kind=persona` 角色并填 label
- **THEN** 系统 MUST 以 `RoleKind.PERSONA` 持久化该 role_config，label 非空唯一；MUST NOT 允许空 label 或与同 campaign 内既有 persona label 重复

#### Scenario: persona label 与 referee label 命名空间隔离

- **WHEN** 同一 campaign 同时存在 `kind=referee` 与 `kind=persona` 且 label 文本相同
- **THEN** 系统 MUST 视为两个独立标识（按 kind + label 寻址），MUST NOT 因 label 文本相同而冲突或互相覆盖

### Requirement: HangupCause.REFEREE_HANGUP 枚举值

`isales_common.enums.HangupCause` SHALL 新增**应用层**值 `REFEREE_HANGUP`，表示「AI 依门控裁决主动挂断」的终态。该值 MUST 登记进 `HangupCause` 单一权威枚举（见 call-state-machine § "hangup_cause 单一来源"），下游 `CallEnded` 消息按枚举校验消费方（worker）MUST 先于 engine 部署该枚举（部署序 common → worker → engine）。

#### Scenario: REFEREE_HANGUP 登记进权威枚举

- **WHEN** engine / worker / retry-followup 记录或匹配该挂断原因
- **THEN** 字符串值 MUST 为 `HangupCause.REFEREE_HANGUP` 成员；MUST NOT 在任何映射表引入未登记的平行值

#### Scenario: CallEnded 枚举校验依赖部署序

- **WHEN** engine 发出 `CallEnded(hangup_cause=referee_hangup)`
- **THEN** 消费方 worker MUST 已持有 `REFEREE_HANGUP` 枚举（pin `isales-common>=0.8`）才能通过校验；若 worker 早于 common/engine 升级 MUST NOT 让该 CallEnded 进 DLQ

### Requirement: campaign.tools 工具配置 schema

`campaign` SHALL 新增 `tools` JSONB 列，持有工具 alias → 工具配置的映射。工具配置 SHALL 为 `HangupToolConfig` / `TransferToolConfig` 的判别联合（`schemas/jsonb/tool_config.py` 新增）：

- `HangupToolConfig{type: "hangup", closing_phrase?: str, interrupt?: bool}`
- `TransferToolConfig{type: "transfer"}`（**不携带话术字段**——转人工复用既有 `_perform_handoff` + 单一来源 `campaign.transfer_phrases`，MUST NOT 引入第二套衔接话术配置；见 ai-pipeline § "挂断 / 转人工 lazy tool route"）

工具由路由规则的 `{type: tool, tool: <alias>}` 动作引用（见 § "routing_rules action 扩展"）。

#### Scenario: tools JSONB 存取

- **WHEN** 创建 / 更新 campaign 时提供 `tools` 映射
- **THEN** 系统 MUST 按判别联合校验每个工具配置（`type ∈ {hangup, transfer}`）并原样持久化；读取时原样返回供 engine 与 api 校验消费

#### Scenario: 未配置 tools 向后兼容

- **WHEN** 存量 campaign 无 `tools` 列值（NULL / 空对象）
- **THEN** 系统 MUST 视为无工具，路由规则 MUST NOT 引用任何 tool alias；行为与现行一致

### Requirement: routing_rules action 扩展：route / tool / then_state

`campaign.routing_rules` 的 `action` 联合 SHALL 新增两个成员，并保持 iSales 既有 `category in match[]` first-match-wins 语义不变：

- `RoutePersonaAction{type: "route", to: <persona-label | closing | recovery | restructure>, then_state?: ThenState}`
- `RouteToolAction{type: "tool", tool: <alias>, then_state?: ThenState, closing_phrase?: str}`

`RouteToolAction.closing_phrase` 为可选**单句**，仅对 `tool: hangup` 有意义：命中规则携带它时 SHALL **覆盖** `HangupToolConfig.closing_phrase`，使多条不同关键字（referee category）的规则复用**同一个** hangup 工具、各带不同结束语；省略时回落到工具配置的 `closing_phrase`，**两者皆空 / 缺省时直接挂断、不播话术**。

`ThenState` SHALL 为 Literal `{LISTENING, WRAPPING_UP, ACTIVATING, TRANSFERRING, END}`。legacy `{type: transition}` / `{type: restructure}` 成员 SHALL 经 **removal-tracked shim** 保留（removal trigger = 后续全量迁移后的清理 change），MUST NOT 在本 change 删除以免破坏存量。

#### Scenario: route 动作引用 persona / 内置对话路由

- **WHEN** 路由规则 action 为 `{type: route, to: "<persona-label>", then_state: "LISTENING"}`
- **THEN** 系统 MUST 校验 `to` 指向同 campaign 已定义的 persona label 或内置 `closing/recovery/restructure`；未定义的 persona label MUST 在保存时以 `422 routing_rule_unknown_persona` 拒绝；engine 选中后按 `then_state` 投影（见 ai-pipeline / call-state-machine spec）

#### Scenario: tool 动作引用工具 alias

- **WHEN** 路由规则 action 为 `{type: tool, tool: "hangup", then_state: "END"}`
- **THEN** 系统 MUST 校验 `tool` 指向 campaign `tools` 已定义 alias；未定义 MUST 在保存时拒绝（api `422 routing_rule_unknown_tool`）

#### Scenario: 同一 hangup 工具按关键字携带不同结束语

- **WHEN** 同一 referee 下两条规则分别为 `{match: ["OFFENSIVE"], action: {type: "tool", tool: "hangup", closing_phrase: "不打扰了，再见"}}` 与 `{match: ["HANGUP"], action: {type: "tool", tool: "hangup", closing_phrase: "那再见"}}`
- **THEN** 两条规则 MUST 校验通过、复用同一个 hangup 工具 alias；engine 选中时 SHALL 取**命中规则**的 `closing_phrase`（覆盖工具配置）；`closing_phrase` 若提供 MUST 为单句字符串，省略或空串表示直接挂断

#### Scenario: legacy action 经 shim 向后兼容

- **WHEN** 存量 campaign 的规则仍为 `{type: transition, ...}` / `{type: restructure, ...}`
- **THEN** 系统 MUST 经 shim 原样接受并按既有语义执行；决策结果 MUST NOT 因本 change 改变

### Requirement: campaign 门控与多人设配置列

`campaign` SHALL 新增三列控制门控与推测并行：

- `persona_fanout_cap` (int, 默认 1, clamp ∈ [1,3])：**每轮并行推测的对话路由总数（含 main）**；`1` = 仅 main、无推测（opt-in 默认关）；`3` = main + 至多 2 个 persona
- `referee_timeout_ms` (int, 默认 ~600)：开口前门控 referee 超时
- `referee_fail_open_route` (str, 默认 `"main"`)：门控 fail-open 的目标路由

#### Scenario: 门控配置被引擎消费

- **WHEN** engine 起一轮门控
- **THEN** engine MUST 用 `campaign.referee_timeout_ms` 作为门控超时、`referee_fail_open_route` 作为 fail-open 目标、`persona_fanout_cap`（clamp [1,3]）作为本轮并行推测对话路由总数（含 main）的上限

#### Scenario: 列默认值向后兼容

- **WHEN** 存量 campaign 无这三列值
- **THEN** 系统 MUST 用默认（`persona_fanout_cap=1` 仅 main 无推测 / `referee_timeout_ms≈600` / `referee_fail_open_route="main"`）；行为等价于仅 main 对话 + fail-open-to-main

### Requirement: pipeline_trace 路由与人设字段

`pipeline_trace` SHALL 新增字段记录门控选路：`selected_route_id` (str)、`selected_route_kind` (str ∈ {dialogue, tool})、`persona_candidates` (JSONB array，本轮推测的候选 label 集)。既有 referee / restructure 字段 MUST 不变。

#### Scenario: 门控选路写入 trace

- **WHEN** 某轮门控裁决放行一条 route
- **THEN** pipeline_trace MUST 记 `selected_route_id`（如 `main` / `persona:<label>` / `tool:hangup`）+ `selected_route_kind` + `persona_candidates`；MUST NOT 改动既有 referee_* / restructure_* 字段语义

### Requirement: dial 消息 persona_llms[]

`schemas/messages/dial.py` 的 DialRequest SHALL 新增 `persona_llms[]` 字段，承载 scheduler 快照的 `kind=persona` 角色 prompt 版本（结构镜像既有 `referee_llms[]`，含 label + model + prompt_version_id）。engine MUST 从该字段读人设配置，MUST NOT 直接查 DB。

#### Scenario: scheduler 打包 persona prompt 版本

- **WHEN** scheduler 派发配置了 persona 的 campaign 通话
- **THEN** dial 消息 `persona_llms[]` MUST 含每个 enabled persona 的 label + model + prompt_version_id；engine 直接消费

### Requirement: isales-common 0.8.0 加性迁移

本 change 的全部 schema 变更（PERSONA / REFEREE_HANGUP / tools / route&tool action / 门控列 / pipeline_trace 字段 / persona_llms）SHALL 由**一条加性 alembic 迁移**承载（down_rev `a7b8c9d0e1f2`），isales-common 版本 SHALL 由 0.7.0 升至 **0.8.0**。下游 api / scheduler / worker pin SHALL 同步到 `>=0.8,<0.9`。`CallStatus` 枚举 SHALL 由 11 值**收缩为 4 值** `{init, in_call, transferring, end}`（见 call-state-machine spec § 状态集合——原 8 个细粒度阶段降级为引擎内部概念）；`call_record.status` 为 `String(16)` 列（非 PG enum），收缩**无需 DB 迁移**（与上述加性迁移正交），收缩前历史行旧值为可接受孤儿（v1 无生产数据）。

#### Scenario: 加性迁移可回滚

- **WHEN** 部署 0.8.0 迁移后需回滚
- **THEN** 迁移 MUST 为纯加性（新增列 / 新增枚举值），回滚 SHALL 不依赖 down-migration（存量行新列取默认）；MUST NOT 删除或改名既有列

#### Scenario: 下游 pin 同步

- **WHEN** isales-common 升 0.8.0
- **THEN** api / scheduler / worker 的 `isales-common` pin MUST 升到 `>=0.8,<0.9`；worker 现有 stale pin `>=0.5,<0.6` MUST 一并修正（否则 REFEREE_HANGUP 枚举不可用、CallEnded 进 DLQ）
