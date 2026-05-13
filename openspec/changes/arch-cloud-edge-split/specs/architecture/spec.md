## MODIFIED Requirements

### Requirement: v1 单主机部署

v1.0 SHALL 采用**云-边双套部署**：5 个软件服务（api / engine / scheduler / worker / web）部署在云端单实例（阿里云 ECS）；2 个边缘组件（modem-controller + audio-bridge）部署在客户机房的边缘机；USB GSM modem 直插边缘机。云端与边缘**MUST NOT 共主机**。多 cloud instance 横向扩展 MUST 列入 v2。

#### Scenario: 云端服务部署

- **WHEN** v1.0 投产
- **THEN** 阿里云 ECS（4-8 核 / 16-32G RAM）SHALL 运行：`isales-api` / `isales-engine` / `isales-scheduler` / `isales-worker` / `nginx-isales-web` 五个 systemd unit；PostgreSQL 与 Redis SHALL 使用阿里云托管服务（RDS PostgreSQL + Redis Tair / 标准版），MUST NOT 自建于 ECS 内

#### Scenario: 边缘组件部署

- **WHEN** v1.0 投产
- **THEN** 边缘机（macOS Mac mini 或 Windows PC，平台后端归 D1）SHALL 运行 `isales-telephony` 单一 entry point 进程，进程内含两个 asyncio task：modem-controller（AT 命令 / PCM 设备 IO）与 audio-bridge（阿里 ARTC SDK 客户端 / 与 modem-controller 的环形 buffer 桥接）；MUST NOT 在边缘机部署 api / engine / scheduler / worker / web / DB / Redis 任何之一

#### Scenario: 不引入容器编排

- **WHEN** v1.0 实施
- **THEN** 云端 5 服务 MUST 通过 systemd 直接管理，MUST NOT 在 v1.0 引入 Docker / Docker Compose / Kubernetes；边缘组件 SHALL 通过 macOS launchd 或 Linux systemd 直接管理

#### Scenario: 单 cloud instance 限制

- **WHEN** v1.0 部署
- **THEN** cloud 端 SHALL 单 ECS 实例运行；deploy / 重启期间允许 30-60 s 服务中断；活跃通话允许中断；MUST NOT 假设跨 cloud instance 状态共享；Redis Pub/Sub 与 Queue 接口抽象保留以支持未来 v2 多实例扩展，但 v1.0 实现允许退化为单实例同进程 IPC

### Requirement: 各仓库职责边界

每个仓库 SHALL 承担明确的职责边界，跨仓库的功能 MUST 在设计阶段拆分到具体仓库主导。云-边拆分后，仓库职责更新如下：

| 仓库 | 职责 | 规模 | 物理位置 |
|---|---|---|---|
| isales-common | SQLAlchemy 模型 / Pydantic Schemas / Provider ABC（ASR/TTS/LLM）/ Alembic 迁移 / utils / **proto 定义 cloud_edge.proto 与编译产物** / **cloud-edge transport 抽象** | 小 | 共享库 |
| isales-api | 管理后台 CRUD（Campaign/Lead/Role/Voice/Analytics/Callback）+ WS 代理 | 中 | 云端 |
| isales-engine | 实时通话引擎：状态机 / AI 三层管线 / 打断/沉默/垫词 / ASR/TTS/LLM Provider 实现 / **阿里 ARTC SDK server-side 入会 / cloud-edge gRPC server** | 大 | 云端 |
| isales-scheduler | 线索分发 / 时间窗口 / 重试与跟进 / 拨打前打包历史摘要；**dial 指令经 engine 的 cloud-edge gRPC 控制面下发** | 小 | 云端 |
| isales-worker | 通话结束后的摘要 / 字段提取 / Webhook 回调 / 数据聚合 | 中 | 云端 |
| isales-telephony | 单一边缘进程，asyncio 任务组：modem-controller（AT 命令 / PCM 设备 IO / udev / pyserial polling）+ audio-bridge（阿里 ARTC SDK 客户端 / PCM 重采样 / 与 modem-controller 同进程环形 buffer 桥接）+ cloud-edge gRPC client + 本地 SQLite 离线 buffer；保留 telephony-api HTTP 入口仅服务边缘本地的设备查询 / 运维 | 中 | **边缘** |
| isales-web | Vue 3 前端（任务/线索/角色/音色/设备/数据看板/通话监控） | 中 | 云端（nginx 反代） |

#### Scenario: 跨仓库职责重叠

- **WHEN** 引入新功能
- **THEN** 设计阶段 MUST 明确归属一个仓库；MUST NOT 把同一职责分散到多个仓库（但一个职责可能跨多仓库分阶段执行——如转人工触发由 engine、派发由 worker、查询由 api）

#### Scenario: 云-边职责边界

- **WHEN** 引入新功能涉及音频或通话控制
- **THEN** AI 编排（ASR / LLM / TTS / 多角色 PK / 流式管线）MUST 归属云端 engine；硬件直接控制（AT 命令 / PCM 设备 IO / 物理 USB）MUST 归属边缘 modem-controller；云-边媒体桥接 MUST 归属边缘 audio-bridge；MUST NOT 在云端进行 AT 命令拼装、MUST NOT 在边缘进行 LLM 调用

### Requirement: 数据存储统一

所有云端服务 SHALL 共享一个 PostgreSQL 实例与一个 Redis 实例，两者均托管在阿里云。所有数据库迁移 MUST 由 isales-common/alembic 管理。边缘 isales-telephony 进程 MUST NOT 直接读写云端 PG / Redis；边缘 SHALL 通过 cloud-edge gRPC 控制面让云端代为读写。

#### Scenario: 数据库共享

- **WHEN** 任何云端服务读写数据
- **THEN** MUST 通过 isales-common 的 SQLAlchemy 模型；MUST NOT 直接写 SQL 绕过 ORM 模型（除性能必要场景外）；连接目标 MUST 是阿里云 RDS PostgreSQL 而非自建 PG

#### Scenario: Redis 用途

- **WHEN** 云内服务间通信或缓存
- **THEN** Redis SHALL 用作：① 队列（scheduler→engine、engine→worker、api→scheduler）② Pub/Sub（云内 api↔engine 实时控制与事件推送，**MUST NOT 直接转发到边缘 gRPC**）③ 全局并发计数器（INCR/DECR）④ 缓存

#### Scenario: 边缘不直连云端数据存储

- **WHEN** 边缘 isales-telephony 进程需要读取 / 写入业务数据（如 device 状态、call_event、hardware_alert）
- **THEN** 进程 MUST 通过 cloud-edge gRPC 控制面把事件 / 查询请求发到云端 engine / api；MUST NOT 直接 TCP 连接云端 PG / Redis；边缘 MAY 维护本地 SQLite 仅用于离线 buffer 与本地设备元数据，但**不**作为权威数据源

### Requirement: 内部 HTTP 服务的统一 JWT 鉴权

`isales-api` 与边缘 `telephony-api` SHALL 共享同一套 JWT 鉴权体系：isales-api 为唯一签发方，telephony-api 仅验证；HMAC 签名密钥经环境变量分发到两个服务。**云-边 gRPC 控制面 SHALL 使用独立的 bearer token**（与前端 JWT 隔离），由云端 isales-api 签发给具体边缘机，写入边缘 `/etc/isales/env/edge.env`；A2 阶段引入最小静态形态（每边缘机一个 token），多租户 / 激活码动态形态由 C2 处理。

#### Scenario: isales-api 是唯一 JWT 签发方

- **WHEN** 前端用户登录
- **THEN** SHALL 由 isales-api 签发 JWT；MUST NOT 由 telephony-api 或任何其他服务签发；telephony-api 不暴露 `/login` 等签发端点

#### Scenario: telephony-api 仅验证 JWT

- **WHEN** 边缘 telephony-api 收到来自本地 isales-web / 运维工具的 HTTP 请求
- **THEN** SHALL 用与 isales-api 相同的密钥验证 JWT；MUST NOT 自行刷新或重签发；验证失败 SHALL 返回 401

#### Scenario: HMAC 密钥经环境变量分发

- **WHEN** 部署 isales-api 与边缘 telephony-api
- **THEN** 共享 HMAC 密钥 SHALL 通过环境变量（命名约定 `ISALES_JWT_SECRET`）注入两个服务；MUST NOT 在 DB 或代码中写死；MUST NOT 经 isales-common 的 Python 模块导出

#### Scenario: 云-边 gRPC 控制面使用独立 token

- **WHEN** 边缘 isales-telephony 进程建立云-边 gRPC bidi stream
- **THEN** 客户端 SHALL 在 gRPC metadata 中携带 `authorization: Bearer <EDGE_DEVICE_TOKEN>`；该 token MUST 与 `ISALES_JWT_SECRET` 签发的前端 JWT 来源 / 用途隔离（不同密钥 / 不同 audience）；云端 engine gRPC server SHALL 验证该 token 并把请求绑定到具体 edge_device_id；验证失败 SHALL 关闭 stream

#### Scenario: 服务间内部调用免 JWT（云内）

- **WHEN** 云端 scheduler 调用 cloud 内部 telephony 资源（A2 后云端不再有 telephony-api，本场景退化为云内服务相互调用如 api↔engine）
- **THEN** v1.0 单 cloud instance 内 MAY 免 JWT；云内服务通信 SHALL 限制在 ECS 内网；多实例扩展（v2）MUST 引入服务账号 JWT 或 mTLS

#### Scenario: JWT 配置不属于 isales-common 业务范围

- **WHEN** 在 isales-common 添加内容
- **THEN** isales-common MUST NOT 提供 JWT 签发函数；MAY 提供 JWT 验证的工具函数（如解码与签名校验），前提是不绑定特定密钥来源

## ADDED Requirements

### Requirement: Engine session 与 cloud instance co-location

v1.0 单 cloud instance 部署下，dial 触发后 engine session SHALL 在唯一 cloud instance 本地起；与该 session 相关的 cancel / 实时控制 SHALL 经云-边 gRPC 控制面进入 cloud instance 后由同进程 asyncio dispatcher 直接 deliver 给 engine session 对象，MUST NOT 经 Redis Pub/Sub 中转。Redis Pub/Sub 接口抽象保留以支持未来 v2 多实例扩展。

#### Scenario: cancel 不走 Redis

- **WHEN** 用户在通话中开口（A3 边缘 VAD 检测；A2 阶段允许由 admin 主动触发）触发 barge-in cancel
- **THEN** cancel 事件 SHALL 经云-边 gRPC `Edge2Cloud.CallEvent`（或 `Cloud2Edge.CancelCommand` 反向）进入 cloud instance；instance 内 asyncio dispatcher SHALL 按 call_id 查找当前 engine session 对象 → 直接调用 session.cancel()；MUST NOT 走 `engine:control` Redis Pub/Sub channel

#### Scenario: dial 派发同进程优先

- **WHEN** scheduler 派发新通话给 engine（云端进程内调用）
- **THEN** v1.0 单 instance 下 SHALL 走同进程 asyncio queue / 直接函数调用；Redis Queue 接口保留但单实例下视为退化路径；engine session 起在派发该 dial 的同一进程内

#### Scenario: 多实例扩展（v2）

- **WHEN** 未来 v2 升级到多 cloud instance
- **THEN** Redis Pub/Sub / Queue 抽象 MUST 切换为跨实例实现；业务代码 MUST NOT 因此重写（仅切实现）；MUST 经 OpenSpec change proposal 论证 sticky session / consistent hashing / Redis Streams 等具体路线

### Requirement: AI 编排归属云端

ASR / LLM / TTS / 多角色 PK / 流式管线 / 垫词 / barge-in 决策等 AI 编排能力 SHALL 全部运行在云端 engine 进程内。MUST NOT 把 AI 编排卸载到云厂商提供的"AI 智能体接入" SaaS（如阿里 IMS AICallKit / AUIAICall）。云-边媒体面（阿里 RTC PaaS）SHALL 仅作传输通道使用，遵循 IMS「RTC 纯通道接入方案」语义。

#### Scenario: 不调用 IMS 智能体 SaaS API

- **WHEN** 云端 engine 接通通话
- **THEN** engine 进程内 SHALL 自行编排 ASR / LLM / TTS 调用；MUST NOT 调用阿里 IMS 的 `StartAIAgent` / `AICallKit` 等托管智能体启动接口；MUST NOT 通过 IMS 控制台配置预置 ASR / LLM / TTS pipeline

#### Scenario: 多角色 PK 在云端单进程

- **WHEN** 一通通话进入多角色 PK 管线
- **THEN** N 个角色 LLM + N×M 裁判 LLM + 1 个润色 LLM 的并发调用 SHALL 全部在该 engine session 所在的云端 instance 内进程并发；MUST NOT 跨进程 / 跨主机分布；选 provider 与 model 严格按 v1.0 AI Provider 策略（豆包 / 通义 / 智谱 OpenAI 兼容接口）

#### Scenario: 边缘不参与 AI 编排

- **WHEN** 边缘 audio-bridge 收到来自 modem 的上行 PCM
- **THEN** SHALL 仅做 PCM 重采样 + Opus 编码 + RTC 推流；MUST NOT 调用任何 ASR / LLM / TTS provider；MUST NOT 在边缘加载语音模型 / LLM 模型（边缘 VAD 由 A3 处理，不属本 change 范围）
