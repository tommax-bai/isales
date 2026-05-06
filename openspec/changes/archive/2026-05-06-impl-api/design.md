## Context

阶段 2 的 isales-api 实施。spec 已经在 `architecture` / `data-model` / `service-communication` / `message-contract` / 各业务 capability spec 中描述。clarify-stage2-boundaries（已归档）确立了 JWT 共享体系（本服务唯一签发方）、campaign_device 归属本服务（嵌套写入合规）、`/handoff-tasks` GET 在阶段 2 即可上线。

约束：
- Python 3.11+，与 isales-common 一致
- FastAPI + 异步全栈
- 单实例部署（v1 单主机；多实例 v2 候选）——影响 WebSocket 连接管理决策
- engine 在阶段 4 才上线；本 change 必须在没有真实事件的情况下完成 WebSocket 验收

## Goals / Non-Goals

**Goals:**

- 完成 9 类资源 CRUD 与 `/auth/login` 签发 JWT，OpenAPI 文档自动可访问
- WebSocket `/ws/calls/{campaign_id}` 能订阅 Redis Pub/Sub，转发 `EngineEvent`
- `scripts/fake_engine_events.py` mock publisher 在 1Hz 推假事件，WS 客户端按序收到
- `POST /campaigns/{id}/start` `POST /campaigns/{id}/pause` 写 `CampaignControl` 进 Redis 队列，消息体合法（用 isales-common 的 Pydantic 类）
- pytest 全绿（CRUD 集成测试 + JWT 路径 + WebSocket 端到端）

**Non-Goals:**

- 不实现多角色权限模型（v1 仅 admin）
- 不实现 Campaign 启停的回执机制（scheduler 阶段 3 才能消费 CampaignControl）
- 不实现 handoff_task 的状态流转 endpoint（worker 阶段 3 才创建 handoff_task）
- 不实现 WebSocket 多实例广播（单实例够用）
- 不实现 analytics 的复杂图表数据（v1 仅基础聚合）
- 不实现 voice_model 的真实试听音频上传——v1 仅返回 `sample_url`，前端从对象存储拉

## Decisions

### 1. JWT：HS256 + 24h 过期 + 无刷新 token

- **选择**：`POST /auth/login` 签发 HS256 JWT，`exp = now + 24h`；过期后用户重新登录，无 refresh endpoint
- **理由**：
  - architecture spec 已要求 HMAC + `ISALES_JWT_SECRET` 环境变量
  - v1 admin 数量少、操作时长短，24h 够用
  - 不做 refresh 减少状态管理（黑名单 / 滑动过期等都省了）
- **替代**：RS256（公私钥）→ 多了密钥分发复杂度；refresh token → 多端实现复杂度；暂留 v2 演进

### 2. WebSocket 鉴权：query param 传 JWT

- **选择**：客户端连接 `wss://.../ws/calls/{campaign_id}?token=<JWT>`；服务端 accept 前验证；token 失效返回 4401 close code
- **理由**：浏览器 WebSocket API 不支持自定义 header；query param 是 WS 鉴权的实践标准
- **替代**：接受连接后等第一条消息带 token → 多一跳延迟，且未鉴权连接占资源

### 3. WebSocket 连接管理：进程内 dict + asyncio.Queue

- **选择**：每 campaign_id 一个 `Set[WebSocket]`；后台一个 asyncio task 订阅 Redis Pub/Sub channel `engine:events:campaign:{id}`，收到消息后 fan-out 给该 set 的所有连接
- **理由**：
  - v1 单实例，进程内 dict 够用
  - asyncio.Queue 解耦订阅者与转发者，断线不会阻塞 Redis subscribe
- **替代**：每个 WS 连接独立订阅 Redis → 多个客户端订阅同一 campaign 时 Redis 连接数膨胀；多实例下要换成 sticky session 或 Redis Streams（v2）

### 4. Campaign 嵌套写入：单事务 + 全量替换 children

- **选择**：`POST/PATCH /campaigns` 接受嵌套结构（role_config / filler_set / callback_config）；服务端在一个事务内 upsert campaign + 全量替换 children（先 delete 再 insert）；任何子项失败整个事务回滚
- **理由**：
  - 全量替换比 diff merge 简单 N 倍；前端拿到 GET 响应改完直接 PATCH 整体即可
  - 单事务保证一致性（避免 campaign 有但 role_config 缺的中间态）
- **替代**：每个子资源独立 endpoint → 前端要做编排，体验差；diff merge → 服务端复杂

### 5. CSV 批量导入：流式解析 + 错误报告 200 OK

- **选择**：`POST /leads/import`（multipart）流式解析；遇到非法行（缺字段/号码格式错）跳过该行，记录到响应体的 `errors: [{row, message}]`；HTTP 200 + 部分成功；超过 N% 错误率才 400
- **理由**：
  - 大文件 100% 严格 → 用户体验差（一行错全军覆没）
  - 流式解析避免大文件 OOM
- **替代**：全失败模式 → 用户痛苦；异步任务模式 → v1 不必要复杂

### 6. analytics：用 SQLAlchemy + 视图风格 SQL，不预聚合

- **选择**：`/analytics/answer-rate` `/analytics/goal-rate` `/analytics/duration-distribution` 各一个 endpoint；服务端用 SQLAlchemy core 写聚合 SQL；不引入物化视图 / 预聚合表
- **理由**：v1 数据量级（≤8 路并发，每天通话数千通）单表查询毫秒级返回；预聚合是 v2 优化项
- **替代**：worker 定时聚合到 analytics 表 → 写入维护成本 + 数据延迟

### 7. mock 事件 publisher：dev 脚本不进 production

- **选择**：`scripts/fake_engine_events.py` 是独立 CLI 脚本（`python -m scripts.fake_engine_events --campaign-id 1`），用 isales-common 的 `EngineEvent` 类构造合法消息，1Hz 写 Redis Pub/Sub；不在 isales-api 的 entry point 暴露
- **理由**：阶段 4 engine 上线后该脚本就废弃；进生产环境是误用，明确隔离
- **替代**：API 加 `/dev/publish-event` endpoint → 生产泄漏风险

### 8. 不在 isales-common 实现 JWT 签发

- **选择**：JWT 签发逻辑在 isales-api 仓库的 `auth/jwt.py`；isales-common 仅提供 `verify_jwt`（与 telephony-api 共用）
- **理由**：架构 spec § "JWT 配置不属于 isales-common 业务范围" 明确禁止 common 持签发能力
- **替代**：在 common 提供签发函数 → 违反 spec

### 9. Campaign 启停 → CampaignControl 消息

- **选择**：用 isales-common 的 `CampaignControl` Pydantic 类构造消息（按 message-contract spec），写 Redis 队列 `scheduler:campaign-control`
- **理由**：message-contract spec 已定义此消息类，本 change 仅消费它
- **替代**：直接在 api 写自定义 dict → 违反 message-contract spec

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| WebSocket 在 isales-api 中长连接占用 worker 进程；FastAPI + uvicorn 默认 worker 数有限 | 部署用 uvicorn `--workers 1` 配 `--ws auto`；高并发 WS 客户端 ≤ 几十路即可（仅监控用，不是用户连接）|
| Campaign 嵌套写入的全量替换会触发外键瀑布（filler_phrase 跟着 filler_set 删） | DB 上 `ON DELETE CASCADE`；事务保证一致；测试覆盖"删除 campaign 时所有子表清空" |
| mock fake_engine_events.py 与真实 engine 输出 schema 不一致 | publisher 强制用 isales-common 的 `EngineEvent` 类，schema_version 由基类管理；任何不兼容会在 publisher 启动时 ValidationError |
| handoff_task GET 在阶段 2 永远返回空列表，前端可能误以为坏了 | OpenAPI 文档加 description 标注"v1 阶段 2 此列表为空，待 worker stage 3 上线后写入"；前端不展示空状态特殊提示 |
| CSV 导入 10w 行单事务可能超时 / 锁表 | 流式分批 commit（每 1000 行一个事务）；测试覆盖 10w 行场景的耗时与连接占用 |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

部署：
1. 配 `ISALES_JWT_SECRET` / `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` 环境变量（与 telephony-api 共用同一 PG/Redis/JWT 密钥）
2. systemd 拉 `isales-api.service`
3. `/auth/login` 签发第一个 admin token，前端用此 token 跑通

## Open Questions

- WebSocket 鉴权失败的 close code 用 4401（自定义）还是 1008（policy violation）——倾向 4401 让前端区分鉴权失败与协议失败；待 PR 实施时定
- analytics endpoint 的时间窗口语义（默认查多久？）——倾向最近 7 天，可被 query param 覆盖；阶段 7 前端展示时再校准
- handoff_task GET 是否要支持 `?status=pending` 过滤——倾向支持，前端阶段 7 会用；本 change 实现成本低
