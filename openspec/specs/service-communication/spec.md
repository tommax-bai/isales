## Purpose

定义 7 个服务之间的通信通道与用途。本规范是"调用关系矩阵"——具体消息内容由各 capability spec 定义；本 spec 仅承担通道选型与全局一致性。
## Requirements
### Requirement: 通信通道矩阵

各服务 SHALL 按以下表使用对应通道；MUST NOT 引入未列出的通道（除非经 change proposal）。本 change 新增 `engine → worker (isales:extract)` 一条 Redis Queue 条目。

| 从 | 到 | 通道 | 用途 |
|---|---|---|---|
| scheduler | engine | Redis Queue | "拨打这条线索"（消息体含 lead 信息 + 历史摘要 + prompt_versions 快照） |
| engine | worker | Redis Queue (`isales:call_ended`) | "通话已结束，请处理"（摘要 + webhook 触发） |
| **engine** | **worker** | **Redis Queue (`isales:extract`)** | **"请抽取这通的客户信息"（post-call extractor 任务，详见 `ai-pipeline` spec § "post-call extractor 异步抽取"）** |
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

#### Scenario: isales:extract 队列消息 schema

- **WHEN** engine LPUSH 一条到 `isales:extract`
- **THEN** payload SHALL 是 JSON 字符串，schema：
  ```json
  {
    "call_record_id": <BigInt>,
    "transcript_snapshot": [
      {"role": "assistant" | "user", "text": "...", "ts_ms": <int>}
    ],
    "extractor_role_config_id": <BigInt>,
    "extractor_prompt_version_id": <BigInt>
  }
  ```
- **AND** engine MUST 在 LPUSH 同时 UPDATE `call_record.extract_status='pending'`；worker BLPOP 处理完成后 UPDATE 为 `'done'` 或 `'failed'`

#### Scenario: isales:extract 队列消息容错

- **WHEN** worker BLPOP 后处理失败（LLM 超时 / JSON 校验失败 / DB 写失败）
- **THEN** worker MUST NOT 重 LPUSH（防雪崩）；MUST UPDATE `call_record.extract_status='failed'` + `extract_error=<reason>`；ops 通过 SQL 查询 `WHERE extract_status='failed'` 手工触发重跑

### Requirement: 队列与 Pub/Sub 的边界

Redis Queue SHALL 用于"必须送达，可异步处理"的工作派发；Redis Pub/Sub SHALL 用于"实时、可丢失"的事件广播。

#### Scenario: 适合 Queue 的场景

- **WHEN** 消息丢失会导致业务遗漏（如未拨打 lead、未处理通话结束）
- **THEN** 通信 MUST 用 Redis Queue（含确认与重试）

#### Scenario: 适合 Pub/Sub 的场景

- **WHEN** 消息延迟敏感且偶尔丢失可接受（如前端实时监控通话状态）
- **THEN** 通信 SHALL 用 Redis Pub/Sub

### Requirement: 全局并发控制

跨 engine 实例的全局并发 SHALL 用 Redis 原子计数器（INCR/DECR）；本地内存计数器 MUST NOT 替代。本要求在 v1.0 单 cloud instance 下退化为同进程计数器但接口保留。

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

`isales-api` SHALL 提供 `/ws/calls/{campaign_id}` WebSocket endpoint：服务端订阅 Redis Pub/Sub channel `engine:events:campaign:{id}`、反序列化 `EngineEvent`（按 message-contract spec），fan-out 给所有该 campaign 的连接客户端。本 Requirement 把 § 通信通道矩阵中 "engine → api Pub/Sub" 的 api 侧落地形态明确为前端可订阅的 WebSocket。

前端（isales-web）订阅 WebSocket 后 SHALL 通过 `EngineEvent` discriminated union 解析每条消息（按 message-contract spec），按 `type` 字段分发到对应的 reactive store 更新；MUST NOT 假定字段命名 / 类型 / 出现频率（vendor 端可调速率）。任何新事件类型 MUST 通过 OpenSpec change 加入 `EngineEvent` union 后前端再处理（避免前端裸用未知 type 字符串导致破坏性升级）。

#### Scenario: WebSocket 鉴权

- **WHEN** 客户端连接 `/ws/calls/{campaign_id}?token=<JWT>`
- **THEN** 服务端 SHALL 在 accept 前验证 JWT；验证失败 MUST 立即关闭连接并返回 close code 4401；MUST NOT accept 未鉴权连接占资源

#### Scenario: 多客户端订阅同一 campaign

- **WHEN** 多个前端客户端订阅同一 campaign_id
- **THEN** 服务端 SHALL 共享一个 Redis Pub/Sub 订阅，把每条 EngineEvent fan-out 给所有连接；MUST NOT 为每个 WS 连接独立订阅 Redis

#### Scenario: v1.0 单实例限制

- **WHEN** v1.0 部署
- **THEN** isales-api SHALL 单实例运行；MUST NOT 假设跨实例消息广播；多实例扩展（v2）MUST 经 OpenSpec change proposal

#### Scenario: 消息形状由 message-contract spec 约束

- **WHEN** 服务端转发消息给 WS 客户端
- **THEN** SHALL 直接传递 `EngineEvent` JSON（不重新包装）；前端解析时 MUST 按 message-contract spec 的 schema 处理；后端 MUST NOT 在 WS 层做字段裁剪或重命名

#### Scenario: 前端 EngineEvent 解析硬契约

- **WHEN** isales-web 收到 WS 消息
- **THEN** 前端 SHALL 用 TypeScript discriminated union（`type` 字段）解析；遇到未知 `type` 字符串 SHALL 仅 console.warn 并跳过该消息，MUST NOT 整个连接断开；遇到字段缺失 / 类型错 MUST 仅 console.warn 跳过

#### Scenario: 新事件类型添加流程

- **WHEN** 后端引入新的 `EngineEvent` 子类型（如 `TokenBudgetExceeded`）
- **THEN** MUST 经 OpenSpec change 同步 isales-common 的 `EngineEvent` discriminated union；前端在该 change 实施时新增对应 handler；MUST NOT 后端先发新 type、前端后处理

### Requirement: 进程内 EventBus 通道

engine 的**单通话内**协调 SHALL 使用一个进程内、类型化、双车道的 EventBus（每个 `CallSession` 一个实例），取代手工接线的 `asyncio.Queue` + `asyncio.Event` + 跨任务 `task.cancel()` + `main.cancel()` sentinel。该 EventBus 是 § 通信通道矩阵之外的**进程内通道类型**——它 MUST NOT 跨进程、MUST NOT 序列化进 Redis；engine ↔ 其它服务的边界仍**只**走 Redis Queue / Pub/Sub（矩阵不变）。Redis 越界 SHALL 只发生在显式的 bridge 订阅者处（control 入站 → bus 事件;bus 事件 → `EngineEvent` 出站）。

#### Scenario: 双车道投递语义

- **WHEN** 一个事件被 post 到 EventBus
- **THEN** 按事件**类型**选车道：**无损道**（unbounded，`put_nowait` 物理不丢）SHALL 承载 ASR final、打断、挂断、lifecycle、control —— 一句用户 final MUST NOT 被丢；**有损道**（bounded，drop-oldest）SHALL 承载 ASR partial、音频帧、VAD
- **AND** 未显式注册车道的事件类型 SHALL 默认无损（永不静默丢弃）；只有显式 `register_lane(LOSSY)` 才能让某类型可丢

#### Scenario: 每-handler 异常隔离（强制）

- **WHEN** 某个订阅 handler 在处理事件时抛出非 `CancelledError` 异常
- **THEN** EventBus MUST 捕获并记录该异常、隔离它，**继续投递给同类型的其它 handler 并保持 dispatcher 存活**；一个坏 handler MUST NOT 拖垮 dispatch 循环或兄弟 handler
- **AND** `CancelledError` MUST 被重抛（不得吞掉）——打断的自取消依赖它

#### Scenario: 车道隔离与单写者

- **WHEN** 有损道涌入大量 partial/音频帧
- **THEN** 每车道一个 dispatcher 协程：车道内 SHALL 串行投递（无损道上无 CallSession 状态写竞争）、跨车道 SHALL 并发——有损道洪水 MUST NOT 延迟无损道上的一句 final
- **AND** 重 handler（LLM 管线）MUST post-and-spawn，MUST NOT 在 dispatcher 协程内内联阻塞

#### Scenario: 关闭时排空无损道

- **WHEN** 通话结束、EventBus 被 `aclose`
- **THEN** EventBus SHALL 先排空关闭前已入队的无损道事件再停止两个 dispatcher——保 shielded-finalize / DECR-snap-to-0 不变量（关闭前入队的 final / CallEnded MUST 仍被投递）；排空 SHALL 有界（关闭后 handler 再 post 的无损事件不致死循环）

### Requirement: 云-边控制面 gRPC bidi keepalive + idle-stream 抗性

Cloud-edge 控制面 gRPC bidi stream SHALL 通过 HTTP/2 keepalive ping
保持 liveness，并 SHALL 与中间网络层（Aliyun ECS 安全组 / SLB 七层
模式 / 客户机 NAT / 公司防火墙）的 stateful idle-cleanup 兼容。
本 Requirement 与既有 "云-边控制面 gRPC bidi 连通性" Requirement 并列，
**不**替代后者；它定义 transport-layer keepalive 的 Producer / Consumer
双方契约。

服务于 v1.0 商用形态（Windows 客户机在不可控网络环境下需要维持长 bidi
stream）+ dev / QA 形态（mac dev 机连真 cloud engine 进行 e2e 演练），
在 `macos-artc-pyobjc-binding` archive 时发现的"stream 1 ms 即被 cut"
问题（2026-05-19）需要本 Requirement 解决。

#### Scenario: edge gRPC client 启用 HTTP/2 keepalive 默认参数

- **WHEN** edge `CloudEdgeGrpcClient` 创建 gRPC channel
- **THEN** channel SHALL 通过 `grpc.aio.insecure_channel(endpoint,
  options=...)` 传入以下 keepalive 参数：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_pings_without_data = 0`
  - `grpc.http2.min_time_between_pings_ms = 10000`
  - `grpc.http2.min_ping_interval_without_data_ms = 10000`
- 即：edge 每 30 秒发一次 HTTP/2 PING，10 秒未收 ACK 视为 transport
  失败、走既有的 `_connect_loop` reconnect 路径
- 即使 stream 上当前无 RPC 活动，keepalive ping SHALL 照样进行（cloud-edge
  控制面大部分时间是 idle）

#### Scenario: cloud gRPC server 对称配置不踢 client ping

- **WHEN** cloud `CloudEdgeGrpcServer.start` 创建 `grpc.aio.server`
- **THEN** server SHALL 传入以下 options：
  - `grpc.keepalive_time_ms = 30000`
  - `grpc.keepalive_timeout_ms = 10000`
  - `grpc.keepalive_permit_without_calls = 1`
  - `grpc.http2.max_ping_strikes = 0`
  - `grpc.http2.min_time_between_pings_ms = 10000`
  - `grpc.http2.min_ping_interval_without_data_ms = 10000`
- **MUST NOT** 把 edge 的 30s 周期 ping 视为"过频"而 GOAWAY / RST_STREAM
  踢掉 stream（即 `max_ping_strikes = 0` 强制不计数）
- 即：cloud 与 edge 双向 keepalive 周期一致、互不踢，保证长 bidi stream
  在外部中间层有 stateful idle-cleanup 时仍存活

#### Scenario: stream 上线 + 上线时分别打 INFO 日志

- **WHEN** edge client 的 `_run_one_stream` 中 `call.initial_metadata()` 返回成功
- **THEN** SHALL 在 `_connected.set()` 之前打 INFO 日志 `cloud_edge_stream_connected`，
  携带 `endpoint` extra
- **WHEN** cloud server 的 `_handle_bidi` 中 `send_initial_metadata` 返回成功
- **THEN** SHALL 在 `_register_stream` 之前打 INFO 日志 `cloud_edge_stream_opened`，
  携带 `edge_device_id` extra
- 这两条 INFO 日志 SHALL 让 dev / ops 在 cloud-edge 稳定性诊断时**直接**
  看到 stream 真上线时刻，而不是只能间接看 `cloud_edge_stream_error` WARNING

#### Scenario: smoke 工具支持长时间 soak 验证

- **WHEN** `scripts/cloud_edge_smoke.py --soak <N>` 启动
- **THEN** SHALL 连接 cloud endpoint，stream 上线后每 30 秒发送一次 Heartbeat
  保持流活，每次 stream cut 记录 (start_ts, end_ts, lifetime_s)
- **THEN** SHALL 在 `N` 秒后退出，stdout SHALL 打印分布表（成功 stream 数 /
  总尝试 / p50 / p95 / max / min lifetime）
- **WHEN** 也传入 `--report-file <path>`
- **THEN** SHALL 把上述统计以 JSON 写到文件，供后续 acceptance.md 自动汇入

#### Scenario: cloud-side RUNBOOK 标明 50051 idle-timeout 配置

- **WHEN** ops 部署 / 排查 cloud-edge gRPC
- **THEN** `deploy/RUNBOOK-cloud.md` SHALL 含一节"50051 TCP idle-timeout
  配置"，列：
  - Aliyun ECS 安全组 inbound 50051 TCP 不要配 stateful idle-cleanup（如
    控制台提供此选项）
  - 如接入 SLB / WAF 在 :50051 前面，七层模式 idle-timeout SHALL ≥ 60 min；
    且 SLB SHALL 支持 HTTP/2 长连接
  - 验收命令：`cloud_edge_smoke.py --soak 600 --report-file report.json`
    应输出 p95 ≥ 300 秒

#### Scenario: 部署顺序：先升 server 再升 client

- **WHEN** rollout 本 Requirement 引入的配置
- **THEN** SHALL 先升级 cloud `isales-engine`（接受新 ping 行为）→ 再升级
  edge `isales-telephony`（开始发 ping）
- **MUST NOT** 反序（旧 server 默认 `max_ping_strikes` 大于 0，新 client
  30s ping 会被踢）

### Requirement: 云-边控制面 — gRPC 出站超时保护

云端 `CloudEdgeGrpcServer` 的 `_ServerStream.send()` SHALL 对出站队列 `put` 操作施加显式超时（默认 5 秒，可通过 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S` 配置）；超时后 SHALL 抛 `EdgeNotConnected`，上层走既有断连清理路径。本 Requirement 补完 `arch-cloud-edge-split` 中 "出站缓冲策略" 的半连接场景兜底。

#### Scenario: Edge 半连接导致出站队列满

- **WHEN** Edge 的 gRPC bidi stream 存在但 Edge 不消费出站消息（半连接状态），导致 `_outbound` 队列（maxsize=64）堆满
- **THEN** `_ServerStream.send()` SHALL 在 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S`（默认 5.0）秒后超时，抛出 `EdgeNotConnected(edge_device_id)`
- **THEN** 上层 `RtcTelephonyClient.dial()` 收到 `EdgeNotConnected` 后 SHALL 走既有断连处理路径（finalize session、DECR 并发计数器、标记 call_record 为异常结束）

#### Scenario: 正常 Edge 消费不触发超时

- **WHEN** Edge 正常消费出站消息（队列不满）
- **THEN** `send()` SHALL 立即成功，不受超时影响（`asyncio.wait_for` 在 put 立即返回时无额外开销）

#### Scenario: 超时值可配置

- **WHEN** 部署调优
- **THEN** 运维 MAY 通过环境变量 `ISALES_ENGINE_GRPC_SEND_TIMEOUT_S` 调整超时值；默认 5.0 秒 SHALL 覆盖绝大多数网络抖动场景；MUST NOT 设为 0（会导致所有 send 立即超时）

### Requirement: 通信故障的容错 — 半连接场景

本 Requirement 扩展 `arch-cloud-edge-split` 已有的 "通信故障的容错" 场景，新增 "半连接" 故障模式：云端 engine SHALL 把「应用层不消费消息但物理 stream 仍在」的 Edge 视为断连处理，受影响的 call_session MUST 走既有 finalize 清理路径，MUST NOT 永久卡在 `init` 状态占满并发槽。

#### Scenario: Edge 半连接等同于断连

- **WHEN** Edge 的 gRPC bidi stream 物理层存在但应用层不消费消息（如 Edge 进程卡死、事件循环阻塞、消费速率远低于推送速率）
- **THEN** 云端 engine SHALL 在 send 超时后把该 Edge 视为断连（`EdgeNotConnected`）；受影响的 call_session MUST 走既有 finalize 清理路径；MUST NOT 让 session 永久卡在 `init` 状态占满并发槽

### Requirement: 多 Edge 动态路由

云端 `CloudEdgeGrpcServer` SHALL 维护 `device_id → edge_device_id` 映射，支持多个 Edge 设备并行处理通话。Engine 下发 `DialCommand` 时 SHALL 根据 `DialRequest.device_id` 动态路由到拥有该 device 的 Edge，而非硬编码发给单一 Edge。

#### Scenario: Edge 通过 Heartbeat 注册 device 映射

- **WHEN** Edge 发送 `Edge2Cloud.Heartbeat` 且 `heartbeat.devices[]` 列表非空
- **THEN** 云端 SHALL 遍历 `devices` 列表，对每个 `device_health.device_id` 更新 `_device_to_edge[device_id] = edge_device_id`
- **THEN** 映射 SHALL 允许 device 在不同 Edge 间迁移（新 Heartbeat 覆盖旧映射）

#### Scenario: Edge 断连时清理 device 映射

- **WHEN** Edge 的 gRPC bidi stream 断开（`_deregister_stream`）且该 edge 未被同名新连接替代（非 displaced）
- **THEN** 云端 SHALL 清理该 edge_device_id 拥有的所有 device 映射条目
- **WHEN** 同一 edge 重连（displaced 旧流）
- **THEN** 映射 SHALL 保留（新连接会通过后续 Heartbeat 刷新）

#### Scenario: DialCommand 动态路由

- **WHEN** `RtcTelephonyClient.dial()` 执行且 `_legacy_edge_device_id` 为空字符串（动态路由模式）
- **THEN** SHALL 调用 `grpc_server.resolve_edge_for_device(state.device_id)` 获取目标 edge
- **THEN** SHALL 用返回的 edge_device_id 调用 `send_to_edge(target_edge, Cloud2Edge(dial=dial_cmd))`
- **WHEN** `resolve_edge_for_device` 找不到映射
- **THEN** SHALL 抛 `EdgeNotConnected`，走既有断连处理路径

#### Scenario: 向后兼容 — legacy 单 Edge 模式

- **WHEN** `ISALES_ENGINE_EDGE_DEVICE_ID` 环境变量非空
- **THEN** `RtcTelephonyClient` SHALL 使用该值作为所有 DialCommand 的目标 edge（行为与本 change 之前完全一致）
- **WHEN** `ISALES_ENGINE_EDGE_DEVICE_ID` 为空字符串
- **THEN** SHALL 启用动态路由模式；Engine 启动时 MUST NOT 因该值为空而报错退出

#### Scenario: hangup 使用路由结果

- **WHEN** 通话进行中需要 hangup（barge-in / admin 手动挂断）
- **THEN** SHALL 使用 dial 阶段路由确定的 `state.edge_device_id` 发送 `CancelCommand`，MUST NOT 重新路由（避免 device 在通话期间被其他 Edge 注册导致 cancel 发错目标）

### Requirement: 云-边控制面（cloud-edge gRPC bidirectional streaming）

云端 isales-engine SHALL 暴露唯一的 gRPC service `CloudEdge`（HTTP/2 over TLS）作为云-边控制面入口；边缘 isales-telephony SHALL 作为 gRPC client 建立长连 bidi stream；所有云-边控制消息 MUST 通过该 stream 流转，序列化形式 MUST 用 protobuf `oneof` 单 message。`.proto` 定义 SHALL 集中在 `isales-common/proto/cloud_edge.proto`，编译产物随 isales-common pip 包分发；MUST NOT 在 engine / telephony 仓库各自维护独立 schema。

#### Scenario: 服务定义

- **WHEN** isales-common 实施 `cloud_edge.proto`
- **THEN** 文件 SHALL 至少包含：
  ```proto
  syntax = "proto3";
  package isales.cloud_edge.v1;

  service CloudEdge {
      rpc Bidi (stream Edge2Cloud) returns (stream Cloud2Edge);
  }

  message Edge2Cloud {
      oneof payload {
          Heartbeat        heartbeat        = 1;
          DialAck          dial_ack         = 2;
          CallEvent        call_event       = 3;
          HardwareAlert    hardware_alert   = 4;
      }
  }

  message Cloud2Edge {
      oneof payload {
          Heartbeat        heartbeat        = 1;
          DialCommand      dial             = 2;
          CancelCommand    cancel           = 3;
          ConfigUpdate     config_update    = 4;
          RtcCredentials   rtc_credentials  = 5;
      }
  }

  message DialCommand {
      string call_id            = 1;
      int64  device_id          = 2;
      string number             = 3;
      string caller_id          = 4;
      string rtc_channel        = 5;
      string rtc_token          = 6;
      string rtc_uid_edge       = 7;
      string rtc_uid_engine     = 8;
  }
  // CallEvent / CancelCommand / Heartbeat / HardwareAlert / ConfigUpdate / RtcCredentials 细节
  // 由 impl 阶段补全，但 message 名称 SHALL 与本 spec 一致
  ```
- 任何对 message schema 的演进 MUST 通过 isales-common 版本 bump + 调用方与响应方同步升级

#### Scenario: gRPC 鉴权

- **WHEN** 边缘 gRPC client 建立 bidi stream
- **THEN** client SHALL 在 gRPC metadata 中携带 `authorization: Bearer <EDGE_DEVICE_TOKEN>`；server SHALL 验证 token，把 stream 绑定到具体 edge_device 身份；验证失败 SHALL 关闭 stream 并返回 UNAUTHENTICATED；token 签发方 SHALL 是云端 isales-api（与前端 JWT 同密钥来源但 audience 隔离），A2 阶段允许静态 token（一边缘机一 token，写入边缘 env）；多租户动态 token 由 C2 处理

#### Scenario: 心跳

- **WHEN** bidi stream 建立
- **THEN** 边缘 SHALL 每 30 s 发送 `Edge2Cloud.Heartbeat`；云端 SHALL 在收到后回 `Cloud2Edge.Heartbeat`（或在自己周期内回）；云端 watchdog SHALL 把超过 120 s 无心跳的边缘机所有 device 状态置 `offline`（复用 device-hardware spec 既有 watchdog 逻辑，运行位置由 modem-controller 心跳改为云端 worker 监听 cloud-edge stream 健康度）

#### Scenario: 断线重连与本地 buffer

- **WHEN** bidi stream 断连
- **THEN** 边缘 SHALL auto-reconnect with exponential backoff（初始 1 s，封顶 30 s，无限重试）；中断期间产生的 `CallEvent` / `HardwareAlert` SHALL 写入 `~/Library/Application Support/isales/sqlite/edge_buffer.db` 顺序追加；重连后 SHALL 按写入顺序补发 buffer 中尚未确认的事件 → server 显式 ACK 后从 buffer 删除；buffer 容量 SHALL 至少容纳 24 h 离线事件（按通话量估算 ≤ 100 MB），超容量 MAY 丢弃最早事件并打告警日志

#### Scenario: cloud → edge 命令丢失语义

- **WHEN** bidi stream 中断期间云端尝试发 `DialCommand` / `CancelCommand`
- **THEN** server SHALL 标记发送失败；`DialCommand` 失败 SHALL 由 scheduler 重试机制兜底（既有）；`CancelCommand` 失败 MUST NOT 重试（进行中通话允许由边缘 modem 自然超时挂断）；MUST NOT 设计任何"边缘上线后补发 Dial / Cancel"机制（避免错过的 dial 在边缘恢复时迟来打扰客户）

### Requirement: 云-边媒体面（阿里 RTC PaaS）

云端 isales-engine 与边缘 isales-telephony（audio-bridge 模块）SHALL 通过阿里 RTC PaaS（ARTC SDK for Linux Python / ARTC SDK for macOS Python）作为参会者入到同一 RTC 房间进行 PCM 双向音频流传输；MUST NOT 使用其他 WebRTC 实现（aiortc / pion / mediasoup 等）；MUST NOT 引入 IMS AICallKit 等托管智能体 SaaS。

#### Scenario: 一通通话一个 RTC 房间

- **WHEN** 云端 scheduler 派发 dial
- **THEN** 云端 engine SHALL 生成 `call_id` 作为 RTC `channel_id`；同时为 `engine-{call_id}` 与 `edge-{call_id}` 两个 uid 生成 RTC token；token 在 `Cloud2Edge.DialCommand` 中下发给边缘；双方 SHALL 各自调用 `JoinChannel(token, channel, uid, username, joinConfig)` 入会，role 均为 `publisher_subscriber`

#### Scenario: 入站 PCM 订阅

- **WHEN** 任一方入会成功
- **THEN** SHALL 用 `AudioFormatPcmBeforMixing` 模式订阅对端 PCM（不混音），通过 `OnSubscribeAudioFrame` 回调按 uid 过滤本通话对端 PCM；MUST NOT 订阅整房间混音流（避免万一房间内出现第三方 uid 时混入）

#### Scenario: 出站 PCM 推送

- **WHEN** 任一方有 PCM 出站（边缘是 modem mic 上行；云端是 TTS 下行）
- **THEN** SHALL 先调用 `SetExternalAudioSource(enable=True, sampleRate=<16k|24k>, channelsPerFrame=1)` 启用外部音频源（关掉默认麦克风采集），然后逐帧调用 `PushExternalAudioFrameRawData(audioSamples, sampleLength, timestamp)` 推帧；MUST 处理 `OnPushAudioFrameBufferFull` 反压回调（暂停 TTS chunk pull 或 modem 上行帧拉取，直到 buffer 排空）

#### Scenario: 通话结束离会

- **WHEN** 任一方收到 `CallEvent: remote_hangup` 或主动挂断
- **THEN** 该方 SHALL 调用 `LeaveChannel()` 离会；对端 SHALL 在 SDK 回调 `OnUserOffline` 中感知，触发自身 `LeaveChannel()` 离会；MUST NOT 让"僵尸"参会者残留在房间内（阿里 RTC 按参会者-分钟计费）

#### Scenario: RTC 凭证生命周期

- **WHEN** `DialCommand` 中下发的 RTC token 接近过期
- **THEN** 云端 engine MAY 通过 `Cloud2Edge.RtcCredentials` 主动下发新 token；边缘 SDK SHALL 用 `RefreshChannelToken()` 替换；A2 时点单通通话时长 ≤ token 默认有效期（典型 24 h），refresh 路径作为预留，A2 实施不强制完整测试

## Implementation Notes

通信通道的具体序列化（如 JSON / msgpack）SHALL 由各服务实现选定；建议 v1 全部用 JSON（便于调试），后续按需优化。
