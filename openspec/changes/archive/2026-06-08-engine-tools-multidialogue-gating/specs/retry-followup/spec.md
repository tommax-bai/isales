## ADDED Requirements

### Requirement: REFEREE_HANGUP 归入不自动重拨终态

`hangup_cause = REFEREE_HANGUP`（AI 依开口前门控裁决主动挂断，见 ai-pipeline / data-model spec）SHALL 被归类为**不自动重拨**的终态桶：worker 处理通话结束时 MUST NOT 把该 lead 放入重试队列、MUST NOT 放入自动跟进队列——AI 主动结束本通电话，自动重拨与该决定相矛盾。该 cause MUST NOT 出现在"可重试 cause"集合 `{no_answer, user_busy, network_out_of_order, temporary_failure}` 中。

#### Scenario: REFEREE_HANGUP 不进重试

- **WHEN** 通话以 `hangup_cause = REFEREE_HANGUP` 结束、worker 决定后续
- **THEN** worker MUST NOT 把 lead 置 `retrying`、MUST NOT 计算 retry `next_call_at`；lead MUST NOT 因本通话再次自动入队

#### Scenario: REFEREE_HANGUP 不进自动跟进

- **WHEN** 通话以 `REFEREE_HANGUP` 结束且 `goal_achieved=false`
- **THEN** worker MUST NOT 把 lead 置 `following_up`（区别于 `normal_clearing` 等正常结束 + 未达成 → 自动跟进）；AI 主动挂断视作业务流程显式终止
