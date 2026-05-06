## MODIFIED Requirements

### Requirement: scheduler 调度数据流

scheduler 主循环 SHALL 按以下步骤选取并派发 lead；派发成功后 SHALL 仅写 `lead.status='calling'`，MUST NOT 写任何终态或重试/跟进状态——这些由 worker（阶段 3B）写回。本 Requirement 把 scheduler 与 worker 的状态写入边界从隐式约定提升为硬契约。

#### Scenario: 调度循环步骤

- **WHEN** scheduler 主循环每分钟启动
- **THEN** 步骤如下：
  1. 扫描 active 状态的 campaign（active 集合由 CampaignControl 消费 + 启动重建维护）
  2. 取 leads where `status ∈ {new, retrying, following_up}` 且 `next_call_at <= now`
  3. 检查可通话时间窗口（详见 time-window）
  4. 检查全局并发计数器（Redis INCR）
  5. 调 `telephony-api /devices/select` 选 device 与 caller_id
  6. 组装 dial 消息：lead 信息、is_follow_up、follow_up_count、历史摘要（跟进时）、当前 prompt_versions 快照
  7. push 到 engine:dial 队列

#### Scenario: scheduler 派发成功后的状态写入

- **WHEN** scheduler 完成步骤 7（DialRequest 已 LPUSH `engine:dial`）
- **THEN** SHALL `UPDATE lead SET status='calling' WHERE id=<lead_id>`；MUST NOT 同时写 `completed/failed/follow_up_exhausted/do_not_call/transferred` 等终态；MUST NOT 计算或写 `next_call_at` 的重试/跟进新值（这是 worker 职责）

#### Scenario: scheduler 派发失败的状态保持

- **WHEN** scheduler 在步骤 4-7 任一步失败（并发上限、选号失败、DialRequest 构造失败、LPUSH 失败）
- **THEN** lead.status MUST 保持原值（仍是 `new/retrying/following_up`），让下一 tick 重试；MUST 把已 INCR 的并发计数器 DECR 回滚

#### Scenario: scheduler 仅在窗外重排时写 next_call_at

- **WHEN** scheduler 选中 lead 但当前不在 campaign 任何窗口内（按 time-window spec）
- **THEN** SHALL 计算最近的窗口起点并 `UPDATE lead SET next_call_at=<新值>`；这是本 Requirement 允许 scheduler 写 `next_call_at` 的唯一场景；其他场景（重试间隔、跟进间隔）的 `next_call_at` 写入 MUST 由 worker 承担

#### Scenario: worker 写回 lead 状态

- **WHEN** 通话结束后 worker 处理 call_record
- **THEN** worker SHALL 根据 hangup_cause 与 goal_achieved 决定 lead 后续状态；若进入 retrying / following_up 则计算并写回 `next_call_at`；若命中 do_not_call 则清理未来调度任务；worker 写回时 MUST 把 `lead.status` 从 `calling` 改成具体后续状态，使下一 tick 能再次选中或终态终止
