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

engine SHALL 同时支持两种"勿打"识别机制；任一命中即 MUST 标记 lead.status=`do_not_call` 并清理未来调度任务。

#### Scenario: 关键词命中

- **WHEN** ASR 终态结果包含 `campaign.do_not_call_keywords`（如「不要打」「别打」「勿打」）中任一短语
- **THEN** engine 标记 do_not_call，进入收尾流程（不立刻挂断，礼貌告别）

#### Scenario: 独立 LLM 判定

- **WHEN** `campaign.do_not_call_llm_enabled=true` 且独立判定 LLM 输出 `{"do_not_call": true}`
- **THEN** engine 同上：标记 do_not_call 并进入收尾

#### Scenario: 标记后的处理

- **WHEN** 任一勿打识别命中
- **THEN** engine MUST 完成礼貌告别后挂断；worker SHALL 设 `lead.status=do_not_call`，移除该 lead 所有未来重试与跟进任务；MAY 触发 `do_not_call_marked` 事件让 callback_config 通知 CRM

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

scheduler 主循环 SHALL 按以下步骤选取 lead：

#### Scenario: 调度循环步骤

- **WHEN** scheduler 主循环每分钟启动
- **THEN** 步骤如下：
  1. 扫描 active 状态的 campaign
  2. 取 leads where `status ∈ {new, retrying, following_up}` 且 `next_call_at <= now`
  3. 检查可通话时间窗口（详见 time-window）
  4. 检查全局并发计数器（Redis INCR）
  5. 调 `telephony-api /devices/select` 选 device 与 caller_id
  6. 组装 dial 消息：lead 信息、is_follow_up、follow_up_count、历史摘要（跟进时）、当前 prompt_versions 快照
  7. push 到 engine:dial 队列

#### Scenario: worker 写回 lead 状态

- **WHEN** 通话结束后 worker 处理 call_record
- **THEN** worker SHALL 根据 hangup_cause 与 goal_achieved 决定 lead 后续状态；若进入 retrying / following_up 则计算并写回 `next_call_at`；若命中 do_not_call 则清理未来调度任务

## Data Schema

| 字段 | 类型 | 说明 |
|---|---|---|
| `campaign.retry_intervals` | JSONB array | 各次重试的间隔分钟数 |
| `campaign.retry_max_count` | int | 重试次数上限 |
| `campaign.follow_up_interval_days` | int | 每次跟进的间隔天数 |
| `campaign.follow_up_max_count` | int | 跟进次数上限 |
| `campaign.do_not_call_keywords` | JSONB array | 勿打关键词列表 |
| `campaign.do_not_call_llm_enabled` | bool | 是否启用独立判定 LLM |
| `campaign.do_not_call_llm_prompt_version_id` | FK / null | 独立 LLM 的 prompt 版本引用 |
| `lead.retry_count` | int | 已重试次数 |
| `lead.follow_up_count` | int | 已跟进次数 |
| `lead.next_call_at` | timestamp | 下次拨打时间 |
| `lead.last_hangup_cause` | string | 上次通话的挂断原因 |
| `lead.status` | enum | new/queued/calling/retrying/following_up/completed/failed/follow_up_exhausted/do_not_call/transferred |
