## Why

当前 iSales 7 服务全部部署在客户现场单台 Mac mini（`architecture` spec L45-52 的 "v1 单主机部署"），形态阻塞两件事：(1) 无法 SaaS 多客户运营——每客户都得上门部署整套；(2) 无法集中 AI 推理与运维——LLM/裁判/润色都跑在客户机房，运维不可及。

唯一**真正**硬件耦合的是 `isales-telephony` 内的 modem-controller（USB GSM modem → AT 命令 + PCM 音频），其余 5 服务（api/engine/scheduler/worker/web）都纯软件，可以无依赖搬到云端。本 change 完成"5 上云 + 2 留边 + 云-边双向控制面与媒体面"的架构切分，作为 v1.0 云-边形态的基础。**这是 v1.0 一体发布的 10 个 openspec change 中的第 2 个（A 系列第 2 个，紧随已 ship 的 A1 `impl-real-at`）**；本 change 落地后才能跑 A3（边缘 VAD + 开场白预缓存）、D1（Windows 客户端原生 backend）等下游 change。

阿里 RTC server-side PoC（Day 1 纸面调研，[结果](../../v1-roadmap-aliyun-rtc-poc-result.md)）4.5/5 GO，媒体面方案已敲定为「阿里 RTC PaaS + IMS 纯通道接入方案」，blueprint 里原写的 aiortc + coturn fallback 用不到。

## What Changes

- **BREAKING** 部署拓扑：从「单主机 7 服务 + 直插 USB modem」改为「云端 5 服务（阿里云 ECS）+ 边缘 2 组件（modem-controller + 新增 audio-bridge）」。`architecture` spec 的 "v1 单主机部署" 与 `deployment-topology` 全部需要 spec delta。
- **新增云-边控制面**：gRPC bidirectional streaming over HTTP/2 + TLS，bearer token 鉴权。单条长连承载 (a) 心跳、(b) cloud→edge 指令（dial / cancel / config update）、(c) edge→cloud 事件（call state / hardware alert）、(d) RTC 房间凭证下发（AppId / channel / token / uid）。所有 payload 用 protobuf `oneof` 统一序列化。
- **新增云-边媒体面**：阿里 RTC PaaS。云端 engine 进程通过 ARTC SDK for Linux Python 作为参会者入到房间，按 `AudioFormatPcmBeforMixing` 模式订阅边缘上行 PCM、用 `PushExternalAudioFrameRawData` 推 TTS PCM 下行。边缘 audio-bridge（同进程内 ARTC SDK 客户端）从 modem 取 mic PCM 推上行、收云端下行 PCM 喂 modem speaker。AI 编排（多角色 PK / 流式 ASR/LLM/TTS）**全部在云 engine 进程内**，RTC 只作传输通道，**不进 IMS 智能体 SaaS / AICallKit**。
- **新增 audio-bridge 边缘组件**：与 modem-controller 同进程（isales-telephony 内新增模块），通过既有内部接口（音频环形 buffer）对接 modem-controller，对外与云端共享一个 RTC 房间。
- **engine session co-location**：v1.0 单 cloud instance，dial 触发后 engine session 在唯一实例本地起；barge-in cancel 经 gRPC stream 到这条 instance → 同进程直接 deliver，**不走 Redis Pub/Sub**。Redis Pub/Sub 接口抽象保留，多实例扩展时切换实现不改业务代码。
- **audio_pipe 新增 RTC backend**：`CaptureBackend` / `PlaybackBackend` 抽象新增 `AliyunRTCCapture` / `AliyunRTCPlayback` 实现，替代当前直接读写 modem PCM 设备的本地 backend。边缘侧 modem-controller 仍读写 PCM 设备，但接的是 audio-bridge 而非 engine。
- **dial 路径重构**：scheduler 下发 dial 不再走 `telephony-api HTTP /devices/select`，改走 `cloud → grpc bidi → edge modem-controller → AT 拨号 → audio-bridge join RTC room`。telephony-api 的 device-select / device-binding HTTP 接口在云-边形态下变成只服务于 isales-web 的设备查询（不再是控制面）。
- **端到端 latency budget 锚定 ≤ 800 ms**：modem 采音 → audio-bridge → 阿里 RTC → 云 engine → 豆包流式 ASR partial → 多角色 PK 首角色 LLM 首 token → 润色 → 豆包流式 TTS 首 chunk → RTC 下行 → 边缘 audio-bridge → modem 喇叭。跨厂商网络成本预算 70-100 ms（阿里云 ↔ 豆包公网），RTC 往返预算约 100 ms。
- 引入 dependency：`grpcio` / `grpcio-tools` / `protobuf` （云端 + 边缘）、阿里 ARTC SDK for Linux Python（云端 engine + 边缘 audio-bridge）、阿里云 Linux SDK 的 Windows 等价物（边缘 Mac mini 用 macOS SDK；Windows 边缘是 D1 范围）。

**故意不在本 change 范围**：
- 边缘 VAD / 开场白预缓存（A3 处理）
- 多租户 / tenant_id schema（C2 处理，本 change 仅引最小的 cloud-edge bearer token 鉴权）
- Windows 原生 backend（D1 处理；A2 假设边缘机仍是 macOS Mac mini，继续复用 macOS audio backend）
- 流式 ASR/LLM/TTS / barge-in 基础逻辑（已实装于 `impl-engine-providers`，本 change 仅迁移其物理位置）
- HA / 多 cloud instance（v1.0 单实例 100-1000 seats 够用，重启允许 30-60 s 中断）

## Capabilities

### New Capabilities

无。本 change 不引入新 capability spec——所有变更都体现在既有 spec 的 delta 上（`architecture` / `deployment-topology` / `service-communication` / `device-hardware` 四份），符合 feedback "不要凭空提新增机制"。

### Modified Capabilities

- `architecture`: 增加「云-边双套部署」requirement 取代当前的 "v1 单主机部署"；明确 5 服务上云 / 2 组件留边的归属；加入 engine session co-location 约束（cancel 不走 Redis）。
- `deployment-topology`: 拓扑从单主机 systemd 7 units 改为「云端 ECS systemd 5 units + 边缘 launchd / systemd 2 units (modem-controller + audio-bridge)」；端口规划（cloud 暴露 gRPC + isales-web HTTPS + telephony-api HTTPS；edge 不暴露任何公网端口）；阿里云基础设施清单（ECS / RDS PG16 / Redis / OSS / RTC AppId）。
- `service-communication`: 新增「云-边控制面 gRPC bidi」requirement，含 protobuf `oneof` 消息定义骨架（heartbeat / dial / cancel / config-update / call-event / hardware-alert / rtc-credentials）、TLS + bearer token 鉴权、断线重连与本地 SQLite 缓冲补发语义；标注 Redis Pub/Sub 在云-边链路里**不再承载实时 cancel**。
- `device-hardware`: 新增 audio-bridge 组件接口规格（与 modem-controller 的同进程环形 buffer 契约 + 与 ARTC SDK 的桥接职责）；明确 modem-controller 不再直接对接 engine，所有音频走 audio-bridge 中转。

## Impact

**仓库与代码影响**：

| 仓库 | 改动 |
|---|---|
| isales-engine | 新增 `transport/aliyun_rtc.py`（ARTC SDK 包装 + asyncio 适配）；`audio_pipe` 新增 `AliyunRTCCapture/Playback` backend；新增 `transport/grpc_server.py`（云端控制面 server）；engine session lifecycle 由 gRPC dial 触发而非 Redis 队列触发（保留 Redis fallback 接口）。 |
| isales-telephony | 新增 audio-bridge 模块（与 modem-controller 同进程，asyncio task）；新增 `transport/grpc_client.py`（边缘控制面 client）；本地 SQLite buffer 暂存离线事件；保留 telephony-api 但只服务于本地 isales-web 设备查询。 |
| isales-api | 仍然托管在云端；与 engine 同 ECS；不直接参与音频路径；新增 dial 入口转发到 scheduler / engine 的 gRPC 控制面。 |
| isales-scheduler | dial 不再调 telephony-api，改通过 engine 的 gRPC 控制面下发指令到边缘 modem-controller；其余调度逻辑不变。 |
| isales-worker | 不变（与边缘无直接交互；通话结束事件经 gRPC 上来后转 Redis queue 给 worker）。 |
| isales-web | 不变（仍直连 isales-api / telephony-api HTTPS）。 |
| isales-common | 新增 `proto/` 目录存放 `.proto` + 编译产物；`provider-abc` 接口不动。 |

**依赖与外部资源**：

- 新增 PyPI：`grpcio`, `grpcio-tools`, `protobuf`（cloud + edge 都装）
- 新增非 PyPI：阿里 ARTC SDK for Linux Python（压缩包从阿里云控制台下载，含 `.so` + Python wrapper，Python 3.6+）；边缘 Mac mini 用阿里 ARTC SDK for macOS
- 阿里云资源：ECS 4-8C / 16-32G RAM 1 台、RDS PostgreSQL 16、Redis（Tair 或标准 1G）、OSS bucket、RTC 应用（拿 AppId / AppKey）、域名 + Let's Encrypt 证书（gRPC + isales-api）
- 计费量级（参考 PoC 结果 §6）：纯音频 ¥6 / 千分钟 / 参会者；100 seats × 1 h/天 × 22 天/月 × 2 端 ≈ ¥1.6 k / 月

**变更链接**：

- 已 ship：A1 `impl-real-at`（archived，commit `7e9adeb` 之前）—— SerialATClient + canonical hangup_cause，A2 依赖此基础
- 并行：D1 `windows-client-core`（A2 propose 阶段 reference，spec delta 冲突归档时再 merge；A2 假设边缘机型 macOS，D1 处理 Windows）
- 下游：A3 `edge-vad-and-opener-prefetch`（边缘 VAD 与开场白预缓存依赖 A2 控制面 cancel 通道与 OSS 接口）

**Risk & 缓解**：

| 风险 | 缓解 |
|---|---|
| ARTC SDK 服务端 PCM 回调延迟 / 帧长未在文档量化（PoC §3 标注待 Day 2 实测） | Day 2 实测脚本在 Sprint 0 期间跑（不阻塞本 propose）；如延迟 > 100 ms，design.md 需要补"音频 jitter buffer 在云端 engine 内的位置" |
| `PushExternalAudioFrameRawData` 的 buffer-full 触发频率不明 | 已知有 `OnPushAudioFrameBufferFull` 反压回调；TTS chunk pull 应 await 这个 signal，design.md §媒体面 必须画反压链路 |
| 多角色 PK 三层流水（N 角色 + N×M 裁判 + 1 润色）在 800 ms budget 内端到端是否仍达标 | design.md "latency budget" 节做毫秒级推演，必要时缩小 N / M 默认值或允许裁判提前剪枝 |
| 边缘断网 → 进行中通话 | 控制面 gRPC auto-reconnect + 本地 SQLite buffer 补发离线事件；进行中通话允许 modem 自然挂断，符合"v1.0 不做 HA" |
| Mac mini 远程运维（A2 时边缘仍是 Mac mini，D1 才换 Windows） | A2 范围内不解决，留 D2 `hardware-observability` 处理告警与一键诊断 |
