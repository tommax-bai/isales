## MODIFIED Requirements

### Requirement: 表归属与全表清单

每张表 SHALL 标记其主要业务归属——归属决定 schema 演进与 PR 主导权，多个服务可读写但归属仅一个；具体读写权由 `service-communication` spec 的"数据库直连"与"跨服务读 vs 写"两条 Requirement 约束。当某张关联表的 lifecycle 跟随归属 A 而非归属 B（例如 `campaign_device` 跟随 campaign 的启停而非 device 的插拔），归属 SHALL 设为 A。

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
| `appointment` | lead_id, created_from_call_id (nullable), appointment_time, status (pending/confirmed/completed/cancelled), store_address, directions, notes | api | appointment |
| `voice_model` | name, provider, voice_id, sample_url | api | (无独立 capability) |
| `filler_set` | campaign_id, name, sort_order | api | filler |
| `filler_phrase` | filler_set_id, phrase, audio_url, generation_status | api | filler |
| `callback_config` | campaign_id, name, trigger(JSONB, JsonLogic), url, method, headers(JSONB), payload_template(text, Jinja2), retry_policy(JSONB), signing_secret(encrypted), timeout_seconds(nullable), enabled | api | webhook-callback |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, attempt_at, next_retry_at, error_message | worker | webhook-callback |
| `device` | name, usb_port, modem_model, imei, status (unknown/detected/registered/idle/dialing/in_call/offline/flagged/error，详见 device-hardware § device 状态机), last_seen_at, last_call_at | telephony | device-hardware |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony | device-hardware |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony | device-hardware |
| `campaign_device` | campaign_id, device_id | api | device-hardware |
