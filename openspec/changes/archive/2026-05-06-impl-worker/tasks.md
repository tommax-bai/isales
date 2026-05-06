> 实施在 isales-worker 仓库（新建）。每组对应 1~2 个 PR，建议按顺序合入。
> 不动 isales-common（依赖 v0.1.2 即可）。

## 1. isales-worker 仓库骨架（PR #1）

- [x] 1.1 `git init isales-worker` + `.gitignore`
- [x] 1.2 `pyproject.toml`（hatchling）+ deps（isales-common>=0.1.2,<0.2、sqlalchemy[asyncio]、asyncpg、redis、httpx、pydantic、pydantic-settings、jinja2、json-logic-py、cryptography）
- [x] 1.3 dev 依赖（pytest / pytest-asyncio / ruff / mypy / types-redis）
- [x] 1.4 目录骨架（`isales_worker/{__init__,main,settings,db,redis_client,callend,summarize,callbacks,retry_loop,lead_state,metrics,llm/{__init__,mock,base}}.py` + `tests/` + `scripts/`）
- [x] 1.5 entry point `isales-worker`（`[project.scripts]`，调 `main:run`）
- [x] 1.6 `settings.py`：pydantic-settings 读 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_FERNET_KEY` / `ISALES_WORKER_LLM_PROVIDER` / `ISALES_WEBHOOK_DEFAULT_TIMEOUT_SECONDS` / `ISALES_WORKER_RETRY_TICK_INTERVAL` / `ISALES_WORKER_RETRY_BATCH_SIZE` / `TZ`
- [x] 1.7 `db.py`（async session factory）+ `redis_client.py`（async redis client wrapper）
- [x] 1.8 `main.py`：lifespan 启动 callend consumer task + retry_loop task + metrics task；优雅停机（cancel + await）
- [x] 1.9 README + CI（ruff/mypy/pytest）— CI 装 isales-common @ v0.1.2

## 2. CallEnded 队列消费 + DLQ（PR #2）

- [x] 2.1 `callend.py`：`callend_loop()` BLPOP `engine:worker:call-ended`（timeout=1s）
- [x] 2.2 用 isales-common `CallEnded` 反序列化；schema_version=1 支持，其他 → `LPUSH worker:dlq` + WARN 日志
- [x] 2.3 单条消息处理：先 fetch call_record（不存在 → ERROR 日志放弃），按顺序调 `summarize → callbacks → lead_state`
- [x] 2.4 任一阶段抛异常：ERROR 日志，**不再 retry 当前消息**（防止重复 summarize 触发 unique 冲突）；后续阶段仍尝试执行
- [x] 2.5 测试：合法 CallEnded → 三阶段函数被调；schema_version=99 → DLQ；call_record 不存在 → ERROR 日志、无三阶段调用

## 3. summarize_call（mock LLM v1）（PR #3）

- [x] 3.1 `llm/base.py`：`LLMProvider` ABC，单方法 `summarize(transcript, extraction_fields) -> SummaryResult{summary_text, extracted_fields, goal_achieved, goal_type}`
- [x] 3.2 `llm/mock.py`：MockProvider — 拼 transcript 中所有 `user_speech.text` + `bot_speech.text`，截断 200 字；`extracted_fields/goal_achieved/goal_type` 直接从 transcript 最后一轮（按 goal-achievement spec § "worker 不重复判定"）读
- [x] 3.3 `summarize.py`：`summarize_call(session, call_record_id, provider) -> CallSummary`：读 call_record + 关联 campaign（`extraction_fields`）→ provider.summarize → INSERT call_summary（unique on call_record_id；冲突时 SELECT 已有记录返回，避免重复 summary）
- [x] 3.4 测试：mock 模式输出确定性文本；transcript 含 5 轮 → goal_achieved/goal_type 取最后一轮；unique 冲突时返回已有记录

## 4. process_callbacks：trigger + payload + signing（PR #4）

- [x] 4.1 `callbacks.py`：`evaluate_trigger(trigger_jsonlogic, ctx) -> bool`：用 `json_logic` 库；任何异常视为 False（按 spec § "失败渲染" 严格写 callback_log 在外层）
- [x] 4.2 `callbacks.py`：`build_eval_context(call_record, call_summary, lead, campaign) -> dict`：按 webhook-callback spec § "trigger 可引用字段范围" 组装 `{goal_achieved, goal_type, extracted, lead, call}`，`call.hangup_cause` 从 call_record 派生
- [x] 4.3 `callbacks.py`：`render_payload(template_str, ctx) -> str`：Jinja2 `SandboxedEnvironment(undefined=StrictUndefined)`；`UndefinedError`/`SecurityError`/`TemplateSyntaxError` 包成 `RenderError`
- [x] 4.4 `callbacks.py`：`sign_request(secret, body, timestamp) -> dict[str, str]`：HMAC-SHA256(`{ts}.{body}`, secret) → headers `X-Isales-Signature: sha256=<hex>` + `X-Isales-Timestamp: <ts>` + `Content-Type: application/json`
- [x] 4.5 `callbacks.py`：`dispatch_callback(session, redis, http, callback_config, ctx, call_record_id) -> None`：trigger 不命中 → 不写 log；命中 → INSERT pending log → 渲染失败 → 改 status=failed_render；渲染成功 → HTTP（用 `signing_secret` 解密后签名）→ 按 status 分类写 log
- [x] 4.6 `callbacks.py`：`process_callbacks(session, redis, http, call_record_id) -> None`：取该 campaign 的 enabled callback_configs，`asyncio.gather` 并发 dispatch
- [x] 4.7 测试：JsonLogic 命中/不命中、Jinja2 渲染成功/StrictUndefined 抛错/SecurityError；HMAC 签名头字符串与 spec 完全一致；`signing_secret` 加密往返
- [x] 4.8 测试：HTTP 200 → success；HTTP 400 → failed_http_4xx + 不重试；HTTP 500 → pending_retry + retry_count=1 + next_retry_at；HTTP 超时 → pending_retry；连接失败 → pending_retry

## 5. callback 重试调度器（PR #5）

- [x] 5.1 `retry_loop.py`：`retry_loop(sessionmaker, redis, http, settings)` → `while True: tick(); await sleep(RETRY_TICK_INTERVAL)`
- [x] 5.2 `tick()`：`SELECT * FROM callback_log WHERE status='pending_retry' AND next_retry_at <= now ORDER BY next_retry_at ASC LIMIT BATCH_SIZE`
- [x] 5.3 每条：取 `callback_config`（含 `retry_policy`、`signing_secret`）；用 `request_body`（已存）+ 重新签名（ts 是当前；HMAC 与 body 一起算 → 重发）
- [x] 5.4 HTTP 2xx → status=success；4xx → status=failed_http_4xx（异常路径，写日志告警）；5xx/超时 → retry_count+1、判断是否达到 max_attempts：达到 → status=exhausted；否则 → status=pending_retry + next_retry_at = now + intervals[min(retry_count, len-1)]
- [x] 5.5 测试：5xx 后 retry_count 递增、间隔递进；超出 intervals 长度沿用最后一项；max_attempts 达到 → exhausted；2xx 后 → success；4xx 在重试路径上 → failed_http_4xx + 告警日志
- [x] 5.6 测试：retry_loop tick 与 process_callbacks 并发不冲突（主键更新 + 行级隔离）

## 6. update_lead_state：决策矩阵（PR #6）

- [x] 6.1 `lead_state.py`：`decide_next(call_record, call_summary, campaign, transcript) -> LeadStateUpdate{status, retry_count_delta, follow_up_count_delta, next_call_at, last_hangup_cause}`
- [x] 6.2 优先级匹配：do_not_call（goal_type='do_not_call' 或 transcript 含 do_not_call_marked 事件）> marked_for_handoff > hangup_cause 分类
- [x] 6.3 hangup_cause 分类（按 retry-followup spec）：retrying / failed / completed / following_up / follow_up_exhausted / transferred / do_not_call
- [x] 6.4 next_call_at 计算：retrying 用 `retry_intervals[min(retry_count, len-1)] * 60` 秒；following_up 用 `follow_up_interval_days * 86400`；do_not_call 设 NULL
- [x] 6.5 `lead_state.py`：`apply_lead_state(session, call_record_id) -> bool`：fetch lead + call_record + call_summary + campaign，调 decide_next；执行 `UPDATE lead SET ... WHERE id=:id AND status='calling'`；rowcount=0 → WARN 日志（race 或 lead 已 race 走过）
- [x] 6.6 测试：retry-followup spec 7 路径全覆盖（每一行决策矩阵一个 test）
- [x] 6.7 测试：do_not_call 命中时清理 next_call_at；marked_for_handoff 优先级正确；race 守卫：lead.status='new' 时 update → rowcount=0
- [x] 6.8 测试：`retry_count + 1 >= retry_max_count` 边界值（最后一次重试 vs 终态）

## 7. aggregate_metrics 定时任务（PR #7）

- [x] 7.1 `metrics.py`：`metrics_loop(sessionmaker, redis, settings)` 每 60s 跑一次
- [x] 7.2 `tick()`：聚合 7 天内每 campaign 的 `total_calls / answered_calls / goal_achieved_calls / avg_duration`
- [x] 7.3 写 Redis Hash `isales:metrics:7d:{campaign_id}`，字段 `total_calls / answered / goal_achieved / avg_duration / updated_at`
- [x] 7.4 测试：构造 30 通通话（含跨日 / 跨 campaign）→ Hash 字段正确

## 8. mock CallEnded 注入脚本（PR #8）

- [x] 8.1 `scripts/fake_call_end.py`：argparse `--db-url` `--redis-url` `--campaign-id` `--lead-id?` `--hangup-cause` `--goal-achieved` `--goal-type?` `--do-not-call?`
- [x] 8.2 可选自动建 lead（如未指定）+ call_record（含 mock transcript：1 greeting + 3 user_speech + 3 bot_speech + 1 hangup 事件，最后一轮的 bot_speech 自带 goal_achieved/goal_type）
- [x] 8.3 把 lead.status 提前置 `calling`（模拟 scheduler 已派发），便于 update_lead_state 的 row guard 通过
- [x] 8.4 `LPUSH engine:worker:call-ended` 一条 `CallEnded`
- [x] 8.5 不在 `[project.scripts]` 暴露；仅 `python -m scripts.fake_call_end`

## 9. systemd unit + 部署文档（PR #9）

- [x] 9.1 `deploy/isales-worker.service`：systemd unit + hardening flags（PrivateTmp / ProtectSystem 等）；`Restart=on-failure`；EnvironmentFile 加载共享密钥
- [x] 9.2 README 部署章节：env 表（与 isales-api 共享 `ISALES_FERNET_KEY` / PG / Redis）+ alembic upgrade（由 isales-common 包跑）+ journalctl
- [x] 9.3 IMPLEMENTATION_PLAN.md 阶段 3B 验收清单全部勾选

## 10. 收尾

- [x] 10.1 全量 pytest 全绿
- [x] 10.2 mypy / ruff 无 error
- [x] 10.3 端到端验收：用 `fake_call_end.py` 注入一条 → DB 中 `call_summary` / `callback_log` / `lead.status` 正确写入（按 IMPLEMENTATION_PLAN 阶段 3B 验收）
- [x] 10.4 主仓 commit 标记 impl-worker 实施完成；archive 由 /opsx:archive 触发
