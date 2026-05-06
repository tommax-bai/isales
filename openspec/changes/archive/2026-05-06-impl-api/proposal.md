## Why

阶段 2 的 isales-api 是管理后台所有 CRUD 的归宿，按 IMPLEMENTATION_PLAN.md 阶段 2B 与 architecture / data-model / service-communication / message-contract spec 实施。本 change 交付一个可独立运行的 FastAPI 服务：JWT 签发 + 9 类资源 CRUD + WebSocket 通话事件代理 + Campaign 启停队列。前端（阶段 7）可基于本 change 完成"建任务 → 导线索 → 启动"的全流程；engine（阶段 4）通过 Redis Pub/Sub 推事件、本服务负责 WebSocket 转发给前端。

由于 engine 在阶段 4 才上线，本 change 提供一个 mock 事件 publisher 脚本（`scripts/fake_engine_events.py`），向 Redis Pub/Sub 灌假 `EngineEvent`，让 WebSocket 在阶段 2 即可独立验收。

## What Changes

- **isales-api 仓库新建**（独立 git repo，pip install isales-common >= 0.1.1，本 change 不要求 v0.1.2）
  - 仓库骨架：pyproject.toml、entry point（`isales-api`）、CI、Redis client wrapper

- **JWT 鉴权**（按 architecture spec：本服务唯一签发方）
  - `POST /auth/login`（用户名 + 密码 → JWT）；v1 仅 admin 一种角色，密码用 bcrypt 存 DB 或环境变量
  - `GET /auth/me`（拿当前用户）
  - 鉴权中间件：除 `/auth/login` / `/health` / `/docs` 外全部要 JWT
  - 密钥从 `ISALES_JWT_SECRET` 读取（与 telephony-api 共享）

- **资源 CRUD**
  - `/campaigns` CRUD（含嵌套写入 role_config / filler_set / filler_phrase / callback_config）
  - `/campaigns/{id}/devices` CRUD（campaign_device 关联，归 api 写——见 clarify-stage2-boundaries）
  - `/leads` CRUD + `POST /leads/import` 批量 CSV 导入（异步流式解析，至少支持 10w 行）
  - `/voice-models` CRUD + `GET /voice-models/{id}/sample`（返回 audio/* 流给前端试听）
  - `/holidays` CRUD（time-window spec 引用）
  - `/handoff-tasks` GET list / GET detail（v1 阶段 2 仅查询；状态流转 endpoint 留到 stage 3，因为 worker 还没起、写入路径不存在）
  - `/calls` GET list（分页 + campaign_id / lead_id / status 过滤）+ GET detail（含 transcript JSONB / recording_url）
  - `/analytics/*`：`接通率 / 目标达成率 / 通话时长分布`聚合 endpoint（v1 用 SQL group by，无独立聚合表）

- **Campaign 启停**
  - `POST /campaigns/{id}/start` → 写 `CampaignControl{action="start"}` 进 Redis 队列
  - `POST /campaigns/{id}/pause` → 同上 `action="pause"`

- **WebSocket 通话事件代理**
  - `GET /ws/calls/{campaign_id}` WebSocket endpoint（query param 带 JWT）
  - 服务端订阅 Redis Pub/Sub channel `engine:events:campaign:{id}`，反序列化 `EngineEvent`，转发给所有该 campaign_id 的连接客户端
  - 连接管理：心跳 / 优雅断开 / 多客户端订阅同一 campaign

- **mock 事件 publisher**
  - `scripts/fake_engine_events.py`：CLI 工具，参数 `--campaign-id`，按 1Hz 向 Redis Pub/Sub 灌假 `EngineEvent`（用 message-contract spec 的 schema），用于阶段 2 WebSocket 独立验收
  - 不进 production runtime，仅 dev/test

- **测试**
  - pytest + pytest-asyncio + httpx test client
  - 各 CRUD 的集成测试（testcontainers PG + Redis）
  - JWT 签发 / 验证 / 401 路径
  - WebSocket 用 mock publisher 推 3 条事件，客户端按序收到
  - Campaign start/pause 校验 Redis 队列消息内容

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `service-communication`: 新增 Requirement "API ↔ 前端 WebSocket 代理"——把现有 § 通信通道矩阵 中"engine → api Pub/Sub"的 api 侧落地形态明确为前端可订阅的 WebSocket（含鉴权、多客户端 fan-out、断开处理、v1 单实例限制、消息形状不裁剪）。这是前端与 api 的硬契约，必须在 spec 层固定。

其余对 `data-model` / `architecture` / `message-contract` 等 spec 的**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-api`（独立 git，本仓库下不放代码）
- **isales-common 依赖**：v0.1.1 即可，**不需要 bump**（last_call_at / DeviceSelectRequest 与 api 无关）
- **依赖链**：本 change 完成后，前端（阶段 7）才有可对接的管理 API；engine（阶段 4）的事件推送有了消费方
- **可与 `impl-telephony` 并行实施**：两者无运行时依赖
- **不影响**：isales-engine / isales-worker / isales-web 仓库均未启动；isales-common 不动；clarify-stage2-boundaries 归档 spec 不动
