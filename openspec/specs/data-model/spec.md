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

每张表 SHALL 标记其主要业务归属（决定该服务的 PR 主导权）；多个服务可读写但归属仅一个。

#### Scenario: 表清单完整性

- **WHEN** 清点系统所有持久化表
- **THEN** 表集合 MUST 包含且仅包含以下：

| 表 | 关键字段 | 归属服务 | 详细规范 |
|---|---|---|---|
| `campaign` | name, voice_id, default_replies(JSONB), concurrency, time_windows(JSONB), extraction_fields(JSONB), max_silence_activations, silence_threshold_ms, silence_phrases(JSONB), silence_hangup_phrase, max_no_progress_seconds, wrap_up_max_rounds, wrap_up_max_seconds, wrap_up_closing_phrases(JSONB), interruption_whitelist(JSONB), interruption_min_duration_ms, max_continuous_interruptions, continuous_interruption_strategy, transfer_keyword_enabled, transfer_keywords(JSONB), transfer_intent_enabled, transfer_intent_threshold, transfer_round_enabled, transfer_round_threshold, transfer_llm_enabled, transfer_llm_prompt_version_id, transfer_phrases(JSONB), retry_intervals(JSONB), retry_max_count, follow_up_interval_days, follow_up_max_count, do_not_call_keywords(JSONB), do_not_call_llm_enabled, do_not_call_llm_prompt_version_id, respect_holidays | api | 各 capability |
| `holiday` | date, name, region | api | time-window |
| `agent` | name, login_user, status (online/offline) | telephony | human-handoff |
| `handoff_task` | call_record_id, agent_id (nullable), trigger_type, trigger_detail, status, created_at, picked_up_at, completed_at | api（worker 创建，api 提供查询/状态变更） | human-handoff |
| `role_config` | campaign_id, kind (role/judge/polish), model, current_prompt_version_id, temperature, top_p, ext_params(JSONB), enabled | api | role-prompt, ai-pipeline |
| `prompt_version` | scope_type, scope_id, content, created_at, created_by, is_active | api | role-prompt |
| `pipeline_trace` | call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates(JSONB), judge_results(JSONB), polish_input(JSONB), polish_output, polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index | engine | transcript |
| `lead` | name, phone, source, custom_data(JSONB), status, retry_count, follow_up_count, next_call_at, last_hangup_cause | api | retry-followup |
| `call_record` | lead_id, campaign_id, caller_id, status, started_at, ended_at, duration, transcript(JSONB), recording_url, transfer_status, transfer_reason, wrap_up_started_at, prompt_versions(JSONB) | engine | transcript |
| `call_summary` | call_record_id, summary_text, extracted_fields(JSONB), goal_achieved, goal_type | worker | goal-achievement |
| `voice_model` | name, provider, voice_id, sample_url | api | (无独立 capability) |
| `filler_set` | campaign_id, name, sort_order | api | filler |
| `filler_phrase` | filler_set_id, phrase, audio_url, generation_status | api | filler |
| `callback_config` | campaign_id, name, trigger(JSONB, JsonLogic), url, method, headers(JSONB), payload_template(text, Jinja2), retry_policy(JSONB), signing_secret(encrypted), timeout_seconds(nullable), enabled | api | webhook-callback |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, attempt_at, next_retry_at, error_message | worker | webhook-callback |
| `device` | name, usb_port, modem_model, imei, status (online/offline/flagged), last_seen_at | telephony | device-hardware |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony | device-hardware |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony | device-hardware |
| `campaign_device` | campaign_id, device_id | telephony | device-hardware |

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

## Cross-Reference

各表的字段语义、约束、状态机 SHALL 在以下 capability spec 中查询：

- 业务行为：`interruption-detection`, `silence-activation`, `goal-achievement`, `filler`, `human-handoff`
- 输入输出：`role-prompt`, `transcript`, `webhook-callback`
- 调度与流程：`call-state-machine`, `retry-followup`, `time-window`, `ai-pipeline`
- 基础设施：`architecture`, `device-hardware`, `service-communication`
