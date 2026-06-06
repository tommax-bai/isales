## MODIFIED Requirements

### Requirement: 重试与跟进的概念区分

重试与跟进 SHALL 是两个独立机制：独立计数、独立间隔策略、独立上限。

#### Scenario: 进入重试队列的条件

- **WHEN** 通话以技术失败结束（hangup_cause ∈ {`no_answer`, `user_busy`, `network_out_of_order`, `temporary_failure`}）
- **THEN** lead 状态 → `retrying`，由 scheduler 按 `campaign.retry_intervals` 排队再次拨打

#### Scenario: 进入跟进队列的条件

- **WHEN** 通话正常结束（hangup_cause ∈ {`normal_clearing`, `wrap_up_completed`, `silence_max_reached`}）且 `call_summary.goal_achieved=false` 且 `lead.status != do_not_call`
- **THEN** lead 状态 → `following_up`，按 `campaign.follow_up_interval_days` 排队跟进

#### Scenario: 不重试的失败场景

- **WHEN** 通话 hangup_cause 是 `call_rejected`、`referee_hangup`、或用户接通后立即挂断
- **THEN** MUST NOT 进入重试队列（视为用户明确拒绝，或本端依裁判判定主动结束）
- **AND** `referee_hangup` 亦不在跟进 cause 集合内，故 MUST NOT 进入跟进队列（与 `manual_hangup` 一致，本端主动结束=业务流程已显式终止）；如运营另需「勿打」，由既有 do_not_call 关键词 / 独立 LLM 路径单独负责，与 `referee_hangup` 正交
