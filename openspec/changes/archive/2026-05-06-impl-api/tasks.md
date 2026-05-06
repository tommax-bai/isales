> 实施在 isales-api 仓库（新建）。每组对应 1~2 个 PR，建议按顺序合入。
> 不动 isales-common（依赖 v0.1.1 即可）。

## 1. isales-api 仓库骨架（PR #1）

- [x] 1.1 `git init isales-api` + `.gitignore`
- [x] 1.2 `pyproject.toml`（hatchling）+ deps（含 isales-common>=0.1.1,<0.2、python-jose、bcrypt、python-multipart）
- [x] 1.3 dev 依赖
- [x] 1.4 目录骨架
- [x] 1.5 entry point `isales-api`
- [x] 1.6 `common/db.py`（DBSession dep + lifecycle）+ `common/redis.py`（wrap isales-common）
- [x] 1.7 `main.py`：FastAPI + `/health` + lifespan（JWT dep 在 PR #2 接入）
- [x] 1.8 README + CI（ruff/mypy/pytest）— CI 装 isales-common @ v0.1.2 git tag

## 2. JWT 签发与鉴权（PR #2）

- [x] 2.1 `auth/users.py`：bcrypt 单 admin 校验，env vars `ISALES_ADMIN_USER` / `ISALES_ADMIN_PASSWORD_HASH`
- [x] 2.2 `auth/jwt.py`：`sign_jwt(claims, ttl=24h)`，HS256；secret 从 `ISALES_JWT_SECRET`
- [x] 2.3 `auth/router.py`：`POST /auth/login`（OAuth2PasswordRequestForm）、`GET /auth/me`
- [x] 2.4 `auth/deps.py`：`current_user` dep 依赖 isales-common `verify_jwt` + OAuth2PasswordBearer；401 + WWW-Authenticate
- [x] 2.5 测试：login 成功 / 密码错 / 未知用户 / 422 / valid me / missing token / invalid token / expired token（共 8 路径）

## 3. campaigns CRUD（含嵌套）（PR #3）

- [x] 3.1 `routers/campaigns.py`：GET list（分页）/ GET detail / POST / PATCH / DELETE（嵌套 children 跟随）
- [x] 3.2 嵌套 schema 在本仓 `isales_api/schemas.py` 落（共 5 个本地 DTO：3 个 NestedWrite + Page + CampaignDetailRead），FillerSet/Phrase 之前 isales-common 未提供 schema
- [x] 3.3 嵌套写入：单事务 upsert campaign + DELETE WHERE + INSERT children；FillerSet 删除靠 `ON DELETE CASCADE` 联级清掉 phrases
- [x] 3.4 ON DELETE CASCADE 已在 isales-common v0.1.x 模型中存在（filler_phrase→filler_set / role_config→campaign / filler_set→campaign / callback_config→campaign 全部 CASCADE），无需新 alembic 迁移
- [x] 3.5 集成测试：POST 嵌套 → GET 校验 / PATCH 全量替换 / DELETE 级联清 4 张子表 / 分页 / 404
- [x] 3.6 `POST/GET/DELETE /campaigns/{id}/devices` 三个 endpoint 直写 campaign_device

## 4. leads / voice_models / holidays / handoff_tasks（PR #4）

- [x] 4.1 `routers/leads.py`：CRUD（GET list 分页 + status / campaign_id 过滤）
- [x] 4.2 `routers/leads.py`：`POST /leads/import` multipart CSV，1000 行批 flush，`LeadsImportResult{success_count, error_count, errors: [{row, message}]}`，HTTP 200 部分成功
- [x] 4.3 测试：5 行 CSV 含 2 错 → 3 成功 2 错；缺列 → 400（10w 行性能验证留 PR #10 smoke）
- [x] 4.4 `routers/voice_models.py`：CRUD + `GET /voice-models/{id}/sample` 307 redirect 到 sample_url（v1 简化）
- [x] 4.5 `routers/holidays.py`：CRUD（local HolidayCreate/Update/Read DTO）
- [x] 4.6 `routers/handoff_tasks.py`：GET list（status 过滤）+ GET detail；pick-up / complete 501 + detail `lifecycle_in_stage_3`

## 5. calls 查询 + analytics（PR #5）

- [x] 5.1 `routers/calls.py`：GET list（campaign_id / lead_id / status 过滤 + 分页）
- [x] 5.2 `routers/calls.py`：GET detail（CallRecordRead 自带 transcript / recording_url）+ `/calls/{id}/summary` 返回 CallSummaryRead
- [x] 5.3 `routers/analytics.py`：answer-rate / goal-rate / duration-distribution 三个 endpoint
- [x] 5.4 SQLAlchemy core 聚合（case+coalesce）；`?since=&until=` 默认最近 7 天
- [x] 5.5 7 个测试：calls list 过滤分页 / detail 404 / summary 404；analytics 三种聚合数值校验 + 时间窗排除老数据

## 6. Campaign 启停 + 消息发布（PR #6）

- [x] 6.1 `routers/campaigns.py`：`POST /campaigns/{id}/start` / `POST /campaigns/{id}/pause`，202 + 返回 `message_id`
- [x] 6.2 用 isales-common `StartCampaign` / `PauseCampaign` 构造消息，`redis.lpush("scheduler:campaign-control", msg.model_dump_json())`
- [x] 6.3 测试：start/pause 各 1 个 + unknown campaign 404；Redis 不可达时 graceful skip（CI 装 Redis service container 跑全套）

## 7. WebSocket 通话事件代理（PR #7）

- [x] 7.1 `ws/manager.py`：`ConnectionManager` 维护 dict[cid, set[WS]] + dict[cid, Task]；锁同步 connect/disconnect；fan_out 写所有连接
- [x] 7.2 `ws/redis_subscriber.py`：`make_subscriber_factory(redis)` 起 pubsub.listen() 协程，原始消息 verbatim 转 manager.fan_out（不重新包装）
- [x] 7.3 `routers/ws.py`：`/ws/calls/{cid}?token=`；accept 后立即 close 4401（custom code）
- [x] 7.4 多客户端共享单 subscriber + 5s delayed shutdown；shutdown 在 lifespan 退出
- [x] 7.5 单元测试：ConnectionManager + redis_subscriber 真 Redis + fake WS，验证 publish→fan_out 与多客户端共享 task。注：TestClient ASGI portal 跨 loop 无法端到端 WS+Redis 派发，故拆为单元测试
- [x] 7.6 鉴权测试：missing/invalid token → 4401；valid token 不返 4401

## 8. mock 事件 publisher（PR #8）

- [x] 8.1 `scripts/fake_engine_events.py`：argparse `--campaign-id` `--rate-hz` `--duration-s` `--call-record-id` `--redis-url`
- [x] 8.2 轮询 5 种 EngineEvent：CallStarted / StatusChanged / ASRPartial / StatusChanged / CallEndedEvent
- [x] 8.3 publish 到 `engine:events:campaign:{id}`
- [x] 8.4 README dev 章节：3-terminal 流程
- [x] 8.5 不在 `[project.scripts]` 暴露；仅 `python -m scripts.fake_engine_events`

## 9. systemd unit + 部署文档（PR #9）

- [x] 9.1 `deploy/isales-api.service`：systemd unit + hardening flags；注释说明 1 worker（WS 长连接限制）
- [x] 9.2 README 部署章节：env 表（JWT 与 telephony-api 共用）+ alembic upgrade（由 isales-common 包跑）+ journalctl
- [x] 9.3 IMPLEMENTATION_PLAN.md 阶段 2B 验收清单全部勾选

## 10. 收尾

- [x] 10.1 全量 pytest 全绿（44 passed）
- [x] 10.2 mypy / ruff 无 error
- [x] 10.3 OpenAPI smoke test（验证 27 条路径 + 5 个 schema 在 /openapi.json 中存在）；端到端流程（建任务 → 导线索 → 启动 → 看监控）由 README dev 三-terminal 流程承载
- [x] 10.4 主仓 commit 标记 impl-api 实施完成；archive 由 /opsx:archive 触发（impl-telephony 已独立归档）
