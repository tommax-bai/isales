## Purpose

定义 7 个服务之间的通信通道与用途。本规范是"调用关系矩阵"——具体消息内容由各 capability spec 定义；本 spec 仅承担通道选型与全局一致性。

## Requirements

### Requirement: 通信通道矩阵

各服务 SHALL 按以下表使用对应通道；MUST NOT 引入未列出的通道（除非经 change proposal）。

| 从 | 到 | 通道 | 用途 |
|---|---|---|---|
| scheduler | engine | Redis Queue | "拨打这条线索"（消息体含 lead 信息 + 历史摘要 + prompt_versions 快照） |
| engine | worker | Redis Queue | "通话已结束，请处理" |
| api | engine | Redis Pub/Sub | 实时控制（手动挂断、转人工指令） |
| engine | api | Redis Pub/Sub | 通话事件推送（状态变更、ASR 文本） |
| api | scheduler | Redis Queue | 启动 / 暂停 Campaign |
| scheduler | telephony-api | HTTP | 拨号前选 device（含 caller_id） |
| engine | modem-controller | 本地 Unix socket / WebSocket | 拨号、挂断、PCM 音频流双向 |
| modem-controller | telephony DB | 直连 | 设备状态 / SIM 状态实时回写 |
| modem-controller | USB GSM modem | AT 命令（`/dev/ttyUSB*`）+ 音频（ALSA） | 物理设备控制 |
| worker | 外部 | HTTP | Webhook 回调外部业务系统 |
| 全部 | PostgreSQL | 直连（通过 isales-common 模型） | 数据持久化 |
| 全部 | Redis | 直连 | 队列、缓存、计数器 |

#### Scenario: 通道选型一致性

- **WHEN** 引入新的服务间调用
- **THEN** 调用 SHALL 复用上表中已有的通道与协议风格；如需新增通道（如 gRPC），MUST 经 change proposal 明确论证

### Requirement: 队列与 Pub/Sub 的边界

Redis Queue SHALL 用于"必须送达，可异步处理"的工作派发；Redis Pub/Sub SHALL 用于"实时、可丢失"的事件广播。

#### Scenario: 适合 Queue 的场景

- **WHEN** 消息丢失会导致业务遗漏（如未拨打 lead、未处理通话结束）
- **THEN** 通信 MUST 用 Redis Queue（含确认与重试）

#### Scenario: 适合 Pub/Sub 的场景

- **WHEN** 消息延迟敏感且偶尔丢失可接受（如前端实时监控通话状态）
- **THEN** 通信 SHALL 用 Redis Pub/Sub

### Requirement: 全局并发控制

跨 engine 实例的全局并发 SHALL 用 Redis 原子计数器（INCR/DECR）；本地内存计数器 MUST NOT 替代。

#### Scenario: 拨号前并发计数器递增

- **WHEN** scheduler 派发新通话前
- **THEN** SHALL 调 Redis INCR 检查并发上限；超限时拒绝派发并稍后重试

#### Scenario: 通话结束计数器递减

- **WHEN** engine 通话结束
- **THEN** SHALL 调 Redis DECR；MUST 在挂断后立即执行（避免计数器泄漏）

#### Scenario: 防计数器泄漏

- **WHEN** engine 异常崩溃
- **THEN** 系统 SHALL 有定期对账机制（短期：systemd 重启时清理；中期：Redis hash slot + 心跳）

### Requirement: HTTP 调用规范

服务间同步 HTTP 调用 SHALL 限制到必要场景（v1 仅 scheduler → telephony-api 一处）；其他通信 MUST 走 Redis 队列或 Pub/Sub。

#### Scenario: 内部 HTTP 仅用于设备选择

- **WHEN** 服务间需要同步 HTTP 调用
- **THEN** v1 仅 scheduler → telephony-api 一处；其他服务间通信 MUST 用 Redis 队列或 Pub/Sub

#### Scenario: 外部 webhook 走 HTTP

- **WHEN** worker 触发 callback
- **THEN** SHALL 用 HTTP POST/PUT 等（具体 method 由 callback_config 配置），细节见 webhook-callback

### Requirement: 数据库直连

每个服务 SHALL 直接访问 PostgreSQL（通过 isales-common 模型）；MUST NOT 引入"数据网关"层在服务间转发数据库读写。

#### Scenario: 跨服务读 vs 写

- **WHEN** 多个服务读同一表
- **THEN** 各自直读即可；写操作 SHALL 由表的归属服务承担（详见 data-model）

### Requirement: 通信故障的容错

各服务 SHALL 对依赖（Redis / PostgreSQL / modem-controller）的短暂不可用有容错策略；MUST 重连并优雅清理受影响的 call_session。

#### Scenario: Redis 短暂不可用

- **WHEN** Redis 连接中断
- **THEN** 各服务 SHALL 重连重试（带退避）；engine 中断重连期间 MUST 不接受新拨号但 MAY 完成当前通话

#### Scenario: PostgreSQL 短暂不可用

- **WHEN** DB 连接失败
- **THEN** 各服务 SHALL 重连重试；正在通话中的 engine MUST 把通话状态缓存至 Redis（v2 优化），v1 则在 DB 不可用时按异常通话处理

#### Scenario: modem-controller 不可用

- **WHEN** engine 检测到 IPC 中断
- **THEN** 受影响的 call_session MUST 优雅清理（写 transcript hangup 事件）；scheduler MAY 暂停派发直到 modem-controller 恢复

### Requirement: API ↔ 前端 WebSocket 代理

`isales-api` SHALL 提供 `/ws/calls/{campaign_id}` WebSocket endpoint：服务端订阅 Redis Pub/Sub channel `engine:events:campaign:{id}`、反序列化 `EngineEvent`（按 message-contract spec），fan-out 给所有该 campaign 的连接客户端。本 Requirement 把 § 通信通道矩阵中"engine → api Pub/Sub"的 api 侧落地形态明确为前端可订阅的 WebSocket。

#### Scenario: WebSocket 鉴权

- **WHEN** 客户端连接 `/ws/calls/{campaign_id}?token=<JWT>`
- **THEN** 服务端 SHALL 在 accept 前验证 JWT；验证失败 MUST 立即关闭连接并返回 close code 4401；MUST NOT accept 未鉴权连接占资源

#### Scenario: 多客户端订阅同一 campaign

- **WHEN** 多个前端客户端订阅同一 campaign_id
- **THEN** 服务端 SHALL 共享一个 Redis Pub/Sub 订阅，把每条 EngineEvent fan-out 给所有连接；MUST NOT 为每个 WS 连接独立订阅 Redis（防止 Redis 连接膨胀）

#### Scenario: 客户端断开

- **WHEN** WS 客户端断开（主动或网络异常）
- **THEN** 服务端 SHALL 从该 campaign 的连接集合移除；当某 campaign 无连接时 MAY 保留 Redis 订阅（避免重复订阅成本）或 MAY 关闭订阅（节省资源）——具体策略由 impl 决定

#### Scenario: v1 单实例限制

- **WHEN** v1 部署
- **THEN** isales-api SHALL 单实例运行；MUST NOT 假设跨实例消息广播；多实例扩展（v2）MUST 经 OpenSpec change proposal，候选方案：sticky session 或 Redis Streams + 跨实例转发

#### Scenario: 消息形状由 message-contract spec 约束

- **WHEN** 服务端转发消息给 WS 客户端
- **THEN** SHALL 直接传递 `EngineEvent` JSON（不重新包装）；前端解析时 MUST 按 message-contract spec 的 schema 处理；后端 MUST NOT 在 WS 层做字段裁剪或重命名

## Implementation Notes

通信通道的具体序列化（如 JSON / msgpack）SHALL 由各服务实现选定；建议 v1 全部用 JSON（便于调试），后续按需优化。
