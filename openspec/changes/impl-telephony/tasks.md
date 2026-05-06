> 实施跨两个仓库：先 isales-common（v0.1.2 bump），后 isales-telephony。每组对应 1~2 个 PR，建议按顺序合入。

## 1. isales-common v0.1.2 bump（PR #1）

- [x] 1.1 在 isales-common 仓库 `models/device.py` 加 `last_call_at: Mapped[datetime | None]`（`DateTime(timezone=True)`，nullable）
- [x] 1.2 在 `schemas/device.py` 加 `DeviceSelectRequest`（`campaign_id: int`）和 `DeviceSelectResponse`（`device_id: int`、`phone_number: str`），跟随既有 schema 命名约定
- [x] 1.3 用 `alembic revision --autogenerate -m "add device.last_call_at"` 生成迁移，校对生成的 op，必要时手工调整
- [x] 1.4 在 `utils/jwt.py` 新增 `verify_jwt(token: str, secret: str) -> dict` 函数（HS256，校验 exp）；MUST NOT 暴露签发函数
- [x] 1.5 单元测试：新 schema 实例化 + 序列化往返；`verify_jwt` 通过/过期/签名错三种路径
- [x] 1.6 跑 `alembic upgrade head` + `alembic downgrade -1` 往返通过；CHANGELOG.md 记一行 v0.1.2
- [x] 1.7 pyproject.toml 版本号 0.1.1 → 0.1.2 (`5fe00da`)；git tag `v0.1.2` deferred to release/v0.1.2 PR merge

## 2. isales-telephony 仓库骨架（PR #2）

- [x] 2.1 `git init isales-telephony` + `.gitignore`（Python + venv + .env + `*.sock`）
- [x] 2.2 `pyproject.toml`（hatchling）：依赖 `fastapi`、`uvicorn[standard]`、`sqlalchemy[asyncio]`、`asyncpg`、`alembic`、`redis>=5`、`pyudev`（platform_system == "Linux"）、`apscheduler`、`pyserial`（optional-dependencies = "hardware"）、`isales-common>=0.1.2,<0.2`
- [x] 2.3 dev 依赖：`pytest`、`pytest-asyncio`、`httpx`、`testcontainers[postgres]`、`ruff`、`mypy`
- [x] 2.4 目录结构：`isales_telephony/{api,modem_controller,common}/__init__.py` + `tests/`
- [x] 2.5 两个 entry point（pyproject `[project.scripts]`）：`telephony-api = "isales_telephony.api.main:run"`、`modem-controller = "isales_telephony.modem_controller.main:run"`
- [x] 2.6 `common/db.py` 提供 async session factory；`common/redis.py` wrap isales-common 的 client factory
- [x] 2.7 `common/auth.py`：FastAPI dependency 依赖 isales-common `verify_jwt`，从 `ISALES_JWT_SECRET` 读密钥；返回 `current_user`；服务间内部调用路由 MAY 用单独 `internal_router`（无 JWT 依赖）
- [x] 2.8 README.md（一句话说明 + 启动命令）；GitHub Actions CI（ruff / mypy / pytest）

## 3. telephony-api：device / sim / binding CRUD（PR #3）

- [x] 3.1 `api/main.py` FastAPI app，挂 `/health`、`/docs`、JWT 中间件
- [x] 3.2 `api/routers/devices.py`：GET list（分页 + status 过滤）/ GET detail / POST / PATCH / DELETE
- [x] 3.3 `api/routers/sim_cards.py`：GET list（分页 + carrier / status 过滤）/ GET detail / POST / PATCH / DELETE
- [x] 3.4 `api/routers/device_sim_bindings.py`：GET list（按 device_id / sim_card_id 过滤；含 unbind_at）
- [x] 3.5 集成测试（real PG via `ISALES_TEST_DATABASE_URL`；testcontainers 留作 CI 路径备份）：每条路由的 200 / 404 / 422 路径
- [x] 3.6 OpenAPI 文档手动跑通，schema 完整

## 4. telephony-api：/devices/select 并发安全实现（PR #4）

- [x] 4.1 `api/routers/select.py`：`POST /devices/select`，请求/响应用 isales-common `DeviceSelectRequest/Response`
- [x] 4.2 实现选号：单事务 + `SELECT ... FOR UPDATE SKIP LOCKED`，紧接 `UPDATE last_call_at = now(), status = 'dialing'`（status 翻 dialing 是实施时的修正——见 design.md 决策 1，否则锁不重叠的并发会重选同一台）
- [x] 4.3 无空闲设备 → 返回 503 `{"detail": "no_idle_device"}`
- [x] 4.4 该路由可走 `internal_router`（免 JWT）；网络层文档说明 telephony-api 监听 loopback / 内部网段
- [x] 4.5 并发集成测试：起 10 个 idle device + 10 个 SIM；并发 11 次 `/devices/select`，断言 10 台被选中一次（不撞车）+ 1 次 503
- [x] 4.6 NULL last_call_at 测试：3 台 idle，2 台 last_call_at 已设、1 台 NULL；首次选号 SHALL 选中 NULL 那台

## 5. telephony-api：设备健康监控 stub（PR #5）

- [x] 5.1 `api/health_monitor.py`：APScheduler async scheduler，间隔 5 分钟
- [x] 5.2 `compute_health(device_id) -> bool` 函数：v1 阶段 2 永远返回 True；TODO 注释指向阶段 4
- [x] 5.3 后台任务：扫所有 device，调 compute_health；False 时把 status 置 flagged
- [x] 5.4 测试：手动触发任务，mock compute_health 返回 False，断言 device.status 变为 flagged

## 6. modem-controller：进程骨架 + IPC server（PR #6）

- [x] 6.1 `modem_controller/main.py`：asyncio 主循环，启动 IPC server（udev watcher / DB sync 留 PR #8）
- [x] 6.2 `modem_controller/ipc_server.py`：监听 Unix socket（路径从环境变量读，默认 `/var/run/isales/modem.sock`）；newline-delimited JSON 解析（按 device-hardware spec § IPC 帧格式）
- [x] 6.3 IPC 消息分发：`cmd: "dial"` / `"hangup"` / `"status"` / `"audio_downstream"` 各一个 handler（dial/hangup 是 PR #6 的 stub，PR #7 替换为 MockATClient 驱动）
- [x] 6.4 单条消息 ≤ 1 MiB 校验；不完整帧 → 关闭连接 + 日志告警
- [x] 6.5 测试：起 IPC server，asyncio 客户端连入，发 `{"cmd":"status"}\n` 收到 status 响应；发不完整帧 / 无效 JSON 验证连接被关闭

## 7. modem-controller：MockATClient + mock dial 行为（PR #7）

- [x] 7.1 `modem_controller/at_client.py`：`ATClient` Protocol 定义（dial / hangup / get_signal / get_iccid / get_imei）
- [x] 7.2 `MockATClient` 实现：dial 返回 call_id 立即 + AsyncIterator[ATEvent]；MOCK_DIAL_DELAY_MS 后 yield connected、MOCK_CALL_DURATION_MS 后 yield remote_hangup{cause: "normal_clearing"}；hangup() 设置 cancel event 提前结束
- [x] 7.3 dial 时 device.status 置 dialing；connected 时置 in_call；hangup 时置 idle
- [x] 7.4 IPC dial handler 调用 ATClient；事件 pump 为后台 task 推 connected/remote_hangup 回连接
- [x] 7.5 测试：起 modem-controller + IPC，发 dial 按时序收到 connected → remote_hangup；status 流转正确；外部 hangup 命令可短路

## 8. modem-controller：udev 监听器骨架（PR #8）

- [x] 8.1 `modem_controller/udev_watcher.py`：`pyudev.Monitor` 监听 add / remove 事件（real impl lazy-import；测试走 fake_events 注入）
- [x] 8.2 add 事件：识别为 GSM modem（按 GSM_MODEM_WHITELIST vendor/product 匹配），写 device.last_seen_at；NOT 发 AT 命令
- [x] 8.3 remove 事件：找到对应 device，status 置 offline
- [x] 8.4 平台兼容：`ISALES_SKIP_UDEV=1` 或 `platform.system() != "Linux"` 时 start_udev_watcher 直接 return None
- [x] 8.5 测试：fake UdevEvent 推 add/remove/未知厂商，断言 last_seen_at / status / 忽略 三种路径

## 9. systemd unit + 部署文档（PR #9）

- [x] 9.1 `deploy/isales-telephony-api.service`：systemd unit + hardening flags
- [x] 9.2 `deploy/isales-modem-controller.service`：含 `RuntimeDirectory=isales` + `SupplementaryGroups=plugdev,dialout`
- [x] 9.3 README.md 部署章节：环境变量表 / 启动命令 / 日志 / 网络策略
- [x] 9.4 IMPLEMENTATION_PLAN.md 阶段 2A 验收清单全部勾选

## 10. 收尾

- [x] 10.1 跑全量 pytest 全绿（isales-common 102 passed / isales-telephony 31 passed）
- [x] 10.2 mypy / ruff 无 error（两仓库均 0）
- [x] 10.3 在主仓 isales 创建 commit 标记 impl-telephony 实施完成；archive 入归档由 /opsx:archive 触发
