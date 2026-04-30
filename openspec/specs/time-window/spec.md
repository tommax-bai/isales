## Purpose

定义可通话时间窗口的配置模型、时区策略、节假日处理、窗外 lead 的调度规则、跨边界保护。窗口判定 SHALL 在 scheduler 派发前完成，确保 engine 在窗外不收到新拨打任务。

## Requirements

### Requirement: Campaign 级多窗口配置

`campaign.time_windows`（JSONB array）SHALL 支持配置 N 个时间窗口，每个窗口指定星期几 + 起止时间。

#### Scenario: 工作日双时段 + 周末单时段

- **WHEN** Campaign 配置如下窗口：
  ```json
  [
    {"days": ["mon","tue","wed","thu","fri"], "start": "09:00", "end": "12:00"},
    {"days": ["mon","tue","wed","thu","fri"], "start": "14:00", "end": "18:00"},
    {"days": ["sat"],                          "start": "10:00", "end": "16:00"}
  ]
  ```
- **THEN** scheduler 在工作日上午 9-12、下午 14-18、周六 10-16 三段内 SHALL 视为窗口内

#### Scenario: 窗口空数组

- **WHEN** `time_windows = []`
- **THEN** scheduler MUST 视该 Campaign 全天禁止外呼（极端情况，应在创建时校验阻止）

### Requirement: 统一服务器时区

所有窗口判定、节假日、`next_call_at` 计算 SHALL 按服务器时区解读（部署侧设定，如 `Asia/Shanghai`）；MUST NOT 引入 lead 级时区。跨时区场景属 v2。

#### Scenario: 时区一致性

- **WHEN** 服务器配置 `TZ=Asia/Shanghai`
- **THEN** `time_windows` 中的 `start: "09:00"` 解释为 Shanghai 时区 9:00；`next_call_at` 存储与读取 MUST 都按 Shanghai 时区处理

### Requirement: 全局节假日表与 Campaign 选择

系统 SHALL 维护全局 `holiday` 表；Campaign 通过 `respect_holidays` 字段（默认 true）选择是否遵从。

#### Scenario: 启用节假日且当日命中

- **WHEN** `campaign.respect_holidays=true` 且当前日期在 holiday 表中（region=`CN_mainland`）
- **THEN** scheduler 当日 MUST 视该 Campaign 为窗外，不分配新 lead

#### Scenario: 不启用节假日

- **WHEN** `campaign.respect_holidays=false`
- **THEN** scheduler 仅按 time_windows 判定，忽略 holiday 表

### Requirement: 窗外 lead 推迟到下个窗口开始时刻

scheduler 扫描到 `lead.next_call_at <= now` 但当前不在任何窗口内时 SHALL 计算最近的窗口开始时刻并更新 `lead.next_call_at`，本次拨打跳过。

#### Scenario: 当日工作时段已过

- **WHEN** scheduler 在工作日 19:00 扫描到 lead 应拨，但当日所有窗口已过
- **THEN** scheduler 计算次日第 1 个窗口开始时刻 → 更新 lead.next_call_at；本次不拨打

#### Scenario: 节假日推迟到节后

- **WHEN** scheduler 在春节首日扫描到 lead 应拨，且 `respect_holidays=true`
- **THEN** scheduler 计算节后第 1 个非节假日且在窗口内的时刻

#### Scenario: 跨周边界

- **WHEN** scheduler 在周日扫描到 lead 应拨且当日不是窗口内
- **THEN** scheduler 计算下周一第 1 个窗口开始时刻

### Requirement: 跨窗口边界保护

通话进行中跨过窗口结束时刻 MUST NOT 被强制中断；scheduler MUST 仅在窗外**不再分配新 lead**。

#### Scenario: 通话跨过窗口边界

- **WHEN** 一通通话在窗口最后 30 秒发起，通话持续 5 分钟跨过窗口结束时刻
- **THEN** engine SHALL 让该通话自然完成；scheduler 在窗口结束后 MUST NOT 再分配新 lead 给 engine

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `campaign.time_windows` (JSONB array) | 时间窗口列表，详见 §13.1 |
| `campaign.respect_holidays` (bool, default true) | 是否遵从全局节假日表 |
| `holiday` 表 | id, date (YYYY-MM-DD), name, region (v1 仅 CN_mainland), created_at |
