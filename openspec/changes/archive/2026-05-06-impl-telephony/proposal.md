## Why

阶段 2 的 telephony 服务在 spec 层面（device-hardware / data-model / architecture / service-communication / message-contract）已经完整描述，但从未实施过。本 change 是首次实施：交付 telephony-api（HTTP 服务）和 modem-controller（守护进程骨架）两个进程，匹配 IMPLEMENTATION_PLAN.md 阶段 2A，让下游 scheduler（阶段 3）和 engine（阶段 4）的 propose 有可调用的 API 与可联调的 IPC mock。

本 change 同时承担 isales-common v0.1.2 增量发布——`device.last_call_at` 列、`DeviceSelectRequest/Response` schema、对应 alembic 迁移；这些字段只服务于 telephony 与未来 scheduler，没必要单独切一个 common bump change。

## What Changes

- **isales-common v0.1.2 增量**（先发布，再被 telephony 仓库 pip 安装）
  - `Device` 模型加 `last_call_at: DateTime | None`
  - `isales_common/schemas/device.py` 加 `DeviceSelectRequest`、`DeviceSelectResponse`
  - alembic 增量迁移 `add_device_last_call_at`
  - 版本号从 0.1.1 → 0.1.2，CHANGELOG 记录

- **isales-telephony 仓库新建**（独立 git repo，pip install isales-common >= 0.1.2）
  - 仓库骨架：pyproject.toml、两个 entry point（`telephony-api` / `modem-controller`）、CI、JWT 验证 utils、Redis client wrapper

- **telephony-api（FastAPI 进程）**
  - JWT 验证中间件（HS256，`ISALES_JWT_SECRET` 环境变量），按 architecture spec 仅验证不签发
  - `/devices` CRUD（GET list / GET detail / POST / PATCH / DELETE）
  - `/sim-cards` CRUD（同上）
  - `/device-sim-bindings` GET list（按 device_id / sim_card_id 过滤；含 unbind_at 历史）
  - `POST /devices/select`：实现 device-hardware spec 算法（含 NULL 视为最早 + 并发安全：用 PG 行级锁 `SELECT ... FOR UPDATE SKIP LOCKED`）
  - 设备健康监控：定时任务扫近 N 通接通率，置 `flagged`（v1 阶段 2 用 mock 数据；真实 call_record 阶段 4 接通后自然生效）
  - OpenAPI 文档自动生成
  - 监听端口配置：MAY 仅 loopback / 内部网段（按 architecture spec 服务间内部调用免 JWT）

- **modem-controller（守护进程骨架）**
  - IPC 服务：Unix socket + JSON（按 device-hardware spec），暴露 `dial / hangup / status / audio_downstream` 指令
  - dial / hangup mock 实现：仅打日志、写 device.status 状态变更、模拟 `connected` / `remote_hangup` 事件回送
  - udev 监听器（pyudev）骨架：监听 add / remove 事件，事件打日志、写 device.last_seen_at；不发 AT 命令
  - AT 命令客户端抽象：定义 `ATClient` 接口（`dial / hangup / get_signal / get_iccid` 等抽象方法），mock 实现返回固定值；真实硬件实现留到阶段 6
  - 启动时从 DB 加载 device 列表，尝试匹配 USB 端口（mock 阶段记录 "matched=False" 即可）
  - systemd unit 文件（v1 同主机部署）

- **测试**
  - pytest + pytest-asyncio
  - device / sim_card / binding CRUD 的集成测试（用 testcontainers PG）
  - `/devices/select` 并发测试：并发 10 个请求验证不会选中同一台
  - modem-controller IPC mock 测试：客户端发 dial 收到模拟 connected

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `device-hardware`: 新增 Requirement "IPC 帧格式"——把现有 § engine ↔ modem-controller IPC 协议 的"JSON 形状"具体化为 newline-delimited JSON 帧格式（含分帧规则、不完整帧处理、单条 ≤ 1 MiB、双向独立流）。这是 modem-controller 与未来 engine（阶段 4）的硬契约，必须在 spec 层固定。

其余对 `data-model` / `architecture` / `service-communication` / `message-contract` 等 spec 的**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-telephony`（独立 git，本仓库下不放代码）
- **isales-common 仓库**：bump 到 v0.1.2 + 发布；模型与 schema 增量已在 `clarify-stage2-boundaries` change 中约定
- **依赖链**：本 change 完成后，scheduler（阶段 3）才有 `/devices/select` 可调；engine（阶段 4）才有 modem-controller IPC mock 可联调
- **可与 `impl-api` 并行实施**：两者无运行时依赖（api 不调 telephony-api 的 endpoint；scheduler 才调）
- **不影响**：isales-engine / isales-worker / isales-web 仓库均未启动；clarify-stage2-boundaries 已归档的 spec 不再变动
