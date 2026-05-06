## Why

阶段 3B 的 isales-worker 是"通话结束后异步处理"的归宿：消费 engine 的 `CallEnded` 队列消息，按顺序跑 `summarize_call → process_callbacks → update_lead_state`，再加一个定时 `aggregate_metrics`。本 change 交付一个可独立运行的 asyncio 服务，按 IMPLEMENTATION_PLAN.md 阶段 3B + retry-followup / webhook-callback / goal-achievement / transcript / data-model spec 实施。

由于 engine（阶段 4）还没上线，本 change 提供一个 mock CallEnded 注入脚本（`scripts/fake_call_end.py`），手工构造 call_record（含 transcript）+ lead，把 `CallEnded` 写入 `engine:worker:call-ended` 队列，让 worker 在阶段 3 即可独立验收"摘要 / 回调 / lead 状态写回 / 聚合"完整链路。

## What Changes

- **isales-worker 仓库新建**（独立 git repo，pip install isales-common >= 0.1.2）
  - 仓库骨架：pyproject.toml、entry point（`isales-worker`）、CI、Redis client wrapper、DB session

- **CallEnded 队列消费**（service-communication spec § engine→worker）
  - 后台 task 阻塞 `BLPOP engine:worker:call-ended`
  - 用 isales-common `CallEnded` 反序列化（`call_record_id` + `hangup_cause` + `ended_at`）
  - 单条消息触发完整 post-process 流水：summarize → callbacks → lead 状态写回
  - schema_version 不支持 → DLQ（`worker:dlq`）+ WARN 日志（按 message-contract spec）

- **summarize_call 任务**
  - 输入：`call_record_id`
  - 读 `call_record`（含 `transcript` JSONB + 最后一轮的 LLM 标记），engine 已经在 transcript 里写了 `goal_achieved/goal_type/extracted`（按 goal-achievement spec § Scenario "worker 不重复判定"）
  - LLM 调用生成 `summary_text`（按 `campaign.extraction_fields` 引用）
  - 写 `call_summary{call_record_id, summary_text, extracted_fields, goal_achieved, goal_type}`（unique on call_record_id 防重）
  - **v1 简化**：LLM provider 走 mock（同 engine 阶段 4 才接真）；env `ISALES_LLM_PROVIDER=mock` 时直接拼 transcript 摘要文本，不调真 LLM；env `=openai`/`=alibaba` 等留给阶段 5

- **process_callbacks 任务**（webhook-callback spec 全实施）
  - 取该 campaign 的 enabled `callback_config[]`
  - 每条评估 `trigger`（JsonLogic）：通过 → 渲染 `payload_template`（Jinja2 SandboxedEnvironment）
  - JsonLogic / Jinja2 异常 → `callback_log{status=failed_render, error_message=...}`，**不重试**
  - 渲染成功 → HTTP 调用：`X-Isales-Signature`（HMAC-SHA256）+ `X-Isales-Timestamp` + `Content-Type: application/json`，超时按 `timeout_seconds` 或全局 `ISALES_WEBHOOK_DEFAULT_TIMEOUT_SECONDS`
  - HTTP 2xx → `callback_log{status=success}`
  - HTTP 4xx → `callback_log{status=failed_http_4xx}`，**不重试**
  - HTTP 5xx / 超时 / 网络错 → `callback_log{status=failed_http_5xx | pending_retry, retry_count, next_retry_at = now + retry_policy.intervals_seconds[retry_count]}`
  - `signing_secret` 通过 isales-common `utils.crypto` 解密后 HMAC

- **callback 重试调度器**
  - 与 CallEnded 消费独立的后台 task，每分钟扫一次 `callback_log WHERE status='pending_retry' AND next_retry_at <= now`
  - 重新派发：渲染（已存的 `request_body` 复用，避免上下文漂移）→ HTTP → 同上结果分类
  - `retry_count >= retry_policy.max_attempts` → `status=exhausted`（终态）

- **update_lead_state 任务**（retry-followup spec § Requirement "scheduler 调度数据流" 5/scenario "worker 写回 lead 状态"）
  - 输入：`call_record_id`（从中拿 `lead_id` / `hangup_cause` / `goal_achieved`）
  - 按 retry-followup spec 决策矩阵写 `lead.status`：
    - `hangup_cause ∈ {no_answer, user_busy, network_out_of_order, temporary_failure}` 且 `retry_count+1 < retry_max_count` → `status=retrying`、`retry_count++`、`next_call_at = now + retry_intervals[retry_count]`
    - 同上但已达 `retry_max_count` → `status=failed`（终态）
    - `hangup_cause = call_rejected` → 不重试，`status` 看 `goal_achieved`：达成 → `completed`（这里实际不会发生因为 rejected 没接通；写 `failed` 兜底）；未达成 → `failed`
    - `hangup_cause ∈ {normal_clearing, wrap_up_completed, silence_max_reached}` 且 `goal_achieved=true` → `status=completed`
    - 同上但 `goal_achieved=false` 且 `follow_up_count+1 < follow_up_max_count` → `status=following_up`、`follow_up_count++`、`next_call_at = ended_at + follow_up_interval_days * 86400`
    - 同上但已达 `follow_up_max_count` → `status=follow_up_exhausted`
    - `hangup_cause = marked_for_handoff` → `status=transferred`
    - **勿打**：在 transcript 中检测到 `do_not_call_marked` 事件（或 `goal_type='do_not_call'`，由 engine 写入）→ `status=do_not_call`（终态），同时清理该 lead 未来的 `next_call_at`（设 NULL）
  - 必须用 `UPDATE lead SET ... WHERE id=:id AND status='calling'` 防止 worker 与 scheduler 写 race（scheduler 派发刚把 status 写成 calling，worker 才能改）

- **aggregate_metrics 定时任务**
  - 每 60s 一次：聚合 7 天内的 `接通率 / 目标达成率 / 平均通话时长`，**v1 简化**仅日志输出（spec 没强制独立聚合表，前端走 isales-api 的 `/analytics/*` 直查 SQL）
  - **保留 hook**：写到 Redis `isales:metrics:7d` Hash（前端可直读做实时大盘），key 含 campaign_id / total_calls / answered / goal_achieved
  - 这一项是 nice-to-have，主要为 v2 留口子；spec 没强制

- **mock CallEnded 注入脚本**
  - `scripts/fake_call_end.py`：CLI 工具，参数 `--db-url` `--redis-url` `--campaign-id` `--lead-id?` `--hangup-cause` `--goal-achieved`
  - 步骤：可选创建 lead 与 campaign（如未指定）、构造 call_record（含 mock transcript / `prompt_versions`）、`LPUSH engine:worker:call-ended` 一条 `CallEnded`
  - 用于阶段 3 独立验收：操作员跑此脚本，观察 worker 写 `call_summary` / `callback_log` / `lead.status`
  - 不进 production runtime

- **测试**
  - pytest + pytest-asyncio + 真 PG + 真 Redis
  - CallEnded 消费：合法消息走完整链路、schema_version=99 → DLQ
  - summarize_call：mock LLM 模式输出确定性文本、call_summary 写入正确（含 unique 防重）
  - process_callbacks：JsonLogic 命中/不命中、Jinja2 渲染、HMAC 签名头格式、HTTP 200/4xx/5xx/超时各 status 写入；signing_secret 加解密
  - 重试调度：5xx 失败后 next_retry_at 落点、达到 max_attempts 进 exhausted；4xx 不进重试
  - update_lead_state：retry-followup spec 决策矩阵 7 条路径全覆盖（含勿打、转人工、达成、跟进上限）
  - lead.status race 保护：worker 在 scheduler 还没写 calling 时尝试 update → 0 row affected + 日志 WARN
  - 端到端：fake_call_end → 完整链路 → 校验 DB 三张表

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `webhook-callback`: 修改 Requirement "重试策略：指数退避 + 最大次数"——把 worker 的"重试调度器实现"从隐式约定提升为硬契约：MUST 用独立后台 task 扫 `callback_log WHERE status='pending_retry' AND next_retry_at <= now`（频率 ≤ 1 分钟），重试时 MUST 复用上次已存的 `request_body` 而不是重新渲染（避免 trigger/payload 上下文漂移），`retry_count` 自增并比对 `retry_policy.max_attempts`。这是 worker 的 process_callbacks 与 retry_loop 之间的内部硬契约，但被前端 / 运维监控读 callback_log 时依赖（status/retry_count 字段语义稳定）。

其余对 `architecture` / `retry-followup` / `goal-achievement` / `transcript` / `webhook-callback`（除上述外）/ `data-model` / `service-communication` / `message-contract` 等 spec 是 worker 侧的**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-worker`（独立 git）
- **isales-common 依赖**：v0.1.2（含 `CallEnded` / `CallbackConfig/Log` model / `crypto.encrypt|decrypt`），**不需要 bump**
- **依赖链**：本 change 完成后，scheduler → engine → worker 链路在阶段 3 即闭环（除 engine mock 之外）；isales-api 阶段 2B 的 `/handoff-tasks` GET 在 worker 上线后会有真实数据写入（worker 可能写 handoff_task，但本 change 不实现——属 engine `marked_for_handoff` 时引擎自己写，worker 仅同步 lead.status）
- **可与 `impl-engine` 独立实施**：worker 的输入由 engine 写，但 schema 已被 message-contract spec 固化；engine 阶段 4 实施时只需保证写 `CallEnded` + transcript 即可
- **不影响**：isales-engine / isales-web 仓库均未启动；isales-common 不动；isales-api / isales-telephony / isales-scheduler 已部署，本 change 仅消费它们留下的数据
- **新环境变量**：`ISALES_WORKER_LLM_PROVIDER`（mock/openai/alibaba/...）、`ISALES_WEBHOOK_DEFAULT_TIMEOUT_SECONDS`、`ISALES_FERNET_KEY`（与 isales-api 共享，解密 signing_secret）、`ISALES_WORKER_RETRY_TICK_INTERVAL`（重试调度器 tick）
