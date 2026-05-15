# Stage-9 设计草稿：iSales 云-边拆分

## Context

当前 iSales 7 个服务全部部署在客户现场一台 Mac mini 上（impl-deploy-macos PR #1–#12
已落地 + 归档）。modem-controller + Core Audio I/O 是唯一硬件耦合环节（USB GSM
modem，A7670E 类），其余 5 个服务（api / engine / scheduler / worker / web + db /
redis）逻辑上 cloud-friendly。

讨论结论（2026-05-12）：拆成**云-边**——边缘只做 modem AT 控制 + 音频转发，
ASR / LLM / TTS 全在云端。

## 边界已定的部分

**边缘**（一台 / 现场，硬件耦合）：
- `modem-controller`：AT 命令、USB 设备监听、`device.last_seen_at` 心跳
- `audio bridge`（新组件）：modem mic PCM → Opus → 上传云；云下行音频 → 解码 →
  modem speaker。20 ms 帧，建议走 WebRTC（自带 jitter buffer + 丢包恢复 + NAT
  穿透 via TURN）或 RTP over DTLS。WebSocket 二进制帧次选，缺 RTP 的时序语义。
- 控制面长连接（gRPC bidi stream 或 WebSocket）：心跳 + 接拨号指令 + 推通话事件
  / 状态机更新 / DTMF。

**云端**：api / engine / scheduler / worker / web / db / redis 直接搬。`engine`
新增 SFU-side 消费者：把入站 PCM 喂 streaming ASR，TTS 流式回 PCM 喂 SFU。

## 时延预算重新分层（关键）

PR #4 那条 p95 ≤ 200 ms 指标**保留**——它针对的是本地音频回环（modem speaker
→ mic loopback），对回声/AEC 有意义，云-边拆分不改这一层。

新增三条对话级指标：

| 指标                         | P50      | P95      | P99      | 说明 |
| ---------------------------- | -------- | -------- | -------- | ---- |
| 云-边音频单程                | ≤ 50 ms  | ≤ 80 ms  | ≤ 150 ms | Opus 编解码 + WAN（中国同区域） |
| 用户说完到 AI 首音节出声     | ≤ 500 ms | ≤ 800 ms | ≤ 1200 ms | "感知响应时间"，行业可接受范围 |
| 端到端 barge-in 切断响应     | ≤ 200 ms | ≤ 400 ms | ≤ 600 ms | 用户打断到云端停 TTS + 边缘停播 |

**为什么是 500/800 ms 而不是 200 ms**：拆出来的 budget 大头是 LLM 首 token
（200-600 ms 视模型）+ 流式 ASR 首字（150-300 ms）+ TTS 首 byte（100-300 ms）。
即使把每一步都流水线起来，理论下限 ~400 ms。人类电话对话 turn gap 200-500 ms，
现代 AI voice (OpenAI Advanced Voice / Twilio AI) 公开声明 sub-500 ms，500 ms
P50 / 800 ms P95 是合理目标。

## 必须做的三件事

### 1. 流式全链路（streaming everything）

- **流式 ASR**：豆包 / Volcengine 流式接口、faster-whisper streaming 或类似，
  消费 20 ms PCM 帧实时吐 partial transcript（每 200-500 ms 一个），靠 VAD +
  silence + 标点检测出 final。
- **流式 LLM**：用 Anthropic / Volcengine streaming API，partial transcript +
  完整对话上下文一并喂入，token 一来就转 TTS。
- **流式 TTS**：豆包 / Volcengine TTS 流式接口，输入 token 流，输出 PCM/Opus
  流，首 byte ~150 ms。
- 整条链路从"等用户说完 → 等 ASR 出完 → 等 LLM 完 → 等 TTS 完"改成"边说边
  听 / 边出边播"。

### 2. Barge-in（用户随时打断）

- **VAD 在边缘**：本地 VAD（py-webrtcvad / silero-vad）准确度够、延迟低
  （<20 ms）；放云端要多吃 WAN RTT 不划算。
- 用户开口 → 边缘立刻 stop playback + drop queued audio + 上控制面 cancel 信号
- 云端 engine 收到 cancel → 中止 in-flight LLM 生成 → 抛掉未发的 TTS chunk
- 新 utterance 立刻进入 ASR 管线
- 关键设计：边缘的播放队列要支持立即清空、云端 LLM 调用要传 cancellation
  token，TTS 调用同样。

### 3. 预缓存开场白 + 高频追问句

- 每个 campaign 的固定开场白（"你好，这是 XX 公司"）和高频追问（"请稍等"、
  "明白了"、"那您现在方便吗"）在 campaign 编辑时预渲染 TTS，PCM/Opus 缓存到
  云对象存储 + 边缘启动时拉到本地。
- 拨号后边缘**先放预缓存开场白**，同时云端 ASR/LLM pipeline 在背后预热——
  用户听到的第一句是 0 ms 冷启动延迟。
- 单 campaign 一次性预渲染、复用千百次，TTS 成本下来。

## 关键文件 / 复用路径

- **现有的 audio_pipe**（isales-telephony/isales_telephony/modem_controller/
  audio_pipe.py）：跨平台 orchestrator + 平台 backend Protocol 已经 PR #1 重构
  完，**正好是云-边拆分的天然切点**——把 backend 从 `MacOSCoreAudioCapture/
  Playback` 换成 `WebRTCBridgeCapture/Playback`（推 Opus 上云、收 Opus 下播），
  audio_pipe orchestrator 不动。
- **at_client.ATClient Protocol**（同仓 modem_controller/）：边缘进程实现，云
  engine 通过 gRPC stub 调用。stage-8 `impl-real-at` 落地的 SerialATClient 直接
  搬到边缘进程内即可，云端不持有 SerialATClient 实例。
- **engine 现有 ASR/LLM/TTS provider 接口**（isales-engine/）：豆包 +
  OpenAI Provider 已在 `impl-engine-providers` 阶段实装；流式版本需要新增 /
  扩展接口（多数 provider SDK 都自带 streaming，主要是 wrapper 改成 async
  generator）。
- **WebRTC stack**：Python 端 `aiortc`（同步实现 SDP / ICE / DTLS-SRTP）是
  最自然选择；信令走自己的 control plane WebSocket，不依赖 STUN/TURN
  公网服务（自建 coturn 即可）。

## 验证方式

1. **本地双进程 PoC**：同机起 `edge-bridge`（modem-controller + aiortc client）+
  `engine-mock`（aiortc server + 假 ASR/LLM/TTS，按时序模拟首 token / 首 byte
  延迟），用 loopback 跑通整条流。
2. **跨机 PoC**：edge-bridge 留 Mac mini，engine 搬到云上一台机器（火山引擎 /
  阿里云 ECS），WAN 跨网，跑同一通话脚本，测三条新指标 P50/P95/P99。
3. **真硬件 + 真 LLM**：A7670E + 真豆包 ASR/LLM/TTS provider key，自己手机接
  听 3 轮对话，验证 barge-in 真能在 400 ms 内切断。

## 边缘交付形态：客户的 Windows PC（2026-05-12 决定）

不出整机硬件，**边缘以 Windows 客户端形态交付到客户自己的 PC**。

**产品定位反推**：
- 目标客户：个人销售 / SOHO / 个体户 / 小型电销团队（非数据中心 / 非工业现场）
- 1 个销售坐席 = 1 台 Windows PC + 1 个 USB GSM modem + 1 张 SIM 卡
- 销售模式：SaaS 订阅，零硬件费，按 AI 坐席数 / 通话分钟数计费

**对架构 / 代码的反推**：
1. **平台扩到 Windows**：要加第三个 backend
   - USB watcher：复用 PR #2 的 `pyserial.tools.list_ports.comports()` 1 Hz polling
     方案，Windows 同样有效，零新代码 ✅
   - 音频 backend：新写 `WindowsWASAPICapture/Playback`，`sounddevice` (PortAudio)
     透明走 WASAPI，工作量类比 macOS Core Audio backend ≈ 1 周
   - 服务托管：装系统服务（pywin32 包成 Windows Service）或者更轻量——登录时
     自启的 tray app（任务栏图标 + "暂停 / 继续 / 退出"菜单）
2. **24/7 假设作废**：边缘是销售自己的工作 PC，会睡眠 / 重启 / 断网
   - 调度器必须识别"边缘掉线"状态，不再向掉线坐席分配 lead
   - call_record / transcript 云端权威，边缘只缓冲未上报的事件
   - WAN 断连保护：边缘自动挂断在线 modem + 拒接新拨号指令，等控制面恢复
3. **多 modem 单机部署被堵死**：一台员工 PC 不会插 4 个 modem
   - 1 modem / 1 PC / 1 坐席是默认形态
   - 中大型电销公司 = 在 N 台员工 PC 上装 N 套客户端，云端把它们当 N 个独立坐席
4. **客户支持基础设施**：必须提供
   - 签名 MSI 安装包（无签名会被 SmartScreen 拦）
   - 内置升级器（拉云端 release manifest，diff 后台升级）
   - 远程诊断通道：tray app 一键"打包诊断包"上传，云端工程师可读 + 反向控制面
     发"重启模块"指令

**对暂未决定项的影响**：
- SIM 卡形态：分散，每客户自有 SIM，集中 SIM pool 这条不走
- modem 选型：USB Audio Class 仍是硬需求（Quectel EC25-AUDIO 或同级），客户
  自购 / 公司发货皆可，价格 ¥200-500/枚
- 调度策略：lead 分配按"坐席 = 客户员工"绑定，不存在按地理 / 号段跨客户调度

## 主战客户与运营模式（2026-05-12 决定）

**主战客户**：中小型电销公司，10-100 坐席规模。SOHO / 个人销售作为兼容副线。

**角色 + 工作流（boss-driven）**：
- 老板 / 公司管理员：tenant 视图。上传 lead 池 → 创建 campaign 选择 goal type
  + AI 模板 + 指定坐席 → 看实时监控 + 报表 + 通话明细
- 员工：seat 视图。Windows 客户端被动接拨号指令，**不参与对话**。员工的实际
  工作是**硬件运维**：处理 SIM 欠费、modem 挂机、信号差告警、SIM 卡可能被封
  等异常。员工客户端的"厚"功能集中在硬件健康可观测性上。

**员工 Windows 客户端 UX 决定**：
- Tray 图标三态色（绿正常 / 橙警告 / 红故障）+ 桌面通知
- 一键诊断面板：测试拨号到固定号、显示 USB 设备、重启 modem 服务、查
  AT+CSQ 信号强度、AT+CUSD 余额查询（运营商相关）
- 硬件事件日志：今日 SIM 卡 / modem / 信号事件记录
- "工作中 / 暂停"二态切换
- 不需要：通话录音播放、lead 浏览、客户管理、销售统计——这些都在云端 web

**Lead 流转**：
- 老板上传 → lead 进库（多租户隔离，lead 归 tenant_id）
- 老板创建 campaign 时**指定派给哪些 seats**，scheduler 在指定 seat 集合内
  按"在线 + 当前不忙"分配 lead
- 员工无 lead 列表 UI、无主动抢单 / 选择能力
- 通话产物（goal_payload）回写 lead，老板看到后续跟进

## AI Goal 多场景化（2026-05-12 决定）

产品定位为**可配置的 AI 外呼平台**，不绑某个垂直。Campaign 级别可选 goal type：

| Goal Type        | 转化点                          | 结构化产物 schema |
| ---------------- | ------------------------------- | --------------------- |
| `contact_capture`| AI 引导客户报微信号 / 备用电话  | `{wechat_id?, phone_alt?, name?}` |
| `intent_grading` | AI 通过问诊问题给客户打意向度档 | `{intent_grade: A/B/C/D, reason}` |
| `oral_order`     | AI 谈下口头下单 + 数量 / 时间    | `{order_intent: bool, qty?, delivery?}` |
| `custom`         | 老板自定义 prompt + 字段抽取    | `{...customer-defined fields}` |

**对 isales-engine 的反推**：
- 需要 goal-aware 抽象层：每个 goal type 对应一套 prompt 模板（system + user
  脚手架）+ 一套 tool definition（让 LLM 在对话中触发 function call 提取字段）
- 通话产物落库：`call_record` 表扩 `goal_type: text` + `goal_payload: jsonb`
  两字段；engine 把 LLM 的 tool call 结果序列化写入
- 现有 engine 的 conversation provider 接口要扩展为 streaming + tool-calling
  两个维度（streaming 已为云-边拆分需要，tool-calling 是 goal-aware 需要）

**Vertical preset 库**（运营资产，**产品护城河**）：
- 保险电销、教育招生、中介房产、餐饮预约、SaaS 销售、教培续班…
- 每个 vertical 提供：开箱 prompt 模板 + 推荐 goal type + 范例 lead 字段
  schema + 范例话术回放
- 商业模式延伸：模板市场、行业话术专家咨询、定制 vertical 包

## 暂未决定 / 待后续讨论

- 客户端打包技术栈：纯 Python + PyInstaller MSI、Electron + Python 子进程、
  抑或纯 .NET 桥接 Python——影响升级器复杂度与安装包体积、签名成本。
- 多席位"集中管理"：老板控制台具体功能优先级（campaign 编辑、坐席监控、
  报表、通话回放、AI 模板编辑）。
- 计费模型：按席位月 / 按通话分钟 / 按成单转化数 / 三档套餐；对公付款 +
  发票流程。
- 通话录音 / transcript 隐私：录音是否上云端、老板能否回放全部 / 仅成单、
  数据合规（个保法、通话录音告知义务）。
- WAN 断连音频缓冲长度（一次通话 5 分钟，断网期间是直接挂断还是本地继续
  录到磁盘等恢复后补传）。
- SIM 卡运营：员工自有 SIM / 公司发卡，欠费 / 封卡处理流程，可能跟运营商
  打通批量充值或物联卡 API。
## Openspec change blueprint（10 个待开 change，对应 10 个 phase）

**整体性质（必读）**：10 个 change 是产品 v1.0 的**一体发布单元**，中间任何
单个 change 落地都不构成可交付产品。Change 之间的 dependency 链是 **A1 →
A2 → A3 → B1 → B2 → C1 → C2 → D1 → D2 → D3**（线性，部分可并行）。`/opsx:
propose` 不必一次提 10 个，按依赖到了再开 proposal——但路线一旦启动就要走到
D3 才算完。

每个 change 给出 **change name 候选 / 1 句问题陈述 / 1 句方案纲要 / 触及的
openspec capabilities / 依赖前置 change**。`spec deltas` 指 `openspec/changes/
<name>/specs/<capability>/spec.md` 要写入的修订；`capabilities (impacted)` 是
此 change 必然要触及的现有 main spec（如不写 delta 也要决定保持现状）。

---

### A. 技术地基

#### change A1 — `impl-real-at`
- **问题**：modem-controller `main.py` 硬编码 `MockATClient`，engine 调用通过
  Protocol 但实际没真打通 modem，整套 AI 外呼 = 纸面。
- **方案**：实现 `SerialATClient` 桥接 `drivers.ModemDriver`（已存在的 AT
  serial 抽象）↔ `at_client.ATClient` Protocol（engine 消费）；`main.py` 按
  环境 dispatch（默认 SerialAT，CI/dev 仍可选 MockAT）。
- **specs (deltas)**: `device-hardware`（AT 客户端真实化的契约）、`call-state-
  machine`（真硬件 ATD/CONNECT/HANGUP 状态转换覆盖）。
- **依赖**：无（前置全部就绪，PR #12 的 12.1 真硬件验证已完成）。

#### change A2 — `arch-cloud-edge-split`

> **Status 2026-05-15 (late)**：propose 已落 (`openspec/changes/arch-
> cloud-edge-split/`)，impl 43/63 tasks done。已 ship 部分：
> - isales-common v0.2.x（proto + transport + audio ABC + 27 tests）
> - isales-engine PR #1-7（AliyunRtcSession + gRPC server + dispatcher
>   + RtcTokenIssuer + RtcTelephonyClient + **heartbeat_handler + hardware_
>   alert_handler** + 244 tests）
> - isales-telephony PR #1-4（CloudEdgeGrpcClient + audio_bridge +
>   SqliteEventBuffer integration + 53 new tests）
> - **isales-scheduler PR (3fc6750)**：dial path retires telephony-api
>   HTTP, `device_selection.pick_idle_device` (FOR UPDATE SKIP LOCKED) +
>   39 tests
> - **isales-api PR (5b6e92e)**：`/edge-devices/status` endpoint +
>   `isales-edge-token-mint` CLI + 23 new tests
> - meta-repo deploy/cloud + deploy/edge skeleton + RUNBOOK-cloud/edge +
>   `openspec/v1-roadmap-a3-context.md` (A3 propose-stage hand-off)
>
> **剩 20 tasks**：Sprint 0 物料 (1.1/1.2/1.4/1.5)、3.3/3.4 由 PR #5
> RtcTelephonyClient 路径替代、5.5 + 12.x e2e (需 ECS + RTC AppId)、
> 7.1/7.3/7.7 edge destructive (modem-controller 改造)、8.x macOS SDK
> mock 路线 obsolete、13.2-13.3 PoC Day 2 + archive prep。
>
> 归档前等 D1 windows-client-core 也接近完成（共享 device-hardware /
> deployment-topology spec delta 需要手工 merge）。

- **问题**：当前 7 服务全部部署在客户现场单台 Mac mini，无法 SaaS 多客户运营、
  无法集中 AI 推理；isales-telephony 内 modem-controller 已是唯一硬件耦合点。
- **方案**：api/engine/scheduler/worker/web 5 服务搬云端；Mac mini 留 modem-
  controller + 新增 `audio-bridge` 组件（**阿里 RTC PaaS 客户端**，2026-05-13
  PoC 4.5/5 GO 后从 aiortc fallback 切回）；新增云-边控制面（**gRPC bidi
  stream over TLS**，bearer token + 心跳 + dial / cancel / config update /
  call event / hardware alert）；audio_pipe 新增 `AliyunRTCCapture/Playback`
  backend；engine session co-location（dial 触发后本地起，cancel 不走 Redis
  Pub/Sub）。
- **specs (deltas)**: `architecture`（云-边双套部署的总图）、`deployment-
  topology`（云端 5 服务 + 边缘 2 组件的拓扑、端口、依赖）、`service-
  communication`（控制面 protocol 定义）、`device-hardware`（audio-bridge
  接口规格）。
- **依赖**：A1（要在云端能驱动真 modem，前提 SerialATClient 跑通） — **已归档**。

#### change A3 — `edge-vad-and-opener-prefetch`
- **问题**：流式 ASR/LLM/TTS + barge-in 在 engine 端**已经完整实装**（详见
  `impl-engine-providers` 已归档 change）。**A3 不是"添加流式"**——A3 的真
  delta 是"barge-in 决策点目前在 engine 内（SPEAKING 期监听 ASR partial），
  在云-边拆分后这条路径多一个 WAN RTT 才能停 TTS，破坏对话感"。
- **方案**：(a) 边缘装 VAD（silero-vad 或 py-webrtcvad），在客户语音真正
  到达 ASR 之前就检测到 "开口"，立刻 stop playback + drop queued audio +
  控制面 cancel 信号给云；(b) 云端 engine 收 cancel 后中止 in-flight LLM +
  抛剩余 TTS chunk，同时仍然走完整 ASR partial → 多角色 PK → 润色管线；
  (c) campaign 开场白由云端预渲染 PCM/Opus 缓存到对象存储，边缘启动时拉
  到本地，拨通后**先播预缓存**（首句 0 ms 冷启动），同时云端管线背后预热。
- **specs (deltas)**: `interruption-detection`（决策点从 engine 前移到边缘 +
  cancellation token 传播路径）、`silence-activation`（VAD 物理位置说明 +
  阈值）、`deployment-topology`（开场白预缓存的存储位置 / 同步策略）。
- **依赖**：A2。
- **不在 A3 范围**：流式 ASR/LLM/TTS（已实装）、barge-in 基础逻辑（已实装）、
  多角色 PK 管线（已实装）。这些保持现状，仅迁移决策点位置。

---

### B. AI 能力扩展

#### change B1 — `tool-calling-goal-extraction`
- **问题**：goal 抽象**部分存在**——role-prompt spec 已定义 goal_type；engine
  角色 LLM JSON 输出已含 `{reply, goal_achieved, goal_type, extracted}` 字段；
  worker 落库到 `call_summary.goal_achieved / goal_type / extracted_fields`。
  **缺的是 provider 层 tool-calling 适配**：当前 LLM 完全靠 prompt 让角色在
  JSON 里吐字段，没用 OpenAI/Anthropic/Volcengine 的 `tools` / `tool_calls`
  原生机制，字段抽取的可靠性 + 输出结构化程度都低。同时 4 种 goal type
  （contact_capture / intent_grading / oral_order / custom）现在完全是
  prompt-driven 区分，没有 engine 层 schema 校验。
- **方案**：(a) engine LLM provider 接口扩 `tools` 字段，对接 OpenAI tools /
  Anthropic tool_use / Volcengine function call 三家原生 tool-calling；(b)
  按 goal_type 定义对应 tool schemas（如 `extract_contact` 的 schema 含
  `wechat_id?, phone_alt?, name?`）；(c) 角色 LLM 在多角色 PK 管线里仍输出
  reply（被裁判 / 润色筛选）+ 通过 tool_call 触发 extract_xxx；worker 把
  tool_call 结果合并落到 call_summary 而非新建 call_record 字段（**保持现有
  数据模型**，避免双重事实）；(d) 老板控制台后续 (C1) 可以按 goal_type
  渲染对应的 call_summary.extracted_fields 报表视图。
- **specs (deltas)**: `goal-achievement`（goal_type → tool schema 映射；
  call_summary.extracted_fields 与 tool_call 结果的合并语义）、`ai-pipeline`
  （provider 层 tool-calling 接入 + 在多角色 PK 管线中的位置 —— 角色 LLM
  并发期触发 vs 润色 LLM 触发的取舍）、`provider-abc`（OpenAI/Anthropic/
  Volcengine 三家 tool-calling 接口的抽象层）、`role-prompt`（更新 goal_type
  spec 中"tool-calling vs JSON 吐字段"的关系）。
- **依赖**：A3（云-边拆分稳定 + 边缘 VAD 就位）；不需要等流式因为 LLM
  本身已经流式 + tool-calling。
- **澄清不做**：call_record 表不动；call_record 仅持 transcript / recording
  URL / lead_id / campaign_id，goal 数据继续走 call_summary。

#### change B2 — `vertical-presets`
- **问题**：B1 后 engine 能跑多 goal type，但客户上手时还要从零写 prompt +
  设计 lead 字段；产品没"行业 know-how"沉淀。
- **方案**：建立 vertical preset 库，初始 5 个垂直（保险 / 教育 / 中介 /
  餐饮 / SaaS 销售），每个含：开箱 prompt 模板（system + user + tool
  definitions）+ 推荐 goal type + 范例 lead schema + 范例话术回放音频；老板
  创建 campaign 时从 preset 库选 + 微调。
- **specs (deltas)**: `role-prompt`（vertical preset 库形态 + 用户自定义覆
  盖语义）、`goal-achievement`（每 vertical 推荐 goal type 的映射）。
- **依赖**：B1。

---

### C. 管理后台

#### change C1 — `boss-console-v1`
- **问题**：现有 engine 端已实装的核心机制（**多角色 PK 管线 / 垫词 /
  转人工 / 时间窗口 / 跟进重试**）目前都靠 yaml/json 配置文件或 DB 直接改
  数据让老板用——没有运维 UX。B 系列后 engine 又长出 tool-calling 字段抽取
  能力，老板看不到结果。C1 把这些"既有 + 新增"机制全部包装成 isales-web
  上的老板操作界面。
- **方案**：isales-web 实现老板视角页面，覆盖以下 6 块（**v1.0 一次到位
  不切片**，每块都对应现有 engine / scheduler 能力）：
  - **Campaign 编辑**：选 vertical preset (B2) + 调 prompt 模板 (B2) +
    选 goal type (B1) + 角色 LLM 配置 (N 个角色 / M 个裁判 / 1 个润色) +
    垫词内容列表 (Filler) + 时间窗口配置 (Time Windows + 假期历法) +
    跟进重试规则 (Retry-Followup: retry_intervals / follow_up_interval_days)
  - **Prompt 版本化**：每次保存 prompt = 一个 prompt_version 快照；通话
    时记录用了哪个 version；老板可以回看 / 对比 / 回滚。
  - **Lead 上传 + 库管理**：CSV 导入、字段映射、lead 池查看 + 标签筛选
  - **Pipeline trace 调试回放**：选一通通话回看完整多角色 PK 决策路径
    （N 个角色各自候选 reply / N×M 裁判评分 / 润色选优过程），用于调
    prompt
  - **通话明细 + transcript 回放 + 录音**：按 lead / campaign / 时间筛
  - **报表**：按 goal_type 分模板的产物报表（contact_capture → 微信号列
    表 / intent_grading → 意向度分布 / oral_order → 下单清单）+ 通用 KPI
    （拨打 / 接通率 / 平均时长 / goal 达成率）
  - **v1.0 故意不暴露**：转人工 (human-handoff) 配置面板——代码保留、
    trigger 默认全关、UI 不出现
- **specs (deltas)**: `data-model`（prompt_version 实体 + reports 视图字段
  补完）、`service-communication`（web → api 的 RPC 扩 prompt 管理 + pipeline
  trace 查询）、`role-prompt`（prompt 版本化语义）、`time-window`（运维
  UX 表达）、`retry-followup`（运维 UX 表达）、`ai-pipeline`（pipeline trace
  数据结构）、`human-handoff`（明确标注"v1.0 dormant"——代码不动，但
  campaign 创建时 handoff trigger 默认 disabled，UI 隐藏配置项）
- **依赖**：B1（goal 数据要落库 + 报表渲染）+ B2（campaign 编辑要选 preset）；
  C1 在 B1 / B2 落地后才有意义。
- **不在 C1 范围**：多租户权限 / 员工视图（C2），先把老板单人单租户跑通。

#### change C2 — `multi-tenant-roles-and-leads`
- **问题**：C1 后能服务 1 个客户；多客户并发需要租户隔离 + 老板/员工权限拆
  分 + 老板派 lead 给指定坐席的调度逻辑。
- **方案**：DB schema 全表加 `tenant_id` + `employee_id`，alembic 迁移；引入
  `tenant` / `employee` / `seat` 三层数据模型；员工激活码生命周期（老板买
  N 席位 → 拿到激活码 → 员工 Windows 客户端启动时输码 → seat 绑定到员工
  + 长期 token 下发）；老板 web 加"派 lead → 选 seats"调度；scheduler
  在选定 seat 集合内 round-robin + 健康状态过滤。
- **specs (deltas)**: `data-model`（tenant_id / employee_id / seat 实体 +
  关系）、`service-communication`（auth 协议、tenant scoping）、`retry-
  followup`（per-tenant 重试策略）、`time-window`（per-tenant 工作时间）。
- **依赖**：C1。

---

### D. 边缘 Windows 客户端

#### change D1 — `windows-client-core`
- **问题**：A2 后边缘形态是 Mac mini，需要工程师上门部署；商用形态目标是
  客户员工自己装在自有 Windows PC 上。
- **方案**：modem_controller / audio_pipe 增加 Windows backend：USB watcher
  复用 PR #2 的 pyserial polling（Windows 原生有效）；audio backend 新增
  `WindowsWASAPICapture/Playback`（sounddevice 透明走 WASAPI）；**技术栈用
  PyInstaller + pystray + PySide6**——单一 Python 栈零迁移，pystray 做 tray
  + 通知、PySide6 做诊断小窗口、qasync 融合 PySide6 主循环 + asyncio；进程
  形态登录即启 tray app；激活码注册流程（启动时无身份 → 输码 → 调云
  register → seat 绑定）。
- **specs (deltas)**: `device-hardware`（Windows 平台 backend 契约）、
  `deployment-topology`（Windows 边缘形态、安装路径、托管方式、单进程异步
  架构）。
- **依赖**：A2（云-边接口）+ C2（激活码模型）。

#### change D2 — `hardware-observability`
- **问题**：D1 后 Windows 客户端能跑但是"哑客户端"——员工实际工作是硬件
  运维（SIM 欠费、modem 挂机、信号差、SIM 被封），客户端必须提供观测 +
  告警 + 诊断能力。
- **方案**：modem-controller 增加 health 检测周期任务：AT+CSQ 信号轮询、
  AT+CUSD 余额查询（运营商相关 USSD 码）、拨号失败率统计；阈值越线触发
  告警事件；事件流推到云端控制面 + 反射到 Windows tray 通知（图标三态色 +
  桌面通知）；一键诊断面板（GUI 小窗口）：USB 设备列表、AT 测试拨号、重启
  modem 服务、查看硬件事件日志；硬件事件落云端供老板审计。
- **specs (deltas)**: `device-hardware`（健康检测协议 + 告警类型 + 严重程
  度分级）、`webhook-callback`（告警事件 → 云端处理）。
- **依赖**：D1。

#### change D3 — `windows-installer-and-ota`
- **问题**：D1/D2 之后客户端能跑、能告警，但客户拿不到——没安装包、没自动
  升级路径。
- **方案**：(a) MSI 安装包：用 cx_Freeze MSIBuilder 或 WiX 包装 PyInstaller
  输出 .exe；(b) EV Authenticode 代码签名（购自 DigiCert / 沃通 / 信任，
  ¥1500-3000/年），否则 SmartScreen 启发式拦截 + Windows Defender 误报；
  (c) 自建升级器（约 200 行 Python）：定期拉云端 release manifest URL → 对比
  当前版本 → 下载全量 / 增量包 → 校验签名 → tray app 提示重启 → 替换
  exe + 重启；(d) 远程诊断包上传（tray "一键打包"，日志 + 配置 + 系统信息
  压缩上传到 OSS 供工程师下载）；(e) 卸载流程留干净。
- **specs (deltas)**: `deployment-topology`（Windows 安装 / 升级 / 卸载流程
  的契约 + 远程诊断包 OSS 路径与权限模型）。
- **依赖**：D2。

---

### 云-边通信拓扑（2026-05-13 决定，2026-05-15 更新媒体面）

- **控制面**：gRPC bidi stream（HTTP/2 + TLS + bearer token auth），单条长连接承
  载 (a) 心跳、(b) cloud → edge 指令（dial / cancel / config update / 远程
  诊断）、(c) edge → cloud 事件（call state / hardware alert）、(d) RTC 房间
  凭证下发（AppId / channel / token / uid）。所有内容用 protobuf oneof
  message 统一序列化。**已实装**：isales-common v0.2.x proto + transport ABC，
  isales-engine PR #2 CloudEdgeGrpcServer，isales-telephony PR #1
  CloudEdgeGrpcClient。
- **媒体面**：**阿里 RTC PaaS**（2026-05-13 PoC 4.5/5 GO，原 aiortc + coturn
  fallback 用不到，本节已重写）。云端 engine 用 ARTC SDK for Linux Python 作
  为参会者入会（`JoinChannel` + `OnSubscribeAudioFrame` + 外部 PCM 推送）；
  边缘 audio-bridge 用 ARTC SDK macOS（A2 阶段 mock loopback，真硬件商用走
  D1 Windows 路径）作为同房间另一参会者。两端 `channel_id = call_id`，
  `uid = "engine-{call_id}" / "edge-{call_id}"`，按 uid 过滤订阅，互不混音。
  IMS AICallKit / 服务端启动智能体 SaaS 不走（多角色 PK 自定义管线与 SaaS
  不兼容；详见 PoC 结果 §1 决策表）。
- **Cloud 实例数（v1.0）**：单实例（一台 4-8 核 / 16-32G RAM 云主机）。
  100-1000 seats 规模够用；不做 HA；deploy / 重启期间允许 30-60s 中断；
  Redis Pub/Sub 作命令总线的**接口抽象保留**，单实例下退化为同进程 IPC，
  多实例扩展时切换实现不改业务代码。
- **Engine session co-location**：dial 触发后 engine session 在唯一 cloud
  instance 本地起；barge-in cancel 经 gRPC stream 到这条 instance → 同进程
  直接 deliver 给 engine session，**不走 Redis**。ARTC SDK 在 engine 同进
  程，PCM 回调直喂 audio_pipe，性能不足时再拆子进程。**已实装**：engine
  PR #4 EngineSessionDispatcher + PR #5 RtcTelephonyClient.hangup → CancelCommand。
- **NAT 穿透**：阿里 RTC PaaS 内置（云厂商 BGP + 节点 + DTLS-SRTP），
  iSales 不自建 coturn / aiortc SFU。原 "若 PoC 不通走自建 fallback" 路径
  在 2026-05-13 PoC 4.5/5 GO 后**取消**。
- **断线重连**：gRPC client auto-reconnect（exponential backoff）；本地
  SQLite WAL buffer 暂存未上报事件，重连后按 seq 顺序补发 + weak-ACK 删除
  （telephony PR #3 + #4，集成进 grpc_client `event_buffer` opt-in）；中断
  期间 cloud 端 dial 指令丢失允许（scheduler 重试机制兜底），cancel 不通
  过缓冲，进行中通话断线 → edge 端 modem 自然挂断。RTC 媒体面与 gRPC
  控制面**独立断连/重连**，互不阻塞。

### 云端基础设施（2026-05-13 决定）

- **云厂商**：阿里云（生态成熟、文档 / 运维支持业界最稳）
- **计算**：单台 ECS（4-8 核 / 16-32G RAM）跑 cloud 5 服务 + SFU + Redis
  pub/sub 接口预留
- **数据库**：RDS PostgreSQL（托管）
- **缓存 / 队列**：阿里云 Redis（Tair 或标准版）
- **对象存储**：阿里云 OSS——存开场白预渲染 PCM/Opus + 通话录音 + 远程诊断
  包上传目标
- **网络延迟代价**：cloud 跑阿里、ASR/TTS 调豆包（火山）走公网 → +20-30ms
  RTT。每通通话往返几次，800ms 端到端 budget 里 70-100ms 给跨厂商网络成本。
  跨厂商 LLM 调用（豆包 / 通义 / GLM）单价 + latency 不受 cloud 位置影响
  （都是公网调用）。

### AI Provider 策略（2026-05-13 决定）

- **ASR / TTS 固定豆包流式**：火山引擎 `asr_volcengine.py` + `tts_volcengine.py`
  已在 `impl-engine-providers` 实装，v1.0 不动。中文场景下豆包是国内 AI voice
  标配。
- **LLM 走 OpenAI 兼容接口，v1.0 范围限国内三大**：豆包（火山）/ 通义
  （Qwen，阿里）/ 智谱（GLM）。三家都通过 OpenAI 兼容接口接入，code
  adapter 一份覆盖。**不接海外**（OpenAI / Anthropic / Gemini）—— 合规、
  延迟、成本对国内电销场景都不友好。代码接口保留可扩展（未来海外业务 / 私
  部署场景再开），但 v1.0 配置面板只暴露这三家。
- **Campaign 级可配的"三层 LLM"**：角色 LLM (N 个) / 裁判 LLM (N×M 个) /
  润色 LLM (1 个)，每个 slot 独立选 provider + model + temperature。允许跨
  provider 混搭（例：角色用 DeepSeek-R1 / 裁判用豆包-pro / 润色用 GPT-4-o）。
- **B1 影响**：tool-calling 适配层 `ToolCallingAdapter` 屏蔽 OpenAI tools /
  Anthropic tool_use / Volcengine function call / DeepSeek 自家格式差异，落
  到 `provider-abc` spec。
- **C1 影响**：老板控制台多角色配置面板每个角色 slot 显示 (provider, model,
  temperature, 单价/1k tokens, 历史 latency P95, 历史 成功率)，老板可基于
  指标决策。

### v1.0 scope decisions（2026-05-13 与现状审计后确认）

- **保留但 dormant 的现有机制**：`human-handoff`（engine + worker 代码不动，
  campaign 默认 trigger 全关，老板控制台不暴露 handoff 配置项）。员工 v1.0
  100% 是硬件载体不参与对话，handoff 待后续 v2.0 之类再上 UI。
- **必须纳入 v1.0 的现有机制**（之前 plan 漏写）：多角色 PK 管线（核心
  卖点，C1 必须做配置 UX + pipeline trace）、垫词机制（C1 必须做 campaign
  级 CRUD）、时间窗口（C1 配置 UI）、跟进重试（C1 配置 UI）。
- **plan 与现状审计差异澄清**：
  - 流式 ASR/LLM/TTS：**已实装**，A3 只迁移 barge-in 决策点位置
  - barge-in 基础逻辑：**已实装**，A3 把决策点前移到边缘 VAD
  - call_record 字段：**不增改**，goal 数据继续走 call_summary
  - Tool-calling：**部分存在**（prompt-driven 吐 JSON），B1 补 provider 层
    原生 tool_calls 适配

### A2 / A3 待趟过的技术风险

1. ~~**WebRTC over 公网穿 NAT** —— 自建 coturn 还是依赖云厂商 TURN~~（**已
   决**：2026-05-13 阿里 RTC PaaS PoC 4.5/5 GO，走 PaaS，不自建）
2. **多角色 PK 管线 streaming 兼容**：N 个角色并发 LLM 流 + N×M 裁判并发 LLM
   流 + 润色 LLM 流，三层流水如何在云-边拆分后保持端到端首 TTS byte ≤
   800ms？A2 design.md Decision 4 已推演（200-400 ms 给多角色 PK 段），且
   定下降级策略：若 P95 > 800 ms，运行时把默认 N=1。Sprint 0 实测验证。
3. **边缘 VAD 与云端 ASR partial 并存**：边缘 VAD 检测开口后立即 cancel，但
   云端 ASR 流仍在产 partial——这个数据 race 在 A3 design.md 必须澄清
   （边缘是不是同时停送音频？云是不是 drop 已收的 partial？）
4. **Mac mini 远程运维成本** —— 边缘机故障的处置 SLA（A2 / D1 衔接阶段
   要梳理）；**A2 范围内不解决**，D2 `hardware-observability` 接手。
5. **ARTC SDK 服务端 PCM 回调延迟**：PoC §3 标注待 Day 2 实测；如 P95 >
   100 ms，design.md latency budget 需重算（多角色 PK 段从 400 → 300 ms）。
6. **macOS ARTC SDK 是纯 Obj-C framework**（2026-05-15 inspect 发现，无
   Python wrapper）：A2 边缘 audio_bridge 走 mock loopback 跑通 wire 形态，
   商用真音频走 D1 Windows 客户端路径。决策见 `reference_artc_sdk.md`。

### 操作建议

- 启动第一个 change 时调 `/opsx:propose impl-real-at`（A1 已在 memory 标记
  为待开），把这里的 1-句问题 + 方案 + capabilities + 依赖搬到 proposal.md
  和 design.md 初稿，节省 propose 时的来回讨论。
- 每个 change 落地归档后再开下一个，避免 main 上多 change 并行造成 spec
  delta 冲突（impl-deploy-macos 与 impl-modem-controller 之间已踩过这个坑）。
- A1 → A2 之间可以稍作休整跑一轮"硬件抽查 + Mac mini 部署文档"再开 A2，
  因为 A2 影响面最大（迁移 5 服务到云、引入 WebRTC、控制面长连），proposal
  阶段需要详细 design.md，不要赶。

## 备注

本文件是讨论沉淀，**不是已批准的 change 提案**。日后准备开 stage-9 change
时，可以把"边界已定 + 三条新时延指标 + 流式/barge-in/预缓存"作为 design.md
的核心，把"暂未决定"作为 proposal 阶段要谈的开放问题。
