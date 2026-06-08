## MODIFIED Requirements

### Requirement: 通信通道矩阵

各服务 SHALL 按以下表使用对应通道；MUST NOT 引入未列出的通道（除非经 change proposal）。云-边拆分后通道矩阵更新：

| 从 | 到 | 通道 | 用途 | 物理位置 |
|---|---|---|---|---|
| scheduler | engine | Redis Queue | "拨打这条线索"（消息体含 lead 信息 + 历史摘要 + prompt_versions 快照） | 云内 |
| engine | worker | Redis Queue | "通话已结束，请处理" | 云内 |
| api | engine | Redis Pub/Sub | 实时控制（手动挂断、转人工指令） | 云内 |
| engine | api | Redis Pub/Sub | 通话事件推送（状态变更、ASR 文本） | 云内 |
| api | scheduler | Redis Queue | 启动 / 暂停 Campaign | 云内 |
| **cloud (engine) ↔ edge (telephony)** | **cloud-edge gRPC bidi stream** | **拨号 / 挂断 / 通话事件 / 硬件告警 / RTC 房间凭证 / 心跳** | **跨云-边** |
| **cloud (engine) ↔ edge (audio-bridge)** | **阿里 RTC PaaS（Opus over DTLS-SRTP）** | **PCM 双向音频流（upstream + downstream）** | **跨云-边** |
| modem-controller | audio-bridge | 同进程 asyncio Queue / 环形 buffer | PCM 双向 + AT 命令结果 + udev / heartbeat 事件 | 边缘进程内 |
| modem-controller | USB GSM modem | AT 命令（`/dev/ttyUSB*`）+ 音频（macOS 平台音频 IO，Windows 由 D1 处理） | 物理设备控制 | 边缘 |
| modem-controller / audio-bridge | 边缘本地 SQLite | 直连 | 离线事件 buffer + 边缘本地设备状态缓存 | 边缘 |
| worker | 外部 | HTTP | Webhook 回调外部业务系统 | 云内 |
| 云端全部 | PostgreSQL（阿里云 RDS） | 直连（通过 isales-common 模型） | 数据持久化 | 云内 |
| 云端全部 | Redis（阿里云 Redis） | 直连 | 队列、缓存、计数器 | 云内 |

#### Scenario: 通道选型一致性

- **WHEN** 引入新的服务间调用
- **THEN** 调用 SHALL 复用上表中已有的通道与协议风格；如需新增通道（如 WebSocket），MUST 经 change proposal 明确论证；云-边通信 MUST 仅走 cloud-edge gRPC bidi 与阿里 RTC PaaS 两个通道，MUST NOT 在云-边之间引入 HTTP / Redis 直连

#### Scenario: 旧 engine → modem-controller IPC 已下线

- **WHEN** 实施本 change 后云端调度通话
- **THEN** 云端 engine MUST NOT 通过 Unix socket / 本机 WebSocket 与 modem-controller 通信（云-边已不共主机）；所有原走 IPC 的指令 SHALL 改走云-边 gRPC bidi（控制指令）+ 阿里 RTC PaaS（音频流）；本 change 之前 device-hardware spec 中 "engine ↔ modem-controller IPC 协议" 在云-边拆分后的等价物在 device-hardware spec delta 中定义

### Requirement: 队列与 Pub/Sub 的边界

Redis Queue SHALL 用于"必须送达，可异步处理"的工作派发；Redis Pub/Sub SHALL 用于"实时、可丢失"的事件广播。Redis Queue / Pub/Sub 通道 SHALL 仅在云内使用，MUST NOT 跨云-边边界（云-边通信走 gRPC bidi）。

#### Scenario: 适合 Queue 的场景

- **WHEN** 消息丢失会导致业务遗漏（如未拨打 lead、未处理通话结束）且通信在云内
- **THEN** 通信 MUST 用 Redis Queue（含确认与重试）

#### Scenario: 适合 Pub/Sub 的场景

- **WHEN** 消息延迟敏感且偶尔丢失可接受（如前端实时监控通话状态）且通信在云内
- **THEN** 通信 SHALL 用 Redis Pub/Sub

#### Scenario: 云-边方向禁止直接转发 Pub/Sub

- **WHEN** 云内 `engine:control` 或 `engine:events` Pub/Sub 产生消息
- **THEN** MUST NOT 直接 fanout 到云-边 gRPC stream；如需把"实时控制"传到边缘（如手动挂断），SHALL 由 engine 内 dispatcher 转译为 `Cloud2Edge.CancelCommand` 或类似 protobuf 消息，经云-边 gRPC 下发

### Requirement: HTTP 调用规范

服务间同步 HTTP 调用 SHALL 限制到必要场景（v1.0 云-边拆分后**云内不再有跨服务同步 HTTP 调用**：scheduler 不再走 telephony-api，dial 经 engine 的云-边 gRPC 控制面）；其他通信 MUST 走 Redis 队列 / Pub/Sub（云内）或 cloud-edge gRPC（云-边）。

#### Scenario: scheduler 不再 HTTP 调 telephony-api

- **WHEN** scheduler 派发新通话
- **THEN** MUST NOT 通过 HTTP 调用边缘 telephony-api 的 `POST /devices/select`；选 device 逻辑 SHALL 改由云端 scheduler 基于云内 PG 查询完成（device 状态由边缘经 cloud-edge gRPC `CallEvent` / `HardwareAlert` 上报 + 云端 watchdog 维护），dial 指令直接经 engine cloud-edge gRPC `DialCommand` 下发到边缘

#### Scenario: 边缘 telephony-api HTTP 角色降级

- **WHEN** 边缘机本地运维 / 本地 isales-web（如有）需要查询设备
- **THEN** 边缘 telephony-api MAY 仍提供 HTTP `GET /devices` 等本地查询接口；MUST 限制监听到 loopback 或本机内网；MUST NOT 暴露公网

#### Scenario: 外部 webhook 走 HTTP

- **WHEN** worker 触发 callback
- **THEN** SHALL 用 HTTP POST/PUT 等（具体 method 由 callback_config 配置），细节见 webhook-callback

### Requirement: 通信故障的容错

各服务 SHALL 对依赖（Redis / PostgreSQL / 云-边 gRPC / 阿里 RTC）的短暂不可用有容错策略；MUST 重连并优雅清理受影响的 call_session。

#### Scenario: Redis 短暂不可用

- **WHEN** Redis 连接中断（云内）
- **THEN** 各云端服务 SHALL 重连重试（带退避）；engine 中断重连期间 MUST 不接受新拨号但 MAY 完成当前通话

#### Scenario: PostgreSQL 短暂不可用

- **WHEN** DB 连接失败
- **THEN** 各云端服务 SHALL 重连重试；正在通话中的 engine MUST 把通话状态缓存至 Redis（v2 优化），v1.0 则在 DB 不可用时按异常通话处理

#### Scenario: 云-边 gRPC 中断

- **WHEN** 边缘 gRPC client 与云端 server 之间连接中断（任一方原因：边缘断网 / 云端 engine 重启 / TLS 续期失败）
- **THEN** 边缘 SHALL auto-reconnect with exponential backoff（初始 1 s，上限 30 s）；中断期间产生的 `CallEvent` / `HardwareAlert` SHALL 写入边缘本地 SQLite buffer 顺序补发；中断期间云端 `DialCommand` / `CancelCommand` 允许丢失（scheduler 重试机制兜底；进行中通话由边缘 modem 自然超时挂断）；云端 engine SHALL 把超过 120 s 无心跳的边缘机所有 device 状态置 `offline`

#### Scenario: 阿里 RTC 媒体面中断

- **WHEN** 进行中通话的 RTC 房间断连（任一参会者）
- **THEN** ARTC SDK 内部 SHALL 尝试 ICE 重协商 / 重连；超过 SDK 内置超时（按 SDK 默认）仍未恢复 SHALL 触发 `OnConnectionLost` 回调；engine / audio-bridge 收到后 SHALL 把对应 call_session 标记为 media_lost；call_session SHALL 触发挂断流程（modem 侧由 modem-controller AT+ATH 挂断，云端 engine 写 transcript hangup 事件）；RTC 中断 MUST NOT 自动 retry 房间（短时中断由 SDK 处理；长时中断走挂断而非重新拨号）

## ADDED Requirements

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

## MODIFIED Requirements

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
