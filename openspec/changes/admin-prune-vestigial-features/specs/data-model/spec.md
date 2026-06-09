## MODIFIED Requirements

### Requirement: 表归属与全表清单

每张表 SHALL 标记其主要业务归属——归属决定 schema 演进与 PR 主导权，多个服务可读写但归属仅一个；具体读写权由 `service-communication` spec 的"数据库直连"与"跨服务读 vs 写"两条 Requirement 约束。当某张关联表的 lifecycle 跟随归属 A 而非归属 B（例如 `campaign_device` 跟随 campaign 的启停而非 device 的插拔），归属 SHALL 设为 A。

`appointment` / `voice_model` / `handoff_task` 三张表已随 change `admin-prune-vestigial-features`（drop 迁移 `c4d5e6f7a8b9`）整体删除，不再属于全表清单：appointment 是无运行时闭环的手工台账；voice_model 自 `f6a7b8c9d0e1` 起是 campaign.voice_id 改为自由文本后的孤儿目录；handoff_task 是从未被写入的转人工任务空表。`agent` 表保留（v1 坐席登录主体），`campaign.voice_id` 仍持有 vendor speaker 字符串（见本 spec § "campaign.voice_id 持有 vendor speaker 字符串"），`lead.status` 不再含 `appointed` / `visited` 成员（保留 `lost` 等其余值）。

#### Scenario: 表清单完整性

- **WHEN** 清点系统所有持久化表
- **THEN** 表集合 MUST 包含且仅包含以下：

| 表 | 关键字段 | 归属服务 | 详细规范 |
|---|---|---|---|
| `campaign` | name, voice_id, default_replies(JSONB), concurrency, time_windows(JSONB), extraction_fields(JSONB), max_silence_activations, silence_threshold_ms, silence_phrases(JSONB), filler_phrases(JSONB), silence_hangup_phrase, max_no_progress_seconds, wrap_up_max_rounds, wrap_up_max_seconds, wrap_up_closing_phrases(JSONB), interruption_whitelist(JSONB), interruption_min_duration_ms, max_continuous_interruptions, continuous_interruption_strategy, transfer_keyword_enabled, transfer_keywords(JSONB), transfer_intent_enabled, transfer_intent_threshold, transfer_round_enabled, transfer_round_threshold, transfer_llm_enabled, transfer_llm_prompt_version_id, transfer_phrases(JSONB), retry_intervals(JSONB), retry_max_count, follow_up_interval_days, follow_up_max_count, do_not_call_keywords(JSONB), do_not_call_llm_enabled, do_not_call_llm_prompt_version_id, respect_holidays, **greeting(Text, nullable — campaign-level 固定开场白文案；NULL 时 engine 走 LLM 生成开场白路径，详见 ai-pipeline § "开场白不走管线")** | api | 各 capability |
| `holiday` | date, name, region | api | time-window |
| `agent` | name, login_user, status (online/offline) | telephony | human-handoff |
| `role_config` | campaign_id, kind (role/judge/polish), model, current_prompt_version_id, temperature, top_p, ext_params(JSONB), enabled | api | role-prompt, ai-pipeline |
| `prompt_version` | scope_type, scope_id, content, created_at, created_by, is_active | api | role-prompt |
| `pipeline_trace` | call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates(JSONB), judge_results(JSONB), polish_input(JSONB), polish_output, polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index | engine | transcript |
| `lead` | name, phone, source, custom_data(JSONB), status, retry_count, follow_up_count, next_call_at, last_hangup_cause | api | retry-followup |
| `call_record` | lead_id, campaign_id, caller_id, status, started_at, ended_at, duration, transcript(JSONB), recording_url, transfer_status, transfer_reason, wrap_up_started_at, prompt_versions(JSONB) | engine | transcript |
| `call_summary` | call_record_id, summary_text, extracted_fields(JSONB), goal_achieved, goal_type | worker | goal-achievement |
| `callback_config` | campaign_id, name, trigger(JSONB, JsonLogic), url, method, headers(JSONB), payload_template(text, Jinja2), retry_policy(JSONB), signing_secret(Text, urlsafe base64 Fernet cipher — 见 provider-credential spec), timeout_seconds(nullable), enabled | api | webhook-callback |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, attempt_at, next_retry_at, error_message | worker | webhook-callback |
| `device` | name, usb_port, modem_model, imei, status (unknown/detected/registered/idle/dialing/in_call/offline/flagged/error，详见 device-hardware § device 状态机), last_seen_at, last_call_at | telephony | device-hardware |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony | device-hardware |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony | device-hardware |
| `campaign_device` | campaign_id, device_id | api | device-hardware |
| `provider_credential` | provider_id (VARCHAR(32)), field_name (VARCHAR(32)), cipher_text (Text, urlsafe base64 Fernet), updated_by (VARCHAR(64), JWT sub claim, no FK), updated_at；UNIQUE(provider_id, field_name) | api | provider-credential |
