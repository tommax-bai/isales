## Why

阶段 3A 的 isales-scheduler 是"线索分发"的归宿：把 lead 按时间窗口、节假日、并发上限、重试/跟进策略派发给 engine。按 IMPLEMENTATION_PLAN.md 阶段 3A 与 architecture / retry-followup / time-window / service-communication / message-contract spec 实施。本 change 交付一个可独立运行的 asyncio 服务：消费 `scheduler:campaign-control`、维护 active campaign 集合、主循环按规则派 lead，写 `engine:dial` 队列。

由于 engine（阶段 4）还没上线，本 change 提供一个 mock dial consumer 脚本（`scripts/fake_engine_consumer.py`），从 `engine:dial` 弹消息并校验 schema、用 stub `last_call_at` 推进 lead 状态，让 scheduler 在阶段 3 即可独立验收 1 小时不崩 + 并发数符合配置。

## What Changes

- **isales-scheduler 仓库新建**（独立 git repo，pip install isales-common >= 0.1.2）
  - 仓库骨架：pyproject.toml、entry point（`isales-scheduler`）、CI、Redis client wrapper、DB session

- **CampaignControl 消费**
  - 后台 task 阻塞 `BLPOP scheduler:campaign-control`
  - 用 isales-common `CampaignControl` discriminated union 反序列化（`StartCampaign` / `PauseCampaign` / `ResumeCampaign`）
  - 维护 active campaign 集合：Redis SET `scheduler:active-campaigns` 持久化 + 进程内 cache；启动时 `SMEMBERS` 重建 cache；start/resume → `SADD` + cache add；pause → `SREM` + cache remove（注：`Campaign` 模型在 v0.1.2 无 `status` 字段，故不走 DB）
  - 处理失败 schema_version 不支持时按 message-contract spec 走 dead letter（写日志 + 入 `scheduler:dlq` list）

- **主循环（asyncio，每 60s 一次 tick）**
  - 对 active campaign 集合中每个 campaign：
    1. **time-window 判定**（按 time-window spec）：当前是否在 `time_windows` 任一窗口内 + `respect_holidays` 命中 holiday 表 → 窗外 skip
    2. 取 leads where `campaign_id=...` 且 `status ∈ {new, retrying, following_up}` 且 `next_call_at <= now`，按 `next_call_at ASC` 限批 N 条
    3. 对每条 lead：
       a. **窗外重排**（按 time-window spec § 窗外 lead 推迟）：当前不在窗口 → 计算最近窗口起点 → 更新 `lead.next_call_at` → skip
       b. **并发上限**（按 service-communication spec § 全局并发控制）：Redis `INCR isales:concurrency:active`，超 `MAX_CONCURRENCY` → DECR 回滚 + skip（保留 lead 给下次 tick）
       c. **选号**：HTTP `POST telephony-api/devices/select` 带 `{campaign_id}` → 拿 `device_id` + `phone_number`；失败 → DECR 回滚 + skip
       d. **打包历史摘要**：查 `call_summary` 表近 N=3 次摘要（按 `lead_id`），转 `HistorySummary[]`
       e. **打包 prompt_versions 快照**：查 `role_config / prompt_version` 当前 active 版本，组 `PromptVersionsSnapshot`
       f. **构造 DialRequest**（用 isales-common Pydantic 类）+ `LPUSH engine:dial`
       g. lead 状态 → `calling`、`last_dispatched_at = now`（避免被下一 tick 重选；engine 起来后由 worker 走真实状态流转，scheduler 派后即放手）

- **lead 状态机执行边界**（按 retry-followup spec）
  - scheduler 仅推 `new/retrying/following_up → calling`（派出去）；MUST NOT 写 `completed/failed/follow_up_exhausted/do_not_call/transferred` 等终态——这些由 worker 阶段 3B 写回
  - `lead.next_call_at` 的回填（重试间隔、跟进间隔）由 worker 写回，scheduler 不算这些；scheduler 的 `next_call_at` 写回仅出现在"窗外重排"场景（推到下个窗口起点）

- **mock dial consumer**
  - `scripts/fake_engine_consumer.py`：CLI 工具，参数 `--rate-hz` `--max-messages` `--ack-mode (drop|simulate-call-end)`
  - 从 `engine:dial` BRPOP，用 isales-common `DialRequest` 反序列化校验，打印
  - `simulate-call-end` 模式：消费后 DECR Redis 并发计数器、把 lead 状态写回 `new` + 短间隔 `next_call_at`，让 1 小时不崩验收能跑出多轮派发
  - 不进 production runtime，仅 dev/test

- **测试**
  - pytest + pytest-asyncio + testcontainers (PG + Redis)
  - CampaignControl 消费：start/pause/resume 各路径 + schema_version 不兼容 → DLQ
  - 主循环：构造 mock 数据（campaign + leads + holiday + time_windows）跑一轮 tick，验证 active 派发、窗外 lead `next_call_at` 推迟、节假日 skip、并发上限到顶 skip
  - 选号：mock telephony-api（httpx MockTransport），验证 5xx 失败时 DECR 回滚、网络错误 graceful skip
  - 历史摘要打包：构造 5 条 call_summary 验证仅取近 N=3 + 顺序
  - DialRequest schema：所有必填字段通过 Pydantic validation；schema_version=1
  - 端到端：fake_engine_consumer simulate-call-end 模式跑 60s，校验 N 条 DialRequest 全部 schema 合法 + 并发计数器无泄漏

## Capabilities

### New Capabilities
无。

### Modified Capabilities

- `retry-followup`: 修改 Requirement "scheduler 调度数据流"——把 scheduler 与 worker 的"谁写 lead.status / next_call_at"边界从隐式约定提升为硬契约：scheduler 派发成功 SHALL 仅写 `status='calling'`、MUST NOT 写终态、MUST NOT 计算重试/跟进 next_call_at（worker 职责）；scheduler 仅在"窗外重排"场景下写 `next_call_at`。这是 scheduler（本 change）与 worker（阶段 3B 后续 change）并行实施的硬契约，必须在 spec 层固定。

其余对 `architecture` / `time-window` / `service-communication` / `message-contract` 等 spec 是**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-scheduler`（独立 git，本仓库下不放代码）
- **isales-common 依赖**：v0.1.2（含 `DialRequest` / `CampaignControl` / `DeviceSelectRequest` / `HistorySummary` / `PromptVersionsSnapshot`），**不需要 bump**
- **依赖链**：本 change 完成后，engine（阶段 4）有可消费的 dial 队列；api（阶段 2B 已交付）的 Campaign start/pause 有了消费方
- **可与 `impl-worker`（阶段 3B）并行实施**：两者无运行时依赖（scheduler 不读 worker 写回的 next_call_at 时仍可独立运行——靠 mock consumer 的 simulate-call-end 模式造数据）
- **不影响**：isales-engine / isales-web 仓库均未启动；isales-common 不动；isales-api / isales-telephony 已部署，本 change 仅复用其 `/devices/select` 与消费其 CampaignControl 写入
