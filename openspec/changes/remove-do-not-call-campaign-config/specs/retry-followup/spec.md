## MODIFIED Requirements

### Requirement: "勿打"识别（双重 OR 关系）

worker SHALL 通过两种 OR 关系的 marker 把 lead 标记为"勿打"终态；任一命中即 MUST 设 `lead.status=do_not_call` 并清理该 lead 未来全部重试与跟进调度任务。

该 marker 由通用管线产生（典型来源：管理员配置的 routing rule 命中后，其 transition action 携带 `goal_type=do_not_call`，见 data-model § `campaign.routing_rules`）。"勿打"识别 MUST NOT 再依赖 campaign 级 `do_not_call_keywords` / `do_not_call_llm_enabled` / `do_not_call_llm_prompt_version_id` 配置——这三项配置（关键词表臂、独立判定 LLM 臂、其 prompt 版本引用）从未接入引擎/scheduler/worker 运行时，已随 change `remove-do-not-call-campaign-config` 连同 campaign 列与 web `DoNotCallTab` 一并移除。

#### Scenario: goal_type marker 命中

- **WHEN** `call_summary.goal_type == 'do_not_call'`
- **THEN** worker SHALL 设 `lead.status=do_not_call`

#### Scenario: transcript 事件命中

- **WHEN** `call_record.transcript` 含 `type == 'do_not_call_marked'` 的事件
- **THEN** worker SHALL 同样设 `lead.status=do_not_call`

#### Scenario: 勿打终态的调度清理与回调

- **WHEN** 任一勿打 marker 命中、worker 写回 lead 状态
- **THEN** worker SHALL 移除该 lead 所有未来重试与跟进任务（`next_call_at` 清空）；MAY 触发 `do_not_call_marked` 事件让 callback_config 通知 CRM（见 webhook-callback spec）
