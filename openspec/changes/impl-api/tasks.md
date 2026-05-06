> 实施在 isales-api 仓库（新建）。每组对应 1~2 个 PR，建议按顺序合入。
> 不动 isales-common（依赖 v0.1.1 即可）。

## 1. isales-api 仓库骨架（PR #1）

- [ ] 1.1 `git init isales-api` + `.gitignore`（Python + venv + .env + uploaded CSVs）
- [ ] 1.2 `pyproject.toml`（hatchling）：依赖 `fastapi`、`uvicorn[standard]`、`sqlalchemy[asyncio]`、`asyncpg`、`alembic`、`redis>=5`、`python-jose[cryptography]`（JWT 签发）、`bcrypt`、`isales-common>=0.1.1,<0.2`
- [ ] 1.3 dev 依赖：`pytest`、`pytest-asyncio`、`httpx`、`testcontainers[postgres]`、`ruff`、`mypy`
- [ ] 1.4 目录：`isales_api/{routers,auth,ws,common}/__init__.py` + `tests/` + `scripts/`
- [ ] 1.5 entry point：`isales-api = "isales_api.main:run"`
- [ ] 1.6 `common/db.py` async session factory；`common/redis.py` wrap isales-common client factory
- [ ] 1.7 `main.py`：FastAPI app + `/health` + `/docs` + JWT 中间件挂载顺序
- [ ] 1.8 README + GitHub Actions CI（ruff / mypy / pytest）

## 2. JWT 签发与鉴权（PR #2）

- [ ] 2.1 `auth/users.py`：admin 用户存储（v1 简化为环境变量 `ISALES_ADMIN_USER` / `ISALES_ADMIN_PASSWORD_HASH`，bcrypt hash）
- [ ] 2.2 `auth/jwt.py`：`sign_jwt(payload) -> str`，HS256，exp=24h；密钥从 `ISALES_JWT_SECRET` 读
- [ ] 2.3 `auth/router.py`：`POST /auth/login`（用户名+密码 → JWT）、`GET /auth/me`（解析当前 user）
- [ ] 2.4 鉴权 dependency：依赖 isales-common `verify_jwt`；错误响应 401
- [ ] 2.5 测试：login 成功 / 密码错 / token 过期 / 缺 token 各路径

## 3. campaigns CRUD（含嵌套）（PR #3）

- [ ] 3.1 `routers/campaigns.py`：GET list（分页 + status 过滤）/ GET detail / POST / PATCH / DELETE
- [ ] 3.2 嵌套 schema：CampaignCreate 含 `role_configs: List[RoleConfigCreate]` / `filler_sets: List[FillerSetCreate]` / `callback_configs: List[CallbackConfigCreate]`
- [ ] 3.3 嵌套写入：单事务，先 upsert campaign，再全量替换 children（DELETE WHERE campaign_id + INSERT）
- [ ] 3.4 DB 上配置 `ON DELETE CASCADE`（filler_phrase 跟 filler_set 删等），通过 alembic 迁移加（如 isales-common 没配则在本 change 落 alembic 增量到 isales-common；如已配则跳过）
- [ ] 3.5 集成测试：POST 嵌套结构 → GET 校验完整 → PATCH 全量替换 → DELETE 级联清空所有 children
- [ ] 3.6 `routers/campaigns.py`：`POST /campaigns/{id}/devices` 增删 campaign_device 关联（按 clarify-stage2 归属调整后 api 直写）

## 4. leads / voice_models / holidays / handoff_tasks（PR #4）

- [ ] 4.1 `routers/leads.py`：CRUD（GET list 分页 + status / campaign_id 过滤）
- [ ] 4.2 `routers/leads.py`：`POST /leads/import`（multipart CSV）流式分批 commit（每 1000 行一事务），返回 `{success_count, errors: [{row, message}]}`，HTTP 200 部分成功
- [ ] 4.3 测试：10w 行 CSV 测试耗时与正确性；含错误行的 CSV 测试 errors 报告
- [ ] 4.4 `routers/voice_models.py`：CRUD + `GET /voice-models/{id}/sample` 流式返回 `audio/*`（实际从 `sample_url` 拉取转发）
- [ ] 4.5 `routers/holidays.py`：CRUD（time-window spec 引用）
- [ ] 4.6 `routers/handoff_tasks.py`：仅 GET list（带 status 过滤）+ GET detail（含 transcript）；状态流转 endpoint 返回 501 Not Implemented + 注释指向 stage 3

## 5. calls 查询 + analytics（PR #5）

- [ ] 5.1 `routers/calls.py`：GET list（分页 + campaign_id / lead_id / status 过滤），返回 summary 字段
- [ ] 5.2 `routers/calls.py`：GET detail（含 transcript JSONB / recording_url / pipeline_trace 引用）
- [ ] 5.3 `routers/analytics.py`：`/analytics/answer-rate`（接通率）、`/analytics/goal-rate`（目标达成率）、`/analytics/duration-distribution`（通话时长分布桶）
- [ ] 5.4 各 analytics endpoint 用 SQLAlchemy core 写聚合 SQL；query param `?since=&until=` 默认最近 7 天
- [ ] 5.5 测试：插假数据，断言聚合结果数值

## 6. Campaign 启停 + 消息发布（PR #6）

- [ ] 6.1 `routers/campaigns.py`：`POST /campaigns/{id}/start` / `POST /campaigns/{id}/pause`
- [ ] 6.2 用 isales-common `CampaignControl`（按 message-contract spec）构造消息 + `redis.lpush("scheduler:campaign-control", msg.model_dump_json())`
- [ ] 6.3 测试：start/pause 后从 Redis 队列读出消息，反序列化校验字段

## 7. WebSocket 通话事件代理（PR #7）

- [ ] 7.1 `ws/manager.py`：`ConnectionManager` 单例；维护 `Dict[campaign_id, Set[WebSocket]]`；提供 `connect / disconnect / fan_out`
- [ ] 7.2 `ws/redis_subscriber.py`：每 campaign_id 起一个 asyncio task 订阅 `engine:events:campaign:{id}`，收到消息反序列化 `EngineEvent` → `manager.fan_out`
- [ ] 7.3 `routers/ws.py`：`/ws/calls/{campaign_id}`，accept 前从 query param `token` 取 JWT 验证；失败 close code 4401
- [ ] 7.4 多客户端订阅同一 campaign：复用同一 Redis 订阅（subscriber 引用计数；最后一个客户端断开时延迟关闭订阅）
- [ ] 7.5 集成测试：起 WS 客户端 + 用 Redis client 直接 publish 一条 EngineEvent，断言客户端收到该消息
- [ ] 7.6 鉴权测试：无 token / 非法 token 连接被 4401 关闭

## 8. mock 事件 publisher（PR #8）

- [ ] 8.1 `scripts/fake_engine_events.py`：CLI（argparse），参数 `--campaign-id <int>` `--rate-hz <float>` `--duration-s <int>`
- [ ] 8.2 用 isales-common `EngineEvent` discriminated union 构造合法消息（state_change / asr_text / transcript_increment 各一种轮询）
- [ ] 8.3 输出到 Redis Pub/Sub `engine:events:campaign:{id}`
- [ ] 8.4 README 增加 dev 章节：如何用 publisher + WS 客户端验证 `/ws/calls`
- [ ] 8.5 NOT 暴露在 entry point；MUST 仅 `python -m scripts.fake_engine_events` 调用

## 9. systemd unit + 部署文档（PR #9）

- [ ] 9.1 `deploy/isales-api.service`：uvicorn worker 1，确认 WS 配置（`--ws auto` `--workers 1`）
- [ ] 9.2 README 部署章节：环境变量（含 `ISALES_JWT_SECRET` 与 telephony-api 共用）/ 启动命令 / migration 说明（migration 由 isales-common 跑）
- [ ] 9.3 在 IMPLEMENTATION_PLAN.md 阶段 2B 验收清单上勾选

## 10. 收尾

- [ ] 10.1 全量 pytest 全绿
- [ ] 10.2 mypy / ruff 无 error
- [ ] 10.3 OpenAPI 文档手动跑一遍：建任务 → 导线索 → 启动 → 看监控（用 mock publisher）
- [ ] 10.4 在主仓 isales 创建 commit 引用本 change archive；提示 impl-telephony 可独立 archive
