> 实施在 isales-scheduler 仓库（新建）。每组对应 1~2 个 PR，建议按顺序合入。
> 不动 isales-common（依赖 v0.1.2 即可）。

## 1. isales-scheduler 仓库骨架（PR #1）

- [x] 1.1 `git init isales-scheduler` + `.gitignore`
- [x] 1.2 `pyproject.toml`（hatchling）+ deps（含 isales-common>=0.1.2,<0.2、httpx、redis、sqlalchemy[asyncio]、pydantic-settings）
- [x] 1.3 dev 依赖（pytest / pytest-asyncio / testcontainers / ruff / mypy）
- [x] 1.4 目录骨架（`isales_scheduler/{__init__,main,settings,db,redis_client,control,loop,time_window,concurrency,telephony,history,prompt,dispatch}.py` + `tests/` + `scripts/`）
- [x] 1.5 entry point `isales-scheduler`（`[project.scripts]`，调 `main:run`）
- [x] 1.6 `settings.py`：pydantic-settings 读 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_TELEPHONY_API_BASE` / `ISALES_SCHEDULER_TICK_INTERVAL` / `ISALES_SCHEDULER_BATCH_SIZE` / `ISALES_SCHEDULER_HISTORY_N` / `ISALES_MAX_CONCURRENCY` / `TZ`
- [x] 1.7 `db.py`（async session factory）+ `redis_client.py`（async redis client wrapper）
- [x] 1.8 `main.py`：lifespan 启动 control task + scheduler loop task；优雅停机（cancel + await）
- [x] 1.9 README + CI（ruff/mypy/pytest）— CI 装 isales-common @ v0.1.2 git tag

## 2. CampaignControl 消费 + active 集合（PR #2）

- [x] 2.1 `control.py`：`ActiveCampaigns` 类（`set[int]` cache + `asyncio.Lock` + redis client）；方法 `add(id)`（`SADD scheduler:active-campaigns` + cache）/ `remove(id)`（`SREM` + cache）/ `snapshot() -> set` / `restore_from_redis()`（`SMEMBERS` 重建 cache）
- [x] 2.2 lifespan 启动时调 `restore_from_redis()` 重建 cache（注：Campaign 模型在 v0.1.2 无 `status` 字段，active 状态仅靠 Redis SET 持久化）
- [x] 2.3 `control.py`：`control_loop()` 协程，`BLPOP scheduler:campaign-control` (timeout=1s 让 cancel 能响应)
- [x] 2.4 反序列化用 isales-common `CampaignControl` discriminated union；`StartCampaign`/`ResumeCampaign` → `add`，`PauseCampaign` → `remove`
- [x] 2.5 schema_version 不支持时 `LPUSH scheduler:dlq` + WARN 日志（按 message-contract spec § Scenario "consumer 校验 schema_version"）
- [x] 2.6 测试：start/pause/resume 各路径（真 redis testcontainer）→ Redis SET 与 cache 同步变更；启动时 Redis SET 已含 2 条 → cache 含 2；schema_version=99 的消息 → 进 DLQ；BLPOP 超时正常循环

## 3. time-window + holiday 模块（PR #3）

- [x] 3.1 `time_window.py`：`is_in_window(campaign, now) -> bool`：解析 `time_windows` JSONB array，按 weekday + start/end 判定（按 time-window spec § Campaign 级多窗口配置）
- [x] 3.2 `time_window.py`：`is_holiday(campaign, date, holiday_dates) -> bool`：`respect_holidays=true` 且 `date in holiday_dates` → True
- [x] 3.3 `time_window.py`：`next_window_start(campaign, now, holiday_dates) -> datetime`：跨日 / 跨周 / 节假日逐日推算下一个窗口起点（覆盖 time-window spec § Scenario "当日工作时段已过"/"节假日推迟到节后"/"跨周边界"）
- [x] 3.4 `time_window.py`：边界 case：`time_windows=[]` → 永远窗外；当前正好在窗口起点 / 结束时刻
- [x] 3.5 测试：4 个 Scenario 全覆盖 + 时区固定 `TZ=Asia/Shanghai`；空窗口数组返回永远窗外；跨周末跨节假日组合

## 4. 全局并发计数器（PR #4）

- [x] 4.1 `concurrency.py`：`try_increment(redis) -> bool`：原子 INCR，> MAX 时立即 DECR 并返回 False
- [x] 4.2 `concurrency.py`：`decrement(redis)`：DECR（用于失败回滚），保护下界 ≥ 0（用 Lua 或先 GET 再 DECR）
- [x] 4.3 key 名 `isales:concurrency:active`（与 architecture / DESIGN 一致）
- [x] 4.4 测试：并发 100 个 try_increment，MAX=8 时只有 8 成功；DECR 回滚后再 INCR 仍能成功；下界保护

## 5. telephony /devices/select 集成（PR #5）

- [x] 5.1 `telephony.py`：`select_device(campaign_id) -> DeviceSelectResponse | None` 用 httpx AsyncClient
- [x] 5.2 `POST {TELEPHONY_API_BASE}/devices/select` body `DeviceSelectRequest(campaign_id=...)`、超时 1s、不重试
- [x] 5.3 网络错误 / 5xx / 4xx 全部返回 None + WARN 日志（让上层决定回滚）
- [x] 5.4 测试：MockTransport 模拟成功 / 5xx / 网络错误 / 超时 / 4xx；成功路径返回正确 DeviceSelectResponse

## 6. 历史摘要 + prompt 快照打包（PR #6）

- [x] 6.1 `history.py`：`pack_history(session, lead) -> list[HistorySummary]`：仅当 `lead.follow_up_count > 0` 才查；按 `ended_at DESC LIMIT N`，转 `HistorySummary(call_record_id, summary, ended_at)`
- [x] 6.2 `prompt.py`：`pack_prompt_versions(session, campaign_id) -> PromptVersionsSnapshot`：查 role_config / prompt_version 当前 active；包含 role_llms / judge_llm / polish_llm / wrap_up_appended（默认 false，由 wrap-up 阶段 v2 启用）
- [x] 6.3 测试：5 条 call_summary → 取近 N=3；非跟进 lead 返回空 list；prompt 快照含 active role_config × prompt_version 引用

## 7. 主调度循环 + 派发（PR #7）

- [x] 7.1 `dispatch.py`：`dispatch_lead(session, redis, lead, active_campaigns, holiday_dates, settings) -> bool`，返回是否成功派发；按设计第 5/8/9 决策实现失败回滚
- [x] 7.2 步骤序：window 判定 → 窗外重排 `next_call_at` 并 return False；INCR 并发 → 选号 → 历史摘要 → prompt 快照 → DialRequest 构造 → LPUSH `engine:dial` → `UPDATE lead SET status='calling' WHERE id=...`
- [x] 7.3 任一步失败 → DECR 并发回滚（如已 INCR）→ 跳过本 lead，return False
- [x] 7.4 `loop.py`：`scheduler_loop(active_campaigns, settings)`：`while True: tick(); await asyncio.sleep(TICK_INTERVAL)`
- [x] 7.5 `tick()`：snapshot active set；查 holiday 表 `WHERE date BETWEEN today AND today+30`（缓存当日 set）；对每个 active campaign：`is_holiday` → skip；查 leads `WHERE campaign_id AND status IN (new,retrying,following_up) AND next_call_at <= now ORDER BY next_call_at ASC LIMIT BATCH_SIZE`；逐条 dispatch；任一失败 break 该 campaign 本轮
- [x] 7.6 测试：构造 mock data（2 active campaigns + 5 leads each + 1 holiday + 时窗）跑一轮：窗内派发预期数量、窗外推迟、节假日 skip、并发上限 N+1 条不派
- [x] 7.7 测试：选号失败 → DECR 回滚 + lead.status 不变；LPUSH 失败 → DECR 回滚

## 8. mock dial consumer（PR #8）

- [x] 8.1 `scripts/fake_engine_consumer.py`：argparse `--rate-hz` `--max-messages` `--ack-mode (drop|simulate-call-end)` `--redis-url` `--db-url`
- [x] 8.2 `BRPOP engine:dial`，用 `DialRequest.model_validate_json` 反序列化（schema 不合法抛错退出）
- [x] 8.3 drop 模式：仅打印；simulate-call-end 模式：DECR `isales:concurrency:active` + `UPDATE lead SET status='new', next_call_at=now+5s`（让 1 小时压测能持续派多轮）
- [x] 8.4 README dev 章节：3-terminal 流程（api / scheduler / fake_engine_consumer）+ 1 小时压测验收命令
- [x] 8.5 不在 `[project.scripts]` 暴露；仅 `python -m scripts.fake_engine_consumer`

## 9. systemd unit + 部署文档（PR #9）

- [x] 9.1 `deploy/isales-scheduler.service`：systemd unit + hardening flags（PrivateTmp / ProtectSystem 等）；`Restart=on-failure`
- [x] 9.2 README 部署章节：env 表（与 isales-api / telephony 共用 PG/Redis）+ alembic upgrade（由 isales-common 包跑）+ journalctl
- [x] 9.3 IMPLEMENTATION_PLAN.md 阶段 3A 验收清单全部勾选

## 10. 收尾

- [x] 10.1 全量 pytest 全绿
- [x] 10.2 mypy / ruff 无 error
- [ ] 10.3 1 小时不崩压测：fake_engine_consumer simulate-call-end，并发计数器无泄漏（每分钟 sample `GET isales:concurrency:active`），DialRequest 全部 schema 合法
- [x] 10.4 主仓 commit 标记 impl-scheduler 实施完成；archive 由 /opsx:archive 触发
