## Purpose

汇总 iSales 系统的核心数据表与字段，明确每张表的归属服务。本规范是数据模型的"目录视图"——具体字段含义、约束、状态机 SHALL 在各功能 capability spec 中定义；本 spec 仅承担"全表清单 + 跨服务一致性"职责。
## Requirements
### Requirement: 数据模型由 isales-common 统一管理

所有 SQLAlchemy 模型与 Alembic 迁移 SHALL 由 isales-common 管理；其他服务通过依赖 isales-common 间接访问。

#### Scenario: 模型新增 / 修改

- **WHEN** 任何服务需要新表或新字段
- **THEN** SHALL 在 isales-common 写模型并生成 alembic 迁移；其他服务 MUST NOT 自己写模型或直接 DDL

#### Scenario: 迁移单一来源

- **WHEN** 部署
- **THEN** alembic 迁移 SHALL 仅由 isales-common 管理；其他服务 MUST NOT 引入独立迁移工具

### Requirement: 表归属与全表清单

每张表 SHALL 标记其主要业务归属——归属决定 schema 演进与 PR 主导权，多个服务可读写但归属仅一个；具体读写权由 `service-communication` spec 的"数据库直连"与"跨服务读 vs 写"两条 Requirement 约束。当某张关联表的 lifecycle 跟随归属 A 而非归属 B（例如 `campaign_device` 跟随 campaign 的启停而非 device 的插拔），归属 SHALL 设为 A。

#### Scenario: 表清单完整性

- **WHEN** 清点系统所有持久化表
- **THEN** 表集合 MUST 包含且仅包含以下：

| 表 | 关键字段 | 归属服务 | 详细规范 |
|---|---|---|---|
| `campaign` | name, voice_id, default_replies(JSONB), concurrency, time_windows(JSONB), extraction_fields(JSONB), max_silence_activations, silence_threshold_ms, silence_phrases(JSONB), silence_hangup_phrase, wrap_up_max_rounds, wrap_up_max_seconds, wrap_up_closing_phrases(JSONB), interruption_whitelist(JSONB), interruption_min_duration_ms, max_continuous_interruptions, continuous_interruption_strategy, transfer_keyword_enabled, transfer_keywords(JSONB), transfer_intent_enabled, transfer_intent_threshold, transfer_round_enabled, transfer_round_threshold, transfer_llm_enabled, transfer_llm_prompt_version_id, transfer_phrases(JSONB), retry_intervals(JSONB), retry_max_count, follow_up_interval_days, follow_up_max_count, do_not_call_keywords(JSONB), do_not_call_llm_enabled, do_not_call_llm_prompt_version_id, respect_holidays, **greeting(Text, nullable — campaign-level 固定开场白文案；NULL 时 engine 走 LLM 生成开场白路径，详见 ai-pipeline § "开场白不走管线")** | api | 各 capability |
| `holiday` | date, name, region | api | time-window |
| `agent` | name, login_user, status (online/offline) | telephony | human-handoff |
| `handoff_task` | call_record_id, agent_id (nullable), trigger_type, trigger_detail, status, created_at, picked_up_at, completed_at | api（worker 创建，api 提供查询/状态变更） | human-handoff |
| `role_config` | campaign_id, kind (role/judge/polish), model, current_prompt_version_id, temperature, top_p, ext_params(JSONB), enabled | api | role-prompt, ai-pipeline |
| `prompt_version` | scope_type, scope_id, content, created_at, created_by, is_active | api | role-prompt |
| `pipeline_trace` | call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates(JSONB), judge_results(JSONB), polish_input(JSONB), polish_output, polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index | engine | transcript |
| `lead` | name, phone, source, custom_data(JSONB), status, retry_count, follow_up_count, next_call_at, last_hangup_cause | api | retry-followup |
| `call_record` | lead_id, campaign_id, caller_id, status, started_at, ended_at, duration, transcript(JSONB), recording_url, transfer_status, transfer_reason, wrap_up_started_at, prompt_versions(JSONB) | engine | transcript |
| `call_summary` | call_record_id, summary_text, extracted_fields(JSONB), goal_achieved, goal_type | worker | goal-achievement |
| `appointment` | lead_id, created_from_call_id (nullable), appointment_time, status (pending/confirmed/completed/cancelled), store_address, directions, notes | api | appointment |
| `voice_model` | name, provider, voice_id, sample_url | api | (无独立 capability) |
| `filler_phrase` | campaign_id, phrase, audio_url, generation_status | api | filler |
| `callback_config` | campaign_id, name, trigger(JSONB, JsonLogic), url, method, headers(JSONB), payload_template(text, Jinja2), retry_policy(JSONB), signing_secret(Text, urlsafe base64 Fernet cipher — 见 provider-credential spec), timeout_seconds(nullable), enabled | api | webhook-callback |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, attempt_at, next_retry_at, error_message | worker | webhook-callback |
| `device` | name, usb_port, modem_model, imei, status (unknown/detected/registered/idle/dialing/in_call/offline/flagged/error，详见 device-hardware § device 状态机), last_seen_at, last_call_at | telephony | device-hardware |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony | device-hardware |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony | device-hardware |
| `campaign_device` | campaign_id, device_id | api | device-hardware |
| `provider_credential` | provider_id (VARCHAR(32)), field_name (VARCHAR(32)), cipher_text (Text, urlsafe base64 Fernet), updated_by (VARCHAR(64), JWT sub claim, no FK), updated_at；UNIQUE(provider_id, field_name) | api | provider-credential |

### Requirement: 数据库统一为 PostgreSQL

所有持久化数据 SHALL 存于同一 PostgreSQL 实例；MUST NOT 引入其他关系型 DB（除非未来明确需求并经过 change proposal）。

#### Scenario: 单库统一

- **WHEN** 实施
- **THEN** 所有表 SHALL 在同一 PG 实例 / 同一 schema；跨服务事务用 PG 事务；不引入分布式事务

### Requirement: JSONB 字段约束

JSONB 字段 SHALL 用于半结构化的配置或事件流；任何新引入的 JSONB 字段 MUST 附带 schema 描述并放置在对应 capability spec。

#### Scenario: JSONB 字段需附 schema 文档

- **WHEN** 引入新 JSONB 字段
- **THEN** 字段对应的 capability spec MUST 描述其 JSON schema（哪些键、值类型、必填可选）

#### Scenario: JSONB 不替代关系建模

- **WHEN** 数据有强结构与外键关系
- **THEN** SHALL 用独立表 + 外键，MUST NOT 用 JSONB 简化（如 callback_log 不能塞进 callback_config 的 JSONB）

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

### Requirement: campaign.voice_id 持有 vendor speaker 字符串

`campaign.voice_id` SHALL 为 `String(128)`、可空，直接持有 TTS vendor 的 speaker 标识字符串（如 `zh_female_xiaohe_uranus_bigtts`），由管理员在场景表单填写。该列 MUST NOT 是指向 `voice_model` 的外键——音色不在本系统编目，引擎与试听端点都将该字符串原样传给 TTS provider。NULL / 空串表示使用 provider 默认音色。

#### Scenario: 存取 speaker 字符串

- **WHEN** 创建 / 更新 campaign 时提供 `voice_id`（vendor speaker 串）
- **THEN** 系统 MUST 原样持久化该字符串，读取时原样返回，引擎合成时直接用作 TTS speaker

#### Scenario: 不依赖 voice_model 编目

- **WHEN** 设置 campaign 的音色
- **THEN** 系统 MUST NOT 要求该 speaker 预先存在于 `voice_model` 表；`campaign.voice_id` MUST NOT 对 `voice_model` 施加外键约束

### Requirement: campaign.asr_eos_silence_ms 端点静默阈值

`campaign` 表 SHALL 含 `asr_eos_silence_ms`（INT，nullable）字段，表示 ASR 判定用户说完（EOS）所需的稳定静默时长（毫秒）。NULL MUST 走系统默认（400ms）。engine `load_runtime_config` SHALL 读出该值透传给 ASR provider 构造，覆盖写死的端点阈值。

取值是 latency 与"误把停顿当说完打断用户"的权衡：越小开口越快、越易误打断犹豫的客户；campaign MUST 能按话术 / 客群停顿习惯独立调整。

#### Scenario: NULL 走默认

- **WHEN** campaign `asr_eos_silence_ms IS NULL`
- **THEN** engine SHALL 用系统默认 400ms 作为 ASR 端点静默阈值

#### Scenario: campaign 覆盖

- **WHEN** campaign `asr_eos_silence_ms = 250`
- **THEN** engine SHALL 用 250ms；该 campaign 的通话 EOS 判定更激进

#### Scenario: 透传到 ASR provider

- **WHEN** `load_runtime_config` 组装 RuntimeConfig
- **THEN** `asr_eos_silence_ms`（或默认）MUST 透传到 ASR provider 的端点检测参数，替换写死常量

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

### Requirement: campaign.filler_delay_ms 垫词门控阈值

`campaign` 表 SHALL 含 `filler_delay_ms`（INT，nullable）字段，表示进入 PROCESSING 后多久（毫秒）首音频仍未出就播垫词。NULL MUST 走系统默认（600ms）。engine `load_runtime_config` SHALL 读出该值透传给 `_play_streaming` 的垫词门控计时器。

#### Scenario: NULL 走默认

- **WHEN** campaign `filler_delay_ms IS NULL`
- **THEN** engine SHALL 用系统默认 600ms 作为垫词门控阈值

#### Scenario: campaign 覆盖

- **WHEN** campaign `filler_delay_ms = 400`
- **THEN** engine SHALL 在首音频超过 400ms 未出时播垫词

## Cross-Reference

各表的字段语义、约束、状态机 SHALL 在以下 capability spec 中查询：

- 业务行为：`interruption-detection`, `silence-activation`, `goal-achievement`, `filler`, `human-handoff`
- 输入输出：`role-prompt`, `transcript`, `webhook-callback`
- 调度与流程：`call-state-machine`, `retry-followup`, `time-window`, `ai-pipeline`
- 基础设施：`architecture`, `device-hardware`, `service-communication`
