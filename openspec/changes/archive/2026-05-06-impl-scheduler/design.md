## Context

阶段 3A 的 isales-scheduler 实施。spec 已经在 `architecture` / `retry-followup` / `time-window` / `service-communication` / `message-contract` 中描述。impl-api（已归档）已交付 `POST /campaigns/{id}/start|pause`，把 `CampaignControl` 写到 `scheduler:campaign-control` 队列；impl-telephony（已归档）已交付 `POST /devices/select`。本 change 把这两个上游接通，并完成主循环到 `engine:dial` 队列的写入。

约束：
- Python 3.11+，与 isales-common 一致
- 全 asyncio（与 api / telephony 一致），不引入 Celery / RQ（worker 才用）
- 单实例部署（v1 单主机）；多实例分片 v2 候选
- engine 在阶段 4 才上线；本 change 必须在没有真实消费方的情况下完成主循环验收
- worker 在阶段 3B 才上线；scheduler 不能依赖 worker 写回 `next_call_at`，所以独立验收要靠 mock consumer 模拟 call-end 触发再调度

## Goals / Non-Goals

**Goals:**

- 消费 `scheduler:campaign-control` 维护 active campaign 集合，启动时从 DB 重建初始集合
- 主循环对 active campaigns 取窗口内、并发未满的 leads，调 telephony-api 选号、打包历史摘要与 prompt 快照、`LPUSH engine:dial`
- time-window 窗外 lead `next_call_at` 推迟到下个窗口起点（按 time-window spec § 窗外 lead 推迟）
- holiday 命中当日的 `respect_holidays=true` campaign 整日 skip
- Redis 全局并发计数器 INCR/DECR，选号失败 / DialRequest 构造失败时 DECR 回滚（不泄漏配额）
- DialRequest / CampaignControl 全部用 isales-common Pydantic 类构造与反序列化，schema_version 不兼容入 DLQ
- `scripts/fake_engine_consumer.py` 让 1 小时不崩验收能独立跑（含 simulate-call-end 模式）
- pytest 全绿（CampaignControl 路径 + 主循环窗内/窗外/节假日 + 选号失败回滚 + 历史摘要打包 + DLQ）

**Non-Goals:**

- 不实现 worker 写回路径（`completed/failed/follow_up_exhausted/do_not_call/transferred` 的状态流转、`next_call_at` 重试/跟进间隔计算）——阶段 3B
- 不实现 lead 状态机的终态判定（`retry_count >= retry_max_count → failed` 等）——属 worker 职责
- 不实现 prompt 版本的运行期变更监听（v1 派发时取当下 active 版本即可）
- 不实现"勿打"识别（engine + worker 阶段 3B/4 才有此通路）
- 不实现多实例分片（单实例单调度器）
- 不实现拨号回执机制（CampaignControl `LPUSH` 后立即 ACK；engine 真消费由阶段 4 验证）
- 不实现 lead 优先级 / SLA 排序（v1 仅 `next_call_at ASC`）

## Decisions

### 1. 调度循环：单 asyncio task + tick 间隔配置项

- **选择**：进程内一个 `asyncio.create_task(scheduler_loop())`，循环体 `while True: tick(); await asyncio.sleep(TICK_INTERVAL)`；TICK_INTERVAL 从环境变量读，类型为 int 秒
- **理由**：
  - retry-followup spec § 调度循环步骤明确"主循环每分钟启动"——分钟级延迟对外呼场景够用
  - 单 task 简化并发模型；多 task 对 active campaigns 并行扫描属 v2 优化
- **替代**：APScheduler / Celery beat → 多依赖、对单调度器无收益；事件驱动（lead.next_call_at 触发） → DB 触发器复杂、阻塞调度逻辑

### 2. active campaigns 集合：Redis SET + 进程内 cache

- **选择**：Redis SET `scheduler:active-campaigns`（值是 campaign_id 字符串）作为持久化真相源；进程内 `set[int]` cache；启动 lifespan 从 Redis `SMEMBERS` 重建 cache；CampaignControl 消费时同时更新 Redis SET 与进程 cache（`SADD` / `SREM` + 内存 add/remove）
- **理由**：
  - `Campaign` 模型在 isales-common v0.1.2 没有 `status` 字段；api 的 `/campaigns/{id}/start|pause` 仅 LPUSH `CampaignControl` 不写 DB——这是既有事实
  - Redis SET 让 scheduler 重启不丢 active 状态（不需要操作员重新发 Start）
  - 单实例部署，进程内 cache 避免每 tick 走 Redis；CampaignControl 实时同步两端
- **替代**：纯进程内 set 不持久化 → 重启丢 active；改 Campaign 加 status 字段 → 触及 isales-common，违反"不动 common"边界；每 tick 直查 Redis SET → 多 N×tick 次 Redis 调用

### 3. CampaignControl 消费：独立 BLPOP task + DLQ 列表

- **选择**：lifespan 里起一个 `asyncio.create_task(control_loop())` BLPOP `scheduler:campaign-control`；用 `CampaignControl` discriminated union 反序列化；schema_version 不支持 LPUSH 到 `scheduler:dlq` + WARN 日志
- **理由**：
  - message-contract spec § Scenario "consumer 校验 schema_version" 要求 dead letter 处理，MUST NOT 静默丢弃
  - 独立 task 不阻塞主循环；BLPOP 比轮询省 Redis 调用
- **替代**：主循环顺带 LPOP → tick 间隙的控制消息延迟一分钟生效，体验差；apscheduler 调度的轮询 → 同样的延迟问题

### 4. CampaignControl 类型映射

- **选择**：
  - `StartCampaign`: 加入 active 集合（DB `campaign.status` 由 api 已写，不重写）
  - `PauseCampaign`: 移出 active 集合
  - `ResumeCampaign`: 加入 active 集合（与 StartCampaign 行为相同）
- **理由**：start 与 resume 对 scheduler 等价；语义区分（start = 首次启动、resume = 暂停后恢复）由 api/前端承担，不影响调度逻辑
- **替代**：start 触发额外清理（重置 lead.next_call_at = now）→ 行为不属 scheduler 职责，应由 api 在写状态时决定

### 5. 主循环 tick：每个 campaign 独立检查 + 限批

- **选择**：每个 campaign 独立判定 time-window/holiday；窗口内 campaign 取 `LIMIT N` lead（N 是配置项）；逐条 lead 处理并发上限、选号、派发；任何一步失败就 break 该 campaign 的本轮（避免对单 campaign 死循环消耗 tick）
- **理由**：
  - 限批避免单 campaign 把 tick 耗光、其他 campaign 饿死
  - "失败即 break 本 campaign"避免选号 / DialRequest 构造连续失败时空转 N 次
- **替代**：全部 lead 一次取出后 round-robin → 复杂度高；并行 campaign 派发 → 多 telephony-api 并发请求，v1 不必要

### 6. time-window 窗外 lead：直接更新 `next_call_at`

- **选择**：`lead.next_call_at <= now` 但当前不在 campaign 任何窗口 → 计算最近窗口起点（含跨日、跨周、节假日）→ `UPDATE lead SET next_call_at = <new>`，本轮不派发
- **理由**：
  - time-window spec § 窗外 lead 推迟明确要求 scheduler 推迟而非 worker
  - 直接 UPDATE 比 lazy 计算简单；下一 tick 自然不再选中
- **替代**：内存维护 deferred 队列 → 重启丢失；让 worker 算 → 违反 spec 职责划分

### 7. 节假日命中：整日 skip 该 campaign

- **选择**：`respect_holidays=true` 的 campaign 当日命中 holiday 表 → 整日不派发；`lead.next_call_at` MAY 不更新（下一 tick 重新判定）或 SHOULD 更新到节后第一个窗口起点
- **理由**：
  - time-window spec § Scenario "节假日推迟到节后" 要求 scheduler 计算节后第一个非节假日且在窗口内的时刻
  - 选 SHOULD 更新：减少节假日期间空转 tick；节假日变更（管理员加新节假日）由下次 lead 选中时重新判定
- **替代**：lazy 不更新 → 节假日 7 天每分钟空转；标记 lead 跳过 → 复杂

### 8. 全局并发计数器：Redis INCR + key

- **选择**：key `isales:concurrency:active`（与 architecture spec / DESIGN 约定一致）；派发前 INCR，超 `MAX_CONCURRENCY` 立即 DECR + skip lead；选号失败 / DialRequest 构造失败 / LPUSH 失败任一路径 DECR 回滚
- **理由**：
  - service-communication spec § Scenario "拨号前并发计数器递增" 明确该顺序
  - 选号成功后才 DECR 风险大（成功了又因别的失败 → 占额度但没派出去）；统一"失败即回滚"清晰
- **替代**：先选号再 INCR → 选号占了 device 但没占并发，多次重排时 device 可能被别 lead 抢
- **泄漏防护**：engine 阶段 4 实施时引入 call_session TTL 兜底；本 change 不实现，但日志 WARN "concurrency rollback" 便于运维监测

### 9. 选号 HTTP 调用：httpx + 重试 + 短超时

- **选择**：复用 isales-common 的 `DeviceSelectRequest` / `DeviceSelectResponse`；`POST {TELEPHONY_API_BASE}/devices/select`；超时 < 1s（telephony-api 在 loopback，正常 ms 级）；网络错误 / 5xx → DECR 回滚 + skip lead 本轮
- **理由**：
  - architecture spec § Scenario "服务间内部调用免 JWT" + telephony-api 已确认 `/devices/select` 走内部路由免 JWT
  - 短超时：scheduler 是分钟级 tick，单条 lead 卡 30s 会拖累整批
  - 不重试：失败留给下一 tick 自然重试（lead 状态没变，仍会被下一 tick 选中）
- **替代**：长超时 + 指数退避 → 复杂、收益少；改 Redis 队列异步选号 → 与 service-communication spec § HTTP 调用规范冲突（v1 仅此一处 HTTP）

### 10. 历史摘要打包：取近 N 条 + 字段裁剪

- **选择**：跟进通话（is_follow_up=true 推断方式：lead.follow_up_count > 0 OR lead.last_completed_call_at 不为空——v1 简化用前者）才查 `call_summary`；取 lead 最近 N 条（N 是配置项），字段仅 `call_record_id / summary / ended_at`（按 isales-common `HistorySummary` 结构）
- **理由**：
  - retry-followup spec § Scenario "历史摘要由 scheduler 注入" 要求 scheduler 注入而非 engine 查
  - DialRequest 体积控制：限 N 条避免跟进次数多了 prompt 超 token（IMPLEMENTATION_PLAN.md 风险表已点名）
  - 非跟进通话不查 → 减少 DB 压力
- **替代**：把 N 设大或不限 → token 风险；call_summary 表加索引 `(lead_id, ended_at desc)` 单独查 → 已由 isales-common 模型保证 lead_id 索引

### 11. prompt_versions 快照：派发时刻取 active 版本

- **选择**：DialRequest 构造时查 `role_config / prompt_version` 取 active 版本，组 `PromptVersionsSnapshot`；查询失败 → DECR 回滚 + skip
- **理由**：
  - retry-followup spec § Requirement "scheduler 调度数据流" 步骤 6 明确"当前 prompt_versions 快照"
  - role-prompt spec 要求"快照"——派发瞬间冻结，避免通话过程中版本变更引入歧义
- **替代**：engine 自查 → 违反 spec；定时刷缓存 → v1 派发频率低、收益少

### 12. lead 派发后状态：`new/retrying/following_up → calling`

- **选择**：scheduler `LPUSH engine:dial` 成功后 `UPDATE lead SET status='calling', last_dispatched_at=now WHERE id=...`；MUST NOT 写 `completed/failed` 等终态
- **理由**：
  - retry-followup spec § Requirement "lead 状态机" 流转图
  - data-model spec：派出去后由 engine + worker 走完，scheduler 放手
  - `last_dispatched_at` 字段用于"派出但 engine 半小时还没回写"的孤儿对账（v1 不实现对账，只埋字段）
- **替代**：不更新 status → 下一 tick 重复派发同一 lead；把 status 留给 engine 写 → engine 阶段 4 才上线，scheduler 阶段 3 独立验收时 lead 永远停在 calling 影响测试

### 13. mock dial consumer：dev 脚本不进 production

- **选择**：`scripts/fake_engine_consumer.py` 是独立 CLI 脚本（`python -m scripts.fake_engine_consumer --rate-hz 1 --ack-mode simulate-call-end`），用 `DialRequest.model_validate_json` 校验，校验失败抛错；`simulate-call-end` 模式额外 DECR Redis 并发 + lead status 写回 `new` + `next_call_at = now + small_delta`
- **理由**：
  - 阶段 4 engine 上线后该脚本就废弃；进生产环境是误用
  - simulate-call-end 模式让 1 小时压测能持续派多轮，不需要手工造数据
  - 与 impl-api 的 `fake_engine_events.py` 结构对称（dev 脚本，不在 entry point 暴露）
- **替代**：scheduler 加 `/dev/dispatch-once` HTTP endpoint → 生产泄漏风险且增依赖

### 14. 不在 isales-common 加新消息类

- **选择**：`DialRequest` / `CampaignControl` / `DeviceSelectRequest` / `HistorySummary` / `PromptVersionsSnapshot` 已在 v0.1.2，本 change 不动 isales-common
- **理由**：message-contract spec 已覆盖；clarify-stage2-boundaries 归档 spec 也已确认 v0.1.2 包含本 change 所需全部 schema
- **替代**：补字段 → 没必要；要补只能开新 change

### 15. 不实现 lead.last_dispatched_at 字段（如 isales-common 未提供）

- **选择**：先验证 v0.1.2 的 lead 表是否含此字段；若无，**降级**为不记录，依赖 `lead.status='calling'` 防重派；**不**在本 change 加字段（避免 alembic 迁移与 isales-common 联动）
- **理由**：与"不动 isales-common"一致；防重派靠 status='calling' 已足够（worker 写回 status 时清理）；孤儿对账 v1 不做
- **替代**：本 change 加字段 + 改 isales-common → 属 schema 演进，应单独 change

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| scheduler 派发后 engine（阶段 4 才上线）不消费，lead 永远停在 `status='calling'`，主循环之后再也不选 | dev 期靠 `fake_engine_consumer.py` 的 simulate-call-end 模式回写 `new`；生产前 engine 必须就绪；README dev 章节明确该工作流 |
| Redis 并发计数器泄漏（scheduler 派发后 engine 崩溃没 DECR） | v1 风险接受；阶段 4 engine 实施时引入 call_session TTL + scheduler 启动清理孤儿计数（service-communication spec § Scenario "防计数器泄漏"）；本 change 仅日志 WARN 帮排查 |
| time-window 窗外 lead 推迟计算复杂（跨日 / 跨周 / 节假日）易出错 | 抽到独立模块 `scheduler/time_window.py`，按 time-window spec 的 4 个 Scenario 全覆盖单元测试 |
| holiday 命中后批量更新所有 lead.next_call_at 到节后可能锁表 | 限批：单 tick 仅更新 LIMIT N 条；下一 tick 继续；测试覆盖"节假日 + 1000 leads 单 tick 不超时" |
| CampaignControl 消费的 BLPOP task 与主循环 task 竞态修改 active 集合 | 用 `asyncio.Lock` 保护；或用单一 task 处理（每 tick 先 LPOP 累积控制消息再扫描）——倾向前者，控制消息延迟低 |
| 选号失败后 DECR 回滚但 device 已被 telephony-api 锁定 | telephony-api `/devices/select` 自带"幂等且仅返回，不锁定"语义（impl-telephony 设计）；scheduler 失败后下次 tick 重选；不存在 device 泄漏 |
| 跟进通话 prompt 超 token | 限 N 条历史；DialRequest 构造时若总长度估算超阈值 WARN 日志；硬限制留 worker 摘要二次压缩（v2） |
| schema_version 不兼容消息塞满 DLQ | DLQ 是 list，运维定期巡检 + 报警；本 change 不实现告警（属 monitoring v2） |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

部署：
1. 配 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_TELEPHONY_API_BASE`（默认 `http://127.0.0.1:8001`）/ `ISALES_SCHEDULER_TICK_INTERVAL` / `ISALES_SCHEDULER_BATCH_SIZE` / `ISALES_SCHEDULER_HISTORY_N` / `ISALES_MAX_CONCURRENCY` / `TZ=Asia/Shanghai` 环境变量
2. systemd 拉 `isales-scheduler.service`
3. 首次启动：active campaign 集合从 DB 重建；如无 active 则空转等 CampaignControl
4. 验收：用 api `POST /campaigns/{id}/start` 触发，`fake_engine_consumer.py` 在另一终端跑 simulate-call-end，观察 1 小时内并发计数器稳定 + DialRequest schema 全部合法

## Open Questions

- 主循环 tick 间隔的合适值（30s / 60s / 120s）——倾向 60s（与 retry-followup spec 描述一致），由配置项保留可调；阶段 4 端到端联调时再校准
- 历史摘要 N 的合适值（3 / 5 / 10）——倾向 3，由配置项保留可调；token 实际占用看 worker 摘要长度
- BLPOP 与主循环的同步：用 `asyncio.Lock` vs. 用单 task 串行——PR 实施时定，倾向 Lock（控制消息生效快）
- 节假日命中后 `lead.next_call_at` 是否真要批量更新到节后——决策 7 选了"批量更新"；如果生产观察到锁表问题，回退到 lazy 不更新（下一 tick 重新判定，多空转几次但简单）；本 change 实现批量更新即可
- v0.1.2 isales-common 是否含 `lead.last_dispatched_at` 字段——PR #1 实施时查证；若无，按决策 15 降级
