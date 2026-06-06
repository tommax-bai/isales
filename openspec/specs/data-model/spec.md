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

本 change 修改 3 张表的字段集：`role_config.kind` 枚举值改为 `{main, referee, extractor}`；`pipeline_trace` 字段集大幅简化；`call_record` 增加 `extract_status` + `extract_error` 字段。

#### Scenario: 表清单完整性

- **WHEN** 清点系统所有持久化表
- **THEN** 表集合 MUST 包含且仅包含以下：

| 表 | 关键字段 | 归属服务 | 详细规范 |
|---|---|---|---|
| `campaign` | name, voice_id, default_replies(JSONB), concurrency, time_windows(JSONB), extraction_fields(JSONB), max_silence_activations, silence_threshold_ms, silence_phrases(JSONB), silence_hangup_phrase, max_no_progress_seconds, wrap_up_max_rounds, wrap_up_max_seconds, wrap_up_closing_phrases(JSONB), interruption_whitelist(JSONB), interruption_min_duration_ms, max_continuous_interruptions, continuous_interruption_strategy, transfer_keyword_enabled, transfer_keywords(JSONB), transfer_intent_enabled, transfer_intent_threshold, transfer_round_enabled, transfer_round_threshold, transfer_llm_enabled, transfer_llm_prompt_version_id, transfer_phrases(JSONB), retry_intervals(JSONB), retry_max_count, follow_up_interval_days, follow_up_max_count, do_not_call_keywords(JSONB), do_not_call_llm_enabled, do_not_call_llm_prompt_version_id, respect_holidays, **filler_enabled** | api | 各 capability |
| `holiday` | date, name, region | api | time-window |
| `agent` | name, login_user, status (online/offline) | telephony | human-handoff |
| `handoff_task` | call_record_id, agent_id (nullable), trigger_type, trigger_detail, status, created_at, picked_up_at, completed_at | api（worker 创建，api 提供查询/状态变更） | human-handoff |
| `role_config` | campaign_id, **kind (main/referee/extractor)**, model, current_prompt_version_id, temperature, top_p, ext_params(JSONB), enabled | api | role-prompt, ai-pipeline |
| `prompt_version` | **scope_type (main/referee/extractor)**, scope_id, content, created_at, created_by, is_active | api | role-prompt |
| `pipeline_trace` | call_record_id, turn_id, ts_start, ts_end, user_input, **main_reply_text(TEXT), main_duration_ms(INT), main_tokens_in(INT), main_tokens_out(INT), main_fallback_used(BOOL), referee_decision(TEXT), referee_goal_type(TEXT), referee_confidence(REAL), referee_duration_ms(INT), first_audio_ms(INT)**, error(TEXT) | engine | transcript, ai-pipeline |
| `lead` | name, phone, source, custom_data(JSONB), status, retry_count, follow_up_count, next_call_at, last_hangup_cause | api | retry-followup |
| `call_record` | lead_id, campaign_id, caller_id, status, started_at, ended_at, duration, transcript(JSONB), recording_url, transfer_status, transfer_reason, wrap_up_started_at, prompt_versions(JSONB), **extracted(JSONB), extract_status(VARCHAR), extract_error(TEXT)** | engine | transcript, ai-pipeline |
| `call_summary` | call_record_id, summary_text, goal_achieved, goal_type | worker | goal-achievement |
| `appointment` | lead_id, created_from_call_id (nullable), appointment_time, status (pending/confirmed/completed/cancelled), store_address, directions, notes | api | appointment |
| `voice_model` | name, provider, voice_id, sample_url | api | (无独立 capability) |
| `filler_set` | campaign_id, name, sort_order | api | filler |
| `filler_phrase` | filler_set_id, phrase, audio_url, generation_status | api | filler |
| `callback_config` | campaign_id, name, trigger(JSONB, JsonLogic), url, method, headers(JSONB), payload_template(text, Jinja2), retry_policy(JSONB), signing_secret(Text, urlsafe base64 Fernet cipher — 见 provider-credential spec), timeout_seconds(nullable), enabled | api | webhook-callback |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, attempt_at, next_retry_at, error_message | worker | webhook-callback |
| `device` | name, usb_port, modem_model, imei, status (unknown/detected/registered/idle/dialing/in_call/offline/flagged/error，详见 device-hardware § device 状态机), last_seen_at, last_call_at | telephony | device-hardware |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony | device-hardware |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony | device-hardware |
| `campaign_device` | campaign_id, device_id | api | device-hardware |
| `provider_credential` | provider_id (VARCHAR(32)), field_name (VARCHAR(32)), cipher_text (Text, urlsafe base64 Fernet), updated_by (VARCHAR(64), JWT sub claim, no FK), updated_at；UNIQUE(provider_id, field_name) | api | provider-credential |

#### Scenario: role_config.kind 枚举改 main/referee/extractor

- **WHEN** 创建或查询 role_config 记录
- **THEN** `kind` 字段 SHALL ∈ `{"main", "referee", "extractor"}`；alembic migration MUST 在升级时 DELETE 现有 `kind IN ('role', 'judge', 'polish')` 行（v1 还没真实生产数据，acceptable）
- **AND** Campaign 启动前 MUST 含恰好 1 个 `main` + 1 个 `referee` + 1 个 `extractor` 三行 role_config（缺则 scheduler 拒绝分派）

#### Scenario: pipeline_trace 字段语义

- **WHEN** engine 在 PROCESSING 完成时写一条 pipeline_trace
- **THEN** 字段含义 SHALL 是：
  - `main_reply_text`: main LLM 流式聚合后的完整 reply 文本（或 default_reply 兜底时的兜底文本）
  - `main_duration_ms`: main LLM 从 chat_stream 启动到 last token 总时长
  - `main_tokens_in` / `main_tokens_out`: token 计费
  - `main_fallback_used`: 是否走了 streaming → chat() 非流式 fallback
  - `referee_decision`: referee 输出的 decision 字段（含 `"timeout" / "invalid" / "low_confidence"` 三种 fail-open 标记）
  - `referee_goal_type`: referee 输出的 goal_type（goal_achieved 时非空）
  - `referee_confidence`: referee 输出的 confidence（fail-open 时为 null）
  - `referee_duration_ms`: referee LLM 调用时长
  - `first_audio_ms`: 从 PROCESSING 入口到首 PCM chunk 推到 RTC 的时间差（监控用）
  - `error`: 任意失败原因（兜底场景 / extractor 不在此字段）

#### Scenario: call_record.extract_status 字段语义

- **WHEN** 查询 call_record 的 extractor 状态
- **THEN** `extract_status` SHALL ∈ `{null, 'pending', 'done', 'failed'}`；含义：
  - `null`: 老数据（本 change 之前的 call_record） / 本通话未触发 extractor（如 dial_fail）
  - `pending`: engine 已 LPUSH `isales:extract`，worker 未处理 / 处理中
  - `done`: worker 成功 UPDATE `extracted` 字段
  - `failed`: worker 失败，`extract_error` 字段记录原因；ops 可手工触发重跑

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

## Cross-Reference

各表的字段语义、约束、状态机 SHALL 在以下 capability spec 中查询：

- 业务行为：`interruption-detection`, `silence-activation`, `goal-achievement`, `filler`, `human-handoff`
- 输入输出：`role-prompt`, `transcript`, `webhook-callback`
- 调度与流程：`call-state-machine`, `retry-followup`, `time-window`, `ai-pipeline`
- 基础设施：`architecture`, `device-hardware`, `service-communication`
