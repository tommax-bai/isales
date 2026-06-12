## Purpose

定义重试与跟进两个独立机制：重试用于通话因技术原因未完成的再次拨打，跟进用于已完成但目标未达成的二次外呼。本规范覆盖 hangup_cause 分类、间隔策略、上限处理、勿打识别、lead 状态机。
## Requirements
### Requirement: 重试与跟进的概念区分

重试与跟进 SHALL 是两个独立机制：独立计数、独立间隔策略、独立上限。

#### Scenario: 进入重试队列的条件

- **WHEN** 通话以技术失败结束（hangup_cause ∈ {`no_answer`, `user_busy`, `network_out_of_order`, `temporary_failure`}）
- **THEN** lead 状态 → `retrying`，由 scheduler 按 `campaign.retry_intervals` 排队再次拨打

#### Scenario: 进入跟进队列的条件

- **WHEN** 通话正常结束（hangup_cause ∈ {`normal_clearing`, `wrap_up_completed`, `silence_max_reached`}）且 `call_summary.goal_achieved=false` 且 `lead.status != do_not_call`
- **THEN** lead 状态 → `following_up`，按 `campaign.follow_up_interval_days` 排队跟进

#### Scenario: 不重试的失败场景

- **WHEN** 通话 hangup_cause 是 `call_rejected` 或用户接通后立即挂断
- **THEN** MUST NOT 进入重试队列（视为用户明确拒绝）

### Requirement: 重试间隔与上限

重试间隔策略 SHALL 为指数退避数组 + 最大次数。第 N 次重试间隔 MUST = `retry_intervals[N-1]`；超出数组长度时 SHALL 使用最后一项。重试次数累计达到 `retry_max_count` 时 lead 状态 SHALL 进入 `failed`。

#### Scenario: 第 N 次重试间隔取值

- **WHEN** Campaign 配置 `retry_intervals=[60, 240, 1440]`（分钟），且当前是第 4 次重试
- **THEN** scheduler 计算 `next_call_at = 上次通话结束时间 + 1440 分钟`（沿用最后一项）

#### Scenario: 重试上限达成

- **WHEN** lead 已重试次数 ≥ `retry_max_count`
- **THEN** lead 状态 → `failed`（终态），不再排队

### Requirement: 跟进间隔与上限

跟进间隔策略 SHALL 为固定间隔 + 最大次数。每次跟进时间 MUST = 上一次通话结束时间 + N × `follow_up_interval_days`。跟进次数达到 `follow_up_max_count` 时 lead 状态 SHALL 进入 `follow_up_exhausted`。

#### Scenario: 跟进时间计算

- **WHEN** Campaign 配置 `follow_up_interval_days=3`，且本次为第 2 次跟进，本次通话结束于 2026-05-01
- **THEN** scheduler 设 `next_call_at = 2026-05-04`

#### Scenario: 跟进上限达成

- **WHEN** lead 已跟进次数 ≥ `follow_up_max_count`
- **THEN** lead 状态 → `follow_up_exhausted`（终态），不再排队

### Requirement: 跟进时角色 LLM 上下文增强

跟进通话调用角色 LLM 时，engine SHALL 在 system prompt 末尾追加跟进上下文段落（紧跟可能的收尾指令之前）。上次通话摘要 SHALL 由 scheduler 在 dial 队列消息中携带，engine MUST NOT 直接查 DB（详见 role-prompt）。

#### Scenario: 跟进上下文段落

- **WHEN** 通话是跟进通话（is_follow_up=true）且 follow_up_count=N
- **THEN** system prompt 末尾追加段落：
  ```
  【跟进上下文】
  这是对该用户的第 N 次跟进。上次通话结束于 {timestamp}。
  请根据下面的【上次通话纪要】调整开场和后续话术，避免重复内容。
  ```

#### Scenario: 历史摘要由 scheduler 注入

- **WHEN** scheduler 派发跟进通话
- **THEN** dial 消息 MUST 携带 `last_call_summary` 字段（从 `call_summary` 表查得），engine 直接使用而不再查 DB

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

### Requirement: lead 状态机

`lead` 表 SHALL 维护以下状态字段并按规则流转：

```
new → queued → calling
                  │
                  ├─ 重试场景 ───────── retrying ──→ queued
                  │
                  ├─ 重试上限 ───────── failed
                  │
                  ├─ 通话完成 + 达成 → completed
                  │
                  ├─ 通话完成 + 未达 → following_up ──→ queued
                  │
                  ├─ 跟进上限 ───────── follow_up_exhausted
                  │
                  ├─ 勿打命中 ───────── do_not_call
                  │
                  └─ 转人工触发 ─────── transferred
```

终态 MUST 包括：`completed` / `failed` / `follow_up_exhausted` / `do_not_call` / `transferred`。

#### Scenario: 终态不再被 scheduler 扫描

- **WHEN** lead 进入任一终态
- **THEN** scheduler 主循环 MUST NOT 再选取该 lead 拨打

### Requirement: scheduler 调度数据流

scheduler 主循环 SHALL 按以下步骤选取并派发 lead；派发成功后 SHALL 仅写 `lead.status='calling'`，MUST NOT 写任何终态或重试/跟进状态——这些由 worker（阶段 3B）写回。本 Requirement 把 scheduler 与 worker 的状态写入边界从隐式约定提升为硬契约。

#### Scenario: 调度循环步骤

- **WHEN** scheduler 主循环每分钟启动
- **THEN** 步骤如下：
  1. 扫描 active 状态的 campaign（active 集合由 CampaignControl 消费 + 启动重建维护）
  2. 取 leads where `status ∈ {new, retrying, following_up}` 且 `(next_call_at IS NULL OR next_call_at <= now)`
  3. 检查可通话时间窗口（详见 time-window）
  4. 检查全局并发计数器（Redis INCR）
  5. 调 `telephony-api /devices/select` 选 device 与 caller_id
  6. 组装 dial 消息：lead 信息、is_follow_up、follow_up_count、历史摘要（跟进时）、当前 prompt_versions 快照
  7. push 到 engine:dial 队列

#### Scenario: 新线索首次入队语义

- **WHEN** scheduler 取数遇到 `status='new'` 且 `next_call_at IS NULL` 的 lead（新建 / 导入后尚未排期）
- **THEN** SHALL 视该 lead 为"立即可呼"并纳入候选；`next_call_at IS NULL` 语义上等同 `next_call_at <= now`，MUST NOT 要求任何服务在 lead 创建时预先初始化 `next_call_at`——首次入队由本取数条件天然覆盖

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

### Requirement: REFEREE_HANGUP 归入不自动重拨终态

`hangup_cause = REFEREE_HANGUP`（AI 依开口前门控裁决主动挂断，见 ai-pipeline / data-model spec）SHALL 被归类为**不自动重拨**的终态桶：worker 处理通话结束时 MUST NOT 把该 lead 放入重试队列、MUST NOT 放入自动跟进队列——AI 主动结束本通电话，自动重拨与该决定相矛盾。该 cause MUST NOT 出现在"可重试 cause"集合 `{no_answer, user_busy, network_out_of_order, temporary_failure}` 中。

#### Scenario: REFEREE_HANGUP 不进重试

- **WHEN** 通话以 `hangup_cause = REFEREE_HANGUP` 结束、worker 决定后续
- **THEN** worker MUST NOT 把 lead 置 `retrying`、MUST NOT 计算 retry `next_call_at`；lead MUST NOT 因本通话再次自动入队

#### Scenario: REFEREE_HANGUP 不进自动跟进

- **WHEN** 通话以 `REFEREE_HANGUP` 结束且 `goal_achieved=false`
- **THEN** worker MUST NOT 把 lead 置 `following_up`（区别于 `normal_clearing` 等正常结束 + 未达成 → 自动跟进）；AI 主动挂断视作业务流程显式终止

## Data Schema

| 字段 | 类型 | 说明 |
|---|---|---|
| `campaign.retry_intervals` | JSONB array | 各次重试的间隔分钟数 |
| `campaign.retry_max_count` | int | 重试次数上限 |
| `campaign.follow_up_interval_days` | int | 每次跟进的间隔天数 |
| `campaign.follow_up_max_count` | int | 跟进次数上限 |
| `lead.retry_count` | int | 已重试次数 |
| `lead.follow_up_count` | int | 已跟进次数 |
| `lead.next_call_at` | timestamp | 下次拨打时间 |
| `lead.last_hangup_cause` | string | 上次通话的挂断原因 |
| `lead.status` | enum | new/queued/calling/retrying/following_up/completed/failed/follow_up_exhausted/do_not_call/transferred |
