## Context

阶段 3B 的 isales-worker 实施。spec 已经在 `architecture` / `retry-followup` / `webhook-callback` / `goal-achievement` / `transcript` / `service-communication` / `message-contract` / `data-model` 中描述。impl-scheduler（已归档）提供了上游：scheduler 派发后写 `lead.status='calling'`，等 worker 在通话结束后接管 lead 状态流转。impl-api（已归档）的 `/analytics/*` 不依赖独立聚合表，所以 `aggregate_metrics` 可以做轻。

约束：
- Python 3.11+，与 isales-common / api / scheduler 一致
- 全 asyncio（与 api / scheduler 一致），不引入 Celery / RQ——v1 用 Redis BLPOP + 后台 task 即可（IMPLEMENTATION_PLAN.md 提了 Celery 但我们已在前几个服务统一用 asyncio）
- 单实例部署（v1 单主机）；多实例 worker v2 候选
- engine 在阶段 4 才上线；本 change 必须能用 mock CallEnded 注入脚本独立验收
- 不动 isales-common（v0.1.2 已含全部需要的 model / schema / crypto）

## Goals / Non-Goals

**Goals:**

- 消费 `engine:worker:call-ended` 队列，按 `summarize_call → process_callbacks → update_lead_state` 顺序串行（webhook-callback spec § Scenario "summarize_call 完成后派发"）
- callback 全套实施：JsonLogic trigger / Jinja2 sandbox payload / HMAC-SHA256 签名 / 指数退避重试 / 4xx vs 5xx 区分 / failed_render 不重试
- callback 重试调度器（独立 task），按 `next_retry_at` 扫 `pending_retry` 重试
- update_lead_state 覆盖 retry-followup spec lead 状态机全部转移路径
- update_lead_state 防止与 scheduler 写 race（用 `WHERE status='calling'` 守卫）
- mock LLM provider（v1）+ 真 LLM 接入留口子
- `scripts/fake_call_end.py` 让阶段 3 独立验收
- pytest 全绿（CallEnded 路径 + summarize + callback 全状态 + 重试调度 + lead 状态机 7 路径 + race 保护 + 端到端）

**Non-Goals:**

- 不实现真 LLM provider 实现（mock 模式即可，真 provider 与 engine 阶段 5 一并实施）
- 不实现独立 analytics 聚合表（v1 用 isales-api `/analytics/*` SQL 直查；worker 仅 Redis Hash 留 hook）
- 不实现 worker 多实例分片（单实例够，v2 候选）
- 不实现 handoff_task 写入（engine `marked_for_handoff` 时由 engine 在挂断时写，worker 仅同步 lead.status；worker 不创建 handoff_task）
- 不实现 webhook 接收方校验工具（spec § Scenario "接收方验证（推荐）" 是给业务方做参考的，worker 端不需要）
- 不实现回调编排 DAG（每个 callback_config 独立处理，互相不依赖）
- 不实现勿打识别本身（engine 在通话期间识别并写 transcript / `goal_type='do_not_call'` 等，worker 只是读到后写 lead.status）

## Decisions

### 1. 不引入 Celery；用 asyncio + Redis BLPOP

- **选择**：所有任务都是同进程内的 async 函数；CallEnded 消费用一个 BLPOP loop；callback 重试用一个 sleep tick loop
- **理由**：
  - 与 api / scheduler 一致；引入 Celery 多一层 broker 协议、序列化方案、worker 进程管理，单实例下没有收益
  - 任务流是顺序串行（summarize → callbacks → lead state），不存在大规模并行需求
  - IMPLEMENTATION_PLAN 提的 Celery 是初期估算时的默认方案，当前栈已经全 asyncio 化
- **替代**：Celery → 多依赖、调试难；APScheduler → 仅给重试用收益小

### 2. CallEnded 消费 + 任务串行：单条消息走完整链路

- **选择**：单 BLPOP task 消费 CallEnded，每条消息内部 `await summarize → await process_callbacks → await update_lead_state`，全部成功后才 ack（即 BLPOP 已经 pop 出来，不需显式 ack）
- **理由**：
  - webhook-callback spec § "summarize_call 完成后派发" 要求顺序
  - retry-followup spec lead 状态机要求 worker 在 callback 之后写 status，因为 do_not_call 命中要清理未来调度
  - 如果中间 step 失败：异常 → 写 ERROR 日志 → 不再 retry 当前消息（避免无限循环），但 callback 重试调度器仍能独立处理 pending_retry 的 callback
- **替代**：
  - 三个独立 task 并行 → callback 可能在 lead.status 写完前评估 trigger，看到的字段不一致
  - 失败重新 LPUSH → 容易把同一 call_record_id 重复 summarize（触发 unique 冲突）；当前选择是"失败即放弃，告警靠日志"

### 3. summarize_call：v1 mock LLM provider

- **选择**：env `ISALES_WORKER_LLM_PROVIDER=mock`（默认）→ summarize 直接拼 transcript 中的 `user_speech` + `bot_speech` 文本生成简单摘要；`extracted_fields` 与 `goal_achieved` / `goal_type` 直接从 transcript 最后一轮（engine 已写）复制
- **理由**：
  - goal-achievement spec § "worker 不重复判定" 明确禁止 worker 触发独立判定 LLM；engine 已写好结构化字段
  - mock provider 让本 change 完全脱离阶段 5 LLM 真接入
  - 真 provider 加在 `worker/providers/llm/` 子目录，与 engine 阶段 5 的 provider 抽象对齐（共用 isales-common 的 ABC）
- **替代**：直接调真 LLM → 阶段 3 验收必须有 LLM key，加部署门槛

### 4. process_callbacks：每条 callback_config 独立 callback_log

- **选择**：trigger 命中即先 INSERT `callback_log{status=pending, request_body=null}`，然后渲染、签名、HTTP；trigger 不命中**不写日志**（避免 callback_log 灌爆）
- **理由**：
  - spec 没强制不命中要写日志；写日志会让 v1 数千通通话 × N 个 callback 配置爆 callback_log 表
  - 命中即写 pending 让运维巡检 `WHERE status IN (pending, pending_retry)` 看在途
- **替代**：所有评估都写 → 表膨胀；都不写 → 失败排查难

### 5. JsonLogic：用 `json-logic-py` 库；字段范围按 spec 全覆盖

- **选择**：deps 加 `json-logic-py`；评估上下文 dict 按 webhook-callback spec § "trigger 可引用字段范围" 组装：`{goal_achieved, goal_type, extracted, lead, call}`，其中 `lead.custom_data` 平铺为 `lead.custom_data.*` 通过 `var: "lead.custom_data.x"` 访问
- **理由**：
  - 用现成库稳定（自维护一套 DSL 评估代价大）
  - 字段范围是硬契约，构造 ctx 时严格按 spec 顺序，遗漏一个就会让 trigger 失效
- **替代**：jsonpath / py-pratt / 自写解析器 → 都是不必要的复杂

### 6. Jinja2 sandbox：StrictUndefined + 渲染失败标 failed_render

- **选择**：`SandboxedEnvironment(undefined=StrictUndefined)` 渲染 `payload_template`；`UndefinedError` / `SecurityError` / `TemplateSyntaxError` 任一 → `callback_log{status=failed_render, error_message=str(exc), request_body=None}`，**不重试**
- **理由**：
  - StrictUndefined 让"引用不存在字段"立即报错，防止偷偷渲染出 `{"x": ""}` 这种半成品 payload 发到第三方
  - spec § "失败渲染的处理" 明确不重试 + 写 error_message
- **替代**：默认 Undefined（输出空串）→ 静默错误，运维查不到

### 7. HMAC 签名：常量时间安全；`signing_secret` 解密在评估时

- **选择**：每次发请求时从 `callback_config.signing_secret` 通过 `isales_common.utils.crypto.decrypt(...)` 解密拿明文；用 `hmac.new(secret.encode(), msg=f"{ts}.{body}".encode(), digestmod=hashlib.sha256).hexdigest()` 算签；header 写 `X-Isales-Signature: sha256=<hex>` + `X-Isales-Timestamp: <unix>`
- **理由**：
  - spec § "签名内容" 明确格式
  - 不在 worker 启动时一次性解密所有 secret 缓存到内存——明文暴露时间窗最小化
- **替代**：缓存解密结果 → 性能微提升，安全风险大

### 8. 重试调度器：独立 task + 每 60s 扫一次

- **选择**：独立后台 task `retry_loop`，`while True: tick(); await sleep(RETRY_TICK_INTERVAL)`；tick 取 `SELECT * FROM callback_log WHERE status='pending_retry' AND next_retry_at <= now LIMIT N ORDER BY next_retry_at`，每条重新 HTTP（**复用 request_body**，不重渲染）；2xx → success，5xx/超时 → `retry_count++`、`next_retry_at = now + intervals[retry_count]`，达到 max_attempts → exhausted；4xx → 转成 `failed_http_4xx`（虽然 spec 说 4xx 不重试，进 retry_loop 又被 4xx 是异常态，但作为安全网处理）
- **理由**：
  - spec § "触发重试的错误" + § "超出数组长度" 全在 retry_loop 实现
  - 复用 request_body：spec 没明文要求，但 trigger 可能引用"评估时刻的 lead.status"，重试时 lead 状态可能已变（如已转 do_not_call），重新评估会触发"不命中"或不同 payload，违反"原触发瞬间的事实"原则
- **替代**：每次重试重新评估 → 如上，会引入语义不一致

### 9. update_lead_state：决策矩阵 + 行级守卫

- **选择**：用 SQL `UPDATE lead SET status=:new_status, retry_count=:rc, follow_up_count=:fc, next_call_at=:nca, last_hangup_cause=:hc WHERE id=:lead_id AND status='calling'`；rowcount=0 时记 WARN 日志（说明 scheduler 还没派 / 已被别的 worker 写过，无害）
- **理由**：
  - retry-followup spec § lead 状态机要求只有 `new/retrying/following_up → calling` 后 worker 才接手；行级守卫让 worker 不会改一个不属于它的 lead
  - rowcount=0 不抛错：阶段 3 mock 注入 + 阶段 4 engine 真上线时存在边界情况（手工注入的 lead 可能跳过 `calling` 步骤）
- **替代**：CAS 用乐观锁 `version` 字段 → isales-common 没这字段；需 schema 演进

### 10. 决策矩阵：7 条路径

按 retry-followup spec 严格落地，写在 `worker/lead_state.py:decide_next(call_record, call_summary, campaign) -> LeadStateUpdate`：

| 输入 | 输出 status | 输出字段 |
|---|---|---|
| `hangup_cause ∈ {no_answer, user_busy, network_out_of_order, temporary_failure}` 且 `retry_count + 1 < retry_max_count` | `retrying` | `retry_count++`, `next_call_at = now + retry_intervals[min(retry_count, len-1)] * 60` |
| 同上但 `retry_count + 1 >= retry_max_count` | `failed` | `retry_count++` |
| `hangup_cause = call_rejected` | `failed` | — |
| `hangup_cause ∈ {normal_clearing, wrap_up_completed, silence_max_reached, user_hangup}` 且 `goal_achieved=true` | `completed` | — |
| 同上但 `goal_achieved=false` 且 `follow_up_count + 1 < follow_up_max_count`（且 `follow_up_max_count > 0`） | `following_up` | `follow_up_count++`, `next_call_at = ended_at + follow_up_interval_days * 86400` |
| 同上但 `follow_up_max_count == 0` 或 `follow_up_count + 1 >= follow_up_max_count` | `follow_up_exhausted` | — |
| `hangup_cause = marked_for_handoff` | `transferred` | — |
| `goal_type = "do_not_call"` 或 transcript 含 `do_not_call_marked` 事件 | `do_not_call` | `next_call_at = NULL` |

按优先级匹配（do_not_call 最高，覆盖其他规则；marked_for_handoff 其次；hangup_cause 其余分类）

### 11. callback log 与 lead state 的事务性

- **选择**：`process_callbacks` 与 `update_lead_state` **不在同一事务**；callback_log 提交后再开新 session 写 lead——webhook-callback spec § "webhook 失败不影响 lead 状态" 已明确 webhook 是 eventually consistent，没必要绑定到 lead 事务
- **理由**：lead.status 写入是关键路径；callback HTTP 调用是慢路径（可能秒级），同事务会持锁太久
- **替代**：单事务 → 如上，性能差；两阶段 commit → v1 不需要

### 12. aggregate_metrics：仅 Redis Hash 写法（v1 简化）

- **选择**：每 60s 一次定时 task：跑两条 SQL（接通率、目标达成率），结果 HSET 到 `isales:metrics:7d:{campaign_id}` Hash；这是 nice-to-have，spec 没强制
- **理由**：前端阶段 7 大盘可读 Redis 直出（毫秒级响应）；不读时无影响；不与 isales-api `/analytics/*` 冲突（那个走 SQL 直查，是真相源）
- **替代**：不实现 → 简单但错失实时大盘的口子；写聚合表 → 引入 schema 演进

### 13. mock CallEnded 注入：dev 脚本不进 production

- **选择**：`scripts/fake_call_end.py` 是独立 CLI 脚本（`python -m scripts.fake_call_end --campaign-id 1 --hangup-cause normal_clearing --goal-achieved true`）；用 isales-common `CallEnded` 类构造合法消息；可选自动建 lead / call_record（含 mock transcript）；`LPUSH engine:worker:call-ended`
- **理由**：与 scheduler 的 `fake_engine_consumer.py` / api 的 `fake_engine_events.py` 对称；阶段 4 engine 上线后该脚本就废弃
- **替代**：worker 加 `/dev/inject-end` HTTP endpoint → 生产泄漏风险

### 14. 队列名约定

- `engine:worker:call-ended`：engine → worker，CallEnded 消息（与 service-communication spec 通道矩阵一致）
- `worker:dlq`：schema_version 不支持 / 反序列化失败的死信
- 不引入额外队列；callback 不走队列（直接 SQL 选 + HTTP）

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| summarize_call 失败（mock 也可能 transcript 缺字段）会卡住后续 callbacks 与 lead state | 用 try/except 包 summarize：异常 → ERROR 日志，**仍继续** callback + lead state（用上次 transcript 直读最后一轮的标记字段；call_summary 留空）；保证 lead 状态流转不被卡 |
| callback HTTP 慢（业务方 30s 才响应）拖慢 CallEnded 处理速度 | 单 worker 实例 + 单消费 task 是瓶颈；v1 通话量级（≤8 路并发，每天数千通）够用；多 callback 并发用 `asyncio.gather` 做并行（每个 callback_config 一个 task）— 但 spec 没强制顺序，单消息内并行安全 |
| `signing_secret` 加解密用的 `ISALES_FERNET_KEY` 与 isales-api 不一致 → 解密失败 | 部署时强制 `ISALES_FERNET_KEY` 全局共享（写 README + systemd EnvironmentFile）；解密失败 → `failed_render` 入 callback_log（运维一眼看出） |
| update_lead_state 与 scheduler 写 race（极低概率，但理论存在） | 用 `WHERE status='calling'` 行级守卫；rowcount=0 仅 WARN 不抛错 |
| 决策矩阵 7 条路径覆盖不全（如 `goal_type='do_not_call'` + `hangup_cause='no_answer'` 怎么处理） | 优先级：do_not_call > marked_for_handoff > 其他；测试覆盖矩阵交叉 case；spec 默认未覆盖的 hangup_cause 走 `failed` 兜底 |
| callback_log 表膨胀（每通通话 × N callback × M 重试） | spec 没强制清理；v2 加分区 + TTL；本 change 不实现 |
| Jinja2 sandbox 默认环境过严，业务方常用 filter（如 `tojson` `default`）被禁 | 实测 `tojson` 在 sandbox 下能用；`default` 同；如有需要再 `globals` 注入；测试覆盖典型模板 |
| 重试调度器 task 与 BLPOP task 的并发写 callback_log 冲突 | 通过 `WHERE id=:id` 主键更新避免；不会有冲突 |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

部署：
1. 配 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_FERNET_KEY`（与 isales-api 共用同一密钥，否则解密 signing_secret 失败）/ `ISALES_WORKER_LLM_PROVIDER=mock` / `ISALES_WEBHOOK_DEFAULT_TIMEOUT_SECONDS=10` / `ISALES_WORKER_RETRY_TICK_INTERVAL=60` / `TZ=Asia/Shanghai`
2. systemd 拉 `isales-worker.service`
3. 验收：用 `python -m scripts.fake_call_end --campaign-id <id> --hangup-cause normal_clearing --goal-achieved true` 注入一条；观察 `call_summary` / `callback_log` / `lead.status` 三张表的写入

## Open Questions

- summarize_call 失败的处理粒度：异常时是"仍继续"还是"整条消息放弃"？倾向"仍继续 + ERROR 日志 + call_summary 留 NULL summary_text"（决策已写）；阶段 5 接真 LLM 时再校准
- callback 顺序：多个 callback_config 命中时是 `asyncio.gather` 并行还是顺序？倾向并行（单消息内的并行安全）；如出现 rate-limit 问题再加并发上限
- 重试调度器扫描频率（30s / 60s / 120s）——倾向 60s（与 scheduler tick 一致），由配置项保留
- aggregate_metrics 是否真做：本 change 实现 Redis Hash 写入（决策 12），如阶段 7 前端不需要可后续删除
- `marked_for_handoff` 时 worker 是否要写 handoff_task：本 change 决策"不写，由 engine 写"——但 engine 阶段 4 才上线；阶段 3 mock 注入 marked_for_handoff 时不需要 handoff_task 实体，仅 lead.status 写 transferred
- LLM provider mock 实现的"摘要"是否够测试用：纯 transcript 拼接 → 测试可用；阶段 5 切真 provider 时升级
- 决策矩阵 v0.1.2 没有 `lead.last_hangup_cause` 字段——已确认存在（见 Lead model line 40）；OK
