## Context

阶段 2 的 telephony 实施。spec 已经在 `device-hardware` / `data-model` / `architecture` / `service-communication` / `message-contract` 中完整描述，本 change 不动 spec，只把它们落到代码。clarify-stage2-boundaries（已归档）解决了边界模糊点：`device.last_call_at` 字段、`/devices/select` schema 出处、JWT 共享体系、并发安全要求等。

约束：
- Python 3.11+（与 isales-common 保持一致）
- FastAPI（HTTP 服务事实标准；自动 OpenAPI；与 isales-api 同栈）
- 异步全栈（async SQLAlchemy + asyncpg + asyncio Unix socket）
- v1 阶段 2 不接真实硬件——modem-controller 全部 mock；udev 监听器骨架可在开发机上跑空（无设备插拔时不报错）
- 单主机部署，systemd 拉两个 unit

## Goals / Non-Goals

**Goals:**

- isales-common bump 到 v0.1.2 并发布，下游可 `pip install isales-common==0.1.2`
- telephony-api 跑通 device / sim_card / device_sim_binding 的 CRUD + `/devices/select`，并发 10 个请求选号验证不撞车
- modem-controller 进程能启动、IPC server 接受连接、mock dial / hangup / status 返回符合 device-hardware spec 的 JSON 形状
- udev 监听器在没插设备时空跑不崩；插一个 USB 设备能在日志看到 add/remove 事件
- pytest 全绿（含集成测试）

**Non-Goals:**

- 不接真实 AT 命令 / 真实 ALSA 音频管道（阶段 6）
- 不实现 device 健康监控的真实指标聚合（call_record 在阶段 4 才被 engine 写入）
- 不实现 SMS / 多主机扩展 / 信号自动切换（device-hardware spec § v1 不做的硬件能力）
- 不实现 telephony-api 与 modem-controller 之间的 health check 或自动重连——v1 systemd Restart=on-failure 即可

## Decisions

### 1. 并发选号：PostgreSQL 行级锁 `SELECT ... FOR UPDATE SKIP LOCKED`

- **选择**：`/devices/select` 实现使用 PG 行级锁查询：`SELECT ... FROM device WHERE status='idle' AND ... ORDER BY last_call_at ASC NULLS FIRST LIMIT 1 FOR UPDATE SKIP LOCKED`，紧接着 `UPDATE device SET last_call_at = now(), status = 'dialing'`，全部在一个事务内
- **理由**：
  - PG 原生支持 `SKIP LOCKED`，并发请求会跳过被锁定的行去拿下一台 idle device，避免单台 device 被多次选中
  - 比应用层 Redis 锁简单：不引入额外组件，事务边界清晰，崩溃不留垃圾锁
  - clarify-stage2-boundaries 的 spec 把"具体策略"留给 impl 决定，本决策落实
  - **status 翻 dialing 是 PR #4 实施时的修正**：原 tasks.md 4.2 只写 `UPDATE last_call_at`，但若 status 不变，两次时序错开（锁不重叠）的 /select 仍能拿到同一设备。/select 是 scheduler 调用的"认领点"，scheduler 收到响应后必须紧接发 dial；提前在 /select 把 status 翻 dialing 等价于 scheduler 已认领，与下游 modem-controller dial 流程语义一致（PR #7 task 7.3 也把 dialing 当作 dial 中状态）
- **替代**：
  - Redis 分布式锁 → 多一个组件、要处理超时与孤儿
  - 乐观锁（CAS on last_call_at）→ 高并发下重试多，且 `last_call_at` 不是天然递增字段
  - SERIALIZABLE 隔离级别 → 所有事务串行重试，性能低

### 2. IPC 协议：Unix socket + 行分隔 JSON（newline-delimited）

- **选择**：`modem-controller` 监听 `/var/run/isales/modem.sock`；engine 客户端连接后双向以 `\n` 分隔的 JSON 消息流；每行一个完整消息
- **理由**：
  - 实现最简（asyncio `StreamReader.readline()`）
  - 调试方便（`socat - UNIX-CONNECT:...` 直接交互）
  - device-hardware spec 已给 JSON 例子，本决策只确定分帧方式
  - PCM 音频走 base64 + 同一通道（v1 简化，spec 已允许）
- **替代**：
  - 长度前缀帧 → 二进制更紧凑但调试难，v1 流量小不必要
  - WebSocket（device-hardware spec 第 110 行写"Unix socket / WebSocket"）→ 本地 IPC 没必要 HTTP 升级

### 3. AT 客户端抽象：`ATClient` Protocol + `MockATClient` / `SerialATClient` 实现

- **选择**：`isales_telephony/modem_controller/at_client.py` 定义 `ATClient` Protocol（abstract methods: `dial(number) -> CallId`、`hangup(call_id)`、`get_signal()`、`get_iccid()`、`get_imei()`），阶段 2 提供 `MockATClient`（返回固定值 + 模拟延迟），阶段 6 加 `SerialATClient`（pyserial）
- **理由**：
  - 阶段 6 加真实实现时无需改 modem-controller 主流程
  - mock 实现可定制 `dial_should_fail` 等参数，方便构造 dial 失败的测试场景
- **替代**：直接 if-else 切换 → 阶段 6 易腐烂

### 4. modem-controller mock dial 行为

- **选择**：`MockATClient.dial(number)` 立即返回 call_id（同步），随后 `MockATClient` 内部 asyncio task 在 1s 后 emit `connected` 事件、再 5s 后 emit `remote_hangup{cause: "normal_clearing"}` 事件，模拟一通短电话
- **理由**：阶段 4 engine 集成时需要可观察的状态机流转；mock 行为足够触发整个 PROGRESS → CONNECTED → HANGUP 链路
- **替代**：mock 立即 hangup → engine 测不出 in_call 状态停留逻辑

### 5. udev 监听器：空跑不崩，事件记日志即写 last_seen_at

- **选择**：`pyudev.Monitor` 启动时若无 GSM modem 类设备也不报错；add 事件触发"识别 ICCID + 写 device.last_seen_at"；remove 事件触发"device.status = offline"；阶段 2 不发 AT 命令、不真初始化 device
- **理由**：开发机不一定有 USB GSM modem；spec 第 90-107 行的完整流程留到阶段 6
- **替代**：阶段 2 全跳过 udev → 阶段 6 才暴露集成问题；先把骨架跑起来更稳

### 6. 设备健康监控：v1 阶段 2 用 stub 数据

- **选择**：定时任务（APScheduler）每 5 分钟扫一次 device 表，调用 `compute_health(device_id)` 函数；阶段 2 该函数返回固定值 `healthy=True`；阶段 4 engine 接通后改为查 call_record 真实接通率
- **理由**：阶段 2 没有 call_record 数据可查；保留任务调度框架避免阶段 4 再加
- **替代**：阶段 2 完全不做监控 → 阶段 4 才发现需要 → 重新加调度框架

### 7. JWT 验证：依赖 isales-common 提供的 `verify_jwt`，不重复造轮

- **选择**：在 isales-common（v0.1.2）`utils/jwt.py` 提供 `verify_jwt(token, secret) -> dict`，telephony-api 通过 FastAPI Depends 注入；按 architecture spec MAY 提供验证不签发
- **理由**：与 isales-api 引用同一份验证逻辑；密钥从环境变量 `ISALES_JWT_SECRET` 各自读取，库不持密钥
- **替代**：每个服务自己写验证 → 易出 bug；isales-common 直接持密钥 → 违反 architecture spec § JWT 配置不属于 isales-common 业务范围

### 8. 部署：两个 systemd unit，不用 supervisor

- **选择**：`isales-telephony-api.service` 和 `isales-modem-controller.service` 各一个 systemd unit，独立日志、独立 Restart 策略
- **理由**：spec architecture § 进程隔离已规定每服务独立 systemd unit；两进程崩溃后独立恢复
- **替代**：用 supervisor / k8s → v1 单主机过重

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `SELECT FOR UPDATE SKIP LOCKED` 在 SQLAlchemy 异步层的语法或行为有坑 | 集成测试覆盖并发 10 路；写一个最小复现脚本，留作回归 |
| isales-common v0.1.2 发布的版本管理混乱（同时多个仓库依赖） | 用 hatchling 的 dynamic version + git tag；下游 pyproject.toml 用 `>=0.1.2,<0.2`；CI 在 PR 阶段就跑 `pip install` 烟测 |
| modem-controller mock 行为与阶段 6 真实硬件差异大 → 阶段 4 engine 集成时偏差累积 | 阶段 6 的 PR 1 必须覆盖 mock vs real 行为对比测试，发现偏差立即修 mock |
| udev 在 macOS 开发机上不可用（pyudev 仅 Linux） | 开发文档明确 telephony 仓库的真实运行需 Linux；macOS 上 modem-controller 跳过 udev 启动（环境变量 `ISALES_SKIP_UDEV=1`）|
| `/devices/select` 的"选号成功后回写 last_call_at" 在事务内执行，失败时回滚——但选号 API 已经返回响应 | 事务必须在响应返回前 commit；commit 失败 → telephony-api 返回 500，scheduler 重试；spec scenario 写的是"在响应返回前更新"，事务模型与之一致 |
| pyserial 依赖在 CI 容器里装不上（v1 阶段 2 不需要但 pyproject 列了） | 用 `dependencies` 与 `optional-dependencies` 分组，CI 跑核心测试不装 pyserial；阶段 6 加测试任务覆盖串口路径 |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

发布顺序：
1. isales-common 仓库：merge v0.1.2 PR → tag v0.1.2 → 发布（pip 私服或 git tag）
2. isales-telephony 仓库：依赖 v0.1.2，按 tasks.md 顺序合 PR
3. 部署：systemd 拉起两个 unit，确认 `/health` 200 与 IPC socket 监听

## Open Questions

- isales-common 的发布渠道（私服 vs git tag URL）阶段 0 说"未来按需选私服"——本 change 默认走 git tag URL（`pip install git+ssh://...@v0.1.2`）；如果用私服，CI 与 pyproject.toml 要相应改
- `MockATClient` 的事件时间常量是否要 configurable（如 `MOCK_DIAL_DELAY_MS`）——倾向 configurable，方便阶段 4 engine 集成测试不同时序场景
