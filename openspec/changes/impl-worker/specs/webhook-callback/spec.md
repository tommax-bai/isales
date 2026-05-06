## MODIFIED Requirements

### Requirement: 重试策略：指数退避 + 最大次数

`callback_config.retry_policy` SHALL 为 JSONB 结构 `{intervals_seconds: [...], max_attempts: N}`。worker 失败时 MUST 按此策略重试；累计尝试次数达到 max_attempts 时 status SHALL 置 `exhausted`。worker 实现 SHALL 由独立的"重试调度器"后台 task 承担：周期性（≤ 60s）扫描 `callback_log WHERE status='pending_retry' AND next_retry_at <= now`，按 `next_retry_at ASC` 取一批重试；重试时 MUST 复用上次已存的 `request_body`（不重新评估 trigger / 重新渲染 payload），以保证"原触发瞬间"的事实不被 lead 状态变化污染。

#### Scenario: 指数退避取值

- **WHEN** retry_policy = `{intervals_seconds: [60, 300, 1800], max_attempts: 3}` 且当前是第 2 次重试
- **THEN** 间隔 = 300 秒（取数组第 2 项）

#### Scenario: 超出数组长度

- **WHEN** 第 N 次重试且 N > intervals_seconds.length
- **THEN** worker MUST 沿用最后一项

#### Scenario: 触发重试的错误

- **WHEN** HTTP 响应是 5xx / 超时 / 连接失败
- **THEN** worker SHALL 重试，next_retry_at = now + 当前间隔；callback_log.status SHALL 置 `pending_retry`；retry_count 自增；重试调度器扫到后再发起 HTTP 请求

#### Scenario: 不重试的错误

- **WHEN** HTTP 响应是 4xx 或 trigger / payload 渲染失败
- **THEN** worker MUST NOT 重试；status 直接置 `failed_http_4xx` / `failed_render`

#### Scenario: 重试调度器复用 request_body

- **WHEN** 重试调度器 tick 取到一条 `status='pending_retry'` 的 callback_log
- **THEN** SHALL 直接复用 `callback_log.request_body` 作为 HTTP body 重发；MUST NOT 重新评估 `trigger` 或重新渲染 `payload_template`（避免 lead 状态变化或 call_record 字段更新导致 payload 与"原触发时刻"不一致）

#### Scenario: 重试达到上限置 exhausted

- **WHEN** 重试 5xx 后 retry_count 达到 `retry_policy.max_attempts`
- **THEN** callback_log.status SHALL 置 `exhausted`（终态）；MUST NOT 再被重试调度器扫到（因 status 不再是 `pending_retry`）
