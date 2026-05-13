## Context

iSales 当前形态（A1 已 ship 的 SerialATClient 之后）：7 服务跑在客户机房一台 Mac mini（或同等单 Linux 主机）上，USB GSM modem 直插同主机。`architecture` spec 的 "v1 单主机部署" requirement 是这条路线的硬契约。问题不是 v1 单主机错了——MVP 阶段它是对的——而是产品要进入 SaaS 形态、要把 AI 推理与运维都集中到云端，单主机形态必须演进。

**v1.0 的 10-phase 一体发布**（[v1-roadmap](../../v1-roadmap.md)）把整个演进切成 10 个 openspec change：A1 → A2 → A3 → B1 → B2 → C1 → C2 → D1 → D2 → D3。**本 change = A2，是 A1 之后影响面最大的一步**，其他 8 个下游 change 都依赖 A2 把控制面 / 媒体面 / engine session 位置定下来。

**关键前置已完成**：
- A1 `impl-real-at` 已归档（meta `680fa2e` + isales-telephony `acff6aa`），云端能驱动真 modem 的 AT 通道、canonical hangup_cause 已就位
- 阿里 RTC server-side PoC Day 1 已完成（[结果](../../v1-roadmap-aliyun-rtc-poc-result.md)），4.5/5 GO，本 design 直接采纳 PoC 结论而不再做选型讨论；Day 2 实测延迟数据在 Sprint 0 期间补齐，不阻塞本 propose

**并行 change**：D1 `windows-client-core`。A2 假设边缘机型仍是 macOS Mac mini；D1 处理 Windows 原生 backend。A2 与 D1 共享 `device-hardware` / `deployment-topology` 两份 spec delta，归档时按"先归档先写盘 + 后归档手工 merge"处理。

**stakeholder**：
- 产品（你）：批准云-边拆分这一步、批准阿里 RTC PaaS 作为媒体面、确认 ¥1.6k/月 计费量级可接受
- engine / telephony 开发：实现 ARTC SDK 接入 + audio-bridge + gRPC bidi 控制面
- 运维：阿里云资源开通（ECS / RDS / Redis / OSS / RTC AppId / 域名 / TLS）+ Sprint 0 准备

## Goals / Non-Goals

**Goals**：

1. 5 服务（api / engine / scheduler / worker / web）可在阿里云单 ECS 上跑通端到端通话
2. 2 边缘组件（modem-controller + 新增 audio-bridge）在 Mac mini 跑通，**仅通过云-边 gRPC + RTC 与云端交互**，不再依赖云-边同主机的 Unix socket
3. 端到端语音 latency P95 ≤ 800 ms（modem 麦 → 云 ASR → 云 LLM → 云 TTS → modem 喇叭）
4. barge-in cancel 路径：边缘检测开口的能力本身在 A3 处理，**A2 把 cancel 通道做出来**（gRPC 控制面 cancel 消息 + engine session 同进程 deliver，不走 Redis）
5. 多角色 PK / 流式 ASR-LLM-TTS / 垫词 / 时间窗口 / 跟进重试 这些"已实装的机制"全部继续工作，**仅迁移其物理位置**，不动业务语义
6. 部署形态文档化：deploy/cloud / deploy/edge 两份 systemd / launchd unit + RUNBOOK
7. MVP 验收点：Windows / Mac mini 边缘机插真 modem → 云端 5 服务跑 → 自己手机响铃 → 接通 → **听到 AI 念开场白** → 挂断（此场景 A2 + D1 都落地后做）

**Non-Goals**：

- 流式 ASR/LLM/TTS / barge-in 决策点迁移（A3）
- 边缘 VAD / 开场白预缓存（A3）
- 多租户 / tenant_id schema（C2；本 change 仅引最小的 cloud-edge bearer token）
- Windows 原生 audio backend / WASAPI / tray app（D1）
- 硬件观测 / 告警 / 一键诊断（D2）
- MSI 安装包 / OTA 升级（D3）
- HA / 多 cloud instance / 跨地域容灾
- aiortc / coturn 自建 SFU 路线（PoC 已 GO，fallback 不展开）
- 数据迁移：A2 上线前现网无客户在跑，**不做** existing single-host → cloud-edge 的数据迁移；新环境从零开始

## Decisions

### Decision 1：NAT 穿透 / WebRTC 服务端 = 阿里 RTC PaaS + IMS 纯通道接入方案

**选项**：

- (A) 阿里 RTC PaaS + IMS 纯通道接入 ← **选定**
- (B) 阿里 IMS AICallKit（托管智能体）
- (C) 自建 coturn + aiortc SFU

**采纳 (A) 的理由**（依据 [PoC 结果](../../v1-roadmap-aliyun-rtc-poc-result.md) §1 决策表 4.5/5 GO）：

- 阿里官方 ARTC SDK for Linux Python 完整支持服务端入会（`JoinChannel(token, channel, userid, username, joinConfig)`）+ 按 uid 分流 PCM 回调（`OnSubscribeAudioFrame`）+ 外部 PCM 推送（`SetExternalAudioSource` / `PushExternalAudioFrameRawData`）+ buffer-full 反压（`OnPushAudioFrameBufferFull`）
- IMS 「RTC 纯通道接入方案」明确"AI 服务编排需要您自己实现"，**iSales 在云端 engine 进程内跑多角色 PK 不进 IMS 智能体 SaaS**，与本项目核心卖点（多角色 PK 管线）完全解耦
- 阿里云生态：DB / Redis / OSS 同生态 → ECS ↔ RTC 内网走，省一次 + 减少跨厂商网络成本
- 阿里 BGP / 全球节点 → 跨地域客户端到 ECS 的质量比自建 coturn 单点强

**排除 (B) 的理由**：AICallKit 内置 ASR/LLM/TTS 编排，与多角色 PK 管线冲突；即使能配自研 LLM，N×M 裁判 + 1 润色这种"管线内多次 LLM 调用 + 流式输出归并"在 SaaS 里做不出来。

**排除 (C) 的理由**：PoC 已确认 (A) 可行，(C) 是 fallback；自建增加运维负担（coturn 安全组 / TURN 凭证轮转 / aiortc 单进程并发上限 50-100 / Opus FEC 调参），且阿里 RTC 单价（纯音频 ¥6/千分钟 ≈ ¥1.6k/月 @ 100 seats）已被接受。

### Decision 2：云-边音频拓扑 = 双方都作为 RTC 参会者入同一房间

```
┌────────── 边缘（Mac mini，A2 时点）──────────┐
│ modem-controller                            │
│  ├── AT 命令 → /dev/ttyUSB*                 │
│  └── PCM 音频（双向环形 buffer）              │
│        ↑↓                                   │
│ audio-bridge（同进程，asyncio task）         │
│  └── 阿里 ARTC SDK 客户端                    │
│        - JoinChannel(channel=call_id,       │
│          uid="edge-{call_id}", role=        │
│          publisher_subscriber)              │
│        - SetExternalAudioSource(8k/16k)     │
│          + PushExternalAudioFrameRawData    │
│          （把 modem mic PCM 上行）            │
│        - OnSubscribeAudioFrame(uid=         │
│          "engine-{call_id}", pcm) →         │
│          modem speaker 环形 buffer          │
└─────────────────────────────────────────────┘
                    ↕ 阿里 RTC PaaS（公网，UDP DTLS-SRTP）
                    ↕ channel=call_id
┌────────── 云端（阿里云 ECS）──────────────────┐
│ isales-engine                               │
│  └── transport/aliyun_rtc.py                │
│        - JoinChannel(channel=call_id,       │
│          uid="engine-{call_id}", role=      │
│          publisher_subscriber)              │
│        - OnSubscribeAudioFrame(uid="edge-…",│
│          pcm) → audio_pipe 入站              │
│        - SetExternalAudioSource(16k or 24k) │
│          + PushExternalAudioFrameRawData    │
│          （TTS 流出站）                       │
└─────────────────────────────────────────────┘
```

**关键约束**：

- 一通通话 = 一个 RTC channel，channel id = `call_id`（由云端 scheduler 下发 dial 时生成）
- 双方都用 `publisher_subscriber` 角色（既订阅对端 PCM 又推自己 PCM）
- 按 `AudioFormatPcmBeforMixing` 模式订阅，按 uid 过滤本通话对端（避免万一同房间多参会者时混入）
- 边缘 audio-bridge 与 modem-controller **同进程**，通过 asyncio Queue / 环形 buffer 解耦音频时钟（modem 8 kHz vs RTC 16 kHz 由 audio-bridge 重采样）
- 云端 engine 与 ARTC SDK **同进程**，PCM 回调直喂 `audio_pipe` 入站 buffer（多角色 PK 上游就是这个 buffer）；TTS 出站 chunk 直接 push 进 SDK

### Decision 3：AI 编排归属 = 全部在云 engine 进程内，RTC 只做传输通道

- **不进 IMS 智能体 SaaS**（不调 AICallKit / AUIAICall / 服务端启动智能体 API）
- 多角色 PK（N 角色并发 LLM + N×M 裁判 + 1 润色）+ 流式 ASR/LLM/TTS 全部跑在云 engine 进程
- LLM provider 走 OpenAI 兼容接口对接豆包 / 通义 / 智谱（已在 v1-roadmap.md L451-470 锁定 v1.0 范围）
- ASR / TTS 固定豆包流式（已实装于 `impl-engine-providers`）
- **不在 A2 范围**：替换 ASR/TTS provider；改 LLM provider 接入层（B1 处理 tool-calling）

### Decision 4：端到端 latency budget ≤ 800 ms

| 段 | 预算 (ms) | 备注 |
|---|---|---|
| modem 麦采音 + GSM codec → modem-controller PCM | 20-40 | 8 kHz / 20 ms 帧；GSM AMR 解码 |
| modem-controller → audio-bridge 环形 buffer | < 5 | 同进程 |
| audio-bridge → ARTC SDK encode → 边缘出网 | 20-40 | Opus encode + DTLS-SRTP |
| 阿里 RTC 传输（边缘 → 云端 SFU → 云端订阅者）| 40-80 | 跨地域 RTT；阿里内网经 RTC PaaS |
| 云端 ARTC SDK decode + 回调 → engine audio_pipe | 10-30 | Opus decode + Python callback |
| engine ASR 流式（首 partial）| 100-200 | 豆包流式 ASR，首 partial 一般 ≤ 200 ms |
| **多角色 PK 流水首 TTS byte** | 200-400 | N 个角色 LLM 流式 + N×M 裁判 + 润色合并，首 TTS chunk 触发 |
| TTS 出站 → ARTC SDK encode → 推到 RTC | 20-40 | 类同入站对称段 |
| RTC 回边缘 → audio-bridge → modem-controller | 40-80 | 类同入站对称段 |
| modem playback → 喇叭 | 20-40 | 8 kHz / GSM AMR 编码下行 |
| **合计 P95** | **470-955** | 多角色 PK 中位数 ~ 600-700 ms 可达 |

**预算紧但可达**。多角色 PK 段（200-400 ms）是最大变量，由 v1-roadmap "AI Provider 策略" 决定的 LLM 选型（豆包 pro / 通义 turbo 等）实测。**若 P95 突破 800 ms，本 design 接受运行时把 N 角色并发降到 1（退化为单角色 + 单裁判 + 单润色），保 latency 达标作为运行时降级策略**，不阻塞 A2 ship。

### Decision 5：云-边控制面 = gRPC bidirectional streaming over TLS，protobuf `oneof` 单 message

**协议骨架**（具体 `.proto` 在 impl 阶段写入 `isales-common/proto/cloud_edge.proto`）：

```proto
service CloudEdge {
    rpc Bidi (stream Edge2Cloud) returns (stream Cloud2Edge);
}

message Edge2Cloud {
    oneof payload {
        Heartbeat               heartbeat        = 1;
        DialAck                 dial_ack         = 2;
        CallEvent               call_event       = 3;   // ringing / connected / remote_hangup / device_error
        HardwareAlert           hardware_alert   = 4;   // signal_lost / sim_arrears
        RtcSdpAnswer            rtc_sdp_answer   = 5;   // 预留：若直接走 SDP，A2 暂不用（用 RTC PaaS 的话信令在 SDK 内部）
    }
}

message Cloud2Edge {
    oneof payload {
        Heartbeat               heartbeat        = 1;
        DialCommand             dial             = 2;   // {call_id, device_id, number, caller_id, rtc_channel, rtc_token, rtc_uid_edge, rtc_uid_engine}
        CancelCommand           cancel           = 3;   // {call_id}, barge-in or admin 主动挂断
        ConfigUpdate            config_update    = 4;
        RtcCredentials          rtc_credentials  = 5;   // 预留：若 dial 之外另外下发凭证
        RemoteDiagnostic        remote_diag      = 6;   // 预留：D2 用
    }
}
```

**鉴权**：bearer token via gRPC metadata；边缘启动时通过激活码（C2 引入）换取长 token，或 A2 阶段用静态 `EDGE_DEVICE_TOKEN` 写在 `/etc/isales/env/edge.env`（cloud-edge bearer token 概念在 A2 引入最小版，多租户 token 体系到 C2 完整化）。

**心跳**：30 s 一次（与既有 modem-controller heartbeat 同节拍）。120 s 无心跳 → cloud 端把边缘所有 device 状态置 `offline`（复用 device-hardware spec 既有 watchdog 逻辑，运行在云 worker）。

**断线**：

- 边缘 gRPC client auto-reconnect with exponential backoff
- 边缘**本地 SQLite** buffer 离线期间产生的 `CallEvent` / `HardwareAlert`，重连后顺序补发
- 中断期间 cloud → edge 的 `Dial` 命令**允许丢失**（scheduler 重试机制兜底）
- 中断期间 cloud → edge 的 `Cancel` 命令**允许丢失**，进行中通话由边缘 modem 自然超时挂断
- RTC 媒体面与 gRPC 控制面**独立**断连/重连，互不阻塞

**Engine session co-location**：dial 触发后 engine session 在唯一 cloud instance 本地起；cancel 经 gRPC 进入 cloud instance → 通过 cloud instance 内进程间 asyncio dispatcher 直接 deliver 给对应 engine session，**不经 Redis Pub/Sub**。这是 v1-roadmap 已锁定的决定（L421-424），本 design 把它落到具体的 cancel 路径上。

**Redis Pub/Sub 不在云-边链路里**：原 `service-communication` spec 表中 "api ↔ engine Pub/Sub" 改为云内调用（同 ECS 内），与边缘无关；MUST NOT 把云内 Pub/Sub 事件直接转发到边缘 gRPC 上（信号过多、且时序敏感）。

### Decision 6：服务拆分清单

| 服务 / 组件 | 物理位置 | 进程形态 |
|---|---|---|
| isales-api | 云端 ECS | systemd unit |
| isales-engine | 云端 ECS | systemd unit；内嵌 ARTC SDK + gRPC server |
| isales-scheduler | 云端 ECS | systemd unit |
| isales-worker | 云端 ECS | systemd unit |
| isales-web（nginx 静态资源 + 反代） | 云端 ECS | systemd nginx unit |
| PostgreSQL | 云端（阿里云 RDS PG16 托管） | 托管 |
| Redis | 云端（阿里云 Redis Tair 或标准 1G 托管） | 托管 |
| OSS bucket | 云端阿里云 | 对象存储 |
| modem-controller | 边缘 Mac mini | launchd / systemd unit（A2 时点是 macOS launchd） |
| audio-bridge | 边缘 Mac mini | 与 modem-controller 同进程的 asyncio task |
| telephony-api | 边缘 Mac mini | launchd / systemd unit；A2 后仅服务边缘本地的设备查询（不再是云调用入口） |

**telephony-api 角色降级**：原本是 scheduler 的"选 device + 拨号"HTTP 入口；A2 后 scheduler 在云端，dial 走 gRPC 到边缘 modem-controller，**telephony-api 的 `POST /devices/select` 接口在云-边链路中不再使用**。telephony-api 仍保留，给边缘机本地的 isales-web（如果有的话）和运维 CLI 查询设备状态用——但 A2 时点 isales-web 已迁云，telephony-api 实际上变成边缘维护接口（保留但 dormant，类似 human-handoff 的处理方式）。

**云端 5 服务进程拓扑**与 `architecture` spec 既有图基本一致，仅把 modem-controller 这块从云抠掉、把 gRPC server 加到 engine 上。

### Decision 7：边缘机 v1.0 仍是 Mac mini（A2 时点）

A2 假设边缘机型 = macOS Mac mini（沿用 `impl-deploy-macos` change 已 ship 的 launchd 部署形态）；D1 `windows-client-core` 处理 Windows 原生 backend。两个 change 平行推进，**A2 不引入 Windows 任何代码**，仅在 `device-hardware` spec delta 中标注"Windows backend 由 D1 提供"占位（避免与 D1 spec delta 冲突 conflict）。

## Risks / Trade-offs

- **[ARTC SDK 服务端 PCM 回调延迟未文档化]** → Day 2 实测脚本（[PoC §8](../../v1-roadmap-aliyun-rtc-poc-result.md#8-day-2-实测脚本sprint-0-期间执行)）在 Sprint 0 期间跑，把决策表"实测"列补齐。如延迟 P95 > 100 ms，本 design Decision 4 的 latency budget 需要重新分配（多角色 PK 段从 400 → 300 ms，或 N×M 默认值收紧）。
- **[`PushExternalAudioFrameRawData` buffer-full 触发频率不明]** → 已知有 `OnPushAudioFrameBufferFull` 反压回调，impl 阶段 TTS chunk pull task 必须 await 这个 signal（参考 PoC §4 反压链路）。如 buffer-full 高频触发导致 TTS 抖动，回退到"先攒满 N 个 chunk 再 push"，或调大 SDK 内部 buffer。
- **[多角色 PK 三层流水在 800 ms budget 内是否仍达标]** → Decision 4 给出降级策略（N 降到 1 + 单裁判）；如实测仍不达标，A2 ship 时把默认 campaign 配置改为单角色 + 单裁判 + 单润色，C1 控制台允许老板提升到多角色。多角色 PK 不是被砍，是默认值收敛。
- **[边缘断网期间进行中通话]** → modem 自然挂断；本地 SQLite buffer 补发 `CallEvent: remote_hangup`；scheduler 重试机制（既有）会重新派发该 lead。**不做** "本地接管 AI 编排" 这种重型 fallback。
- **[Mac mini 远程运维成本]** → A2 范围内不解决；D2 `hardware-observability` 处理（告警 + 一键诊断 + 远程诊断包上传 OSS）。A2 把硬件事件经 gRPC 上来的通道做出来，给 D2 用。
- **[ARTC SDK 压缩包交付，不在 PyPI]** → impl 阶段把 SDK 解压到 `deploy/vendor/aliyun-artc-linux-python/`（云端）和 `deploy/vendor/aliyun-artc-macos-python/`（边缘），由 `pip install -e .[vendor]` 之类的方式从本地路径安装（或者直接 `sys.path.insert` 引入）；`requirements.txt` 加 `aliyun-artc @ file://...` 形式 pin 路径；具体方式 impl 阶段决定。
- **[PoC Q5 计费量级 ¥1.6k/月 未含 IMS 套餐细节]** → 工单已稿（PoC §9），impl 阶段开通 RTC AppId 前与阿里云销售确认是否有"含 RTC + 服务端 SDK"的套餐包，若有则 design 不变、运营成本结构调整。
- **[gRPC bidi 单连承载 7 种 oneof message]** → message 模型扩展性靠 protobuf `oneof` 加新分支；但 message 太多会让 reflection 不直观。impl 阶段如果发现某类事件高频（如 hardware alert 信号强度上报），考虑拆出独立 server-streaming 通道（与 bidi 控制面并存）。

## Migration Plan

A2 上线**前**现网没有客户在跑（v1.0 一体发布尚未 ship 任何客户），所以**没有 production 数据迁移问题**。impl 阶段顺序：

1. **Sprint 0 准备**（与 A2 impl 并行）：阿里云开通 ECS 4C16G + RDS PG16 + Redis 1G + OSS bucket + RTC AppId + 域名 + Let's Encrypt 证书
2. **isales-common：proto + transport 抽象**（先于云 / 边）：
   - `isales_common/proto/cloud_edge.proto` 写定，`make proto` 生成 Python stub
   - `isales_common/transport/abc.py` 抽象云-边 client / server 接口（边缘 ↔ 云端 RPC）
   - `isales_common/audio/rtc_backend.py` 抽象 RTC capture / playback backend（云 / 边复用）
3. **云端 engine 引入 ARTC SDK 与 gRPC server**：
   - `transport/aliyun_rtc.py` 包装 ARTC SDK，asyncio 适配
   - `transport/grpc_server.py` 起 cloud_edge.Bidi server，监听边缘心跳 / 事件
   - `audio_pipe.py` 新增 `AliyunRTCCapture/Playback` backend
   - engine session lifecycle 接 gRPC `Dial` 触发
4. **边缘 audio-bridge + gRPC client**：
   - `isales-telephony` 增 `audio_bridge/` 模块，与 modem-controller 同进程
   - `transport/grpc_client.py` 起 cloud_edge.Bidi stream，maintain SQLite buffer
   - modem-controller 改为推 PCM 到 audio-bridge 而非 engine
5. **部署脚本**：
   - `deploy/cloud/` 阿里云 ECS provision + 5 服务 systemd unit + nginx 配置
   - `deploy/edge/` Mac mini launchd + audio-bridge + modem-controller
6. **端到端验证**：本地一台 Mac mini + 一台云 ECS（QA 环境），单 modem + 自己手机 → 拨通 → 听到回声测试音；然后接入 ASR/LLM/TTS 念开场白
7. **MVP 验收**：Windows 边缘机（D1 落地后）+ 云 ECS → 真客户号码呼入 → 听到 AI 开场白 → 挂断；A2 + D1 联合验收

**Rollback**：A2 没有"回退到单主机"的语义——一体发布的 v1.0 体系中不存在"双形态共存"。如果 A2 实施后发现致命问题，rollback = 阻塞下游 change 推进、修 A2、再发；不是改架构。

## Open Questions

1. **ARTC SDK 安装路径**：vendor 目录 + `pip install -e file://...` vs 写 `setup.py` 把 SDK 打成本地包？→ impl 阶段决定，本 design 不锁
2. **边缘 SQLite buffer 大小上限**：离线多久的事件保留？→ 默认 24 h，超过丢弃 + 告警；impl 阶段最终值由 worker watchdog 配合决定
3. **RTC channel id 是否复用 call_id**：本 design 假设 channel_id = call_id（简单 1-to-1）；如果未来要支持"多个 dial-out 共用一个房间"则需重新设计 → v1.0 不会有这场景，本设计 1-to-1 OK
4. **gRPC bidi 单连 vs 多连**：本 design 走单连承载所有 payload；如果某类消息（如 hardware alert）频繁到打爆 bidi 单流，impl 阶段考虑加独立 server-streaming 通道 → 本 design 不预先优化
5. **云 engine 进程 ARTC SDK 并发上限**：单进程能稳定承载多少路 channel？阿里 SDK 文档未明确单进程上限。Sprint 0 实测；如有限制（如 50 路），design 影响：v1.0 单实例 100-1000 seats 中的"1000 seats" 实际指峰值并发 50-100，符合 v1-roadmap "100-1000 seats 规模" 的口径 → 不阻塞
