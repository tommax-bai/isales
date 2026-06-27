## ADDED Requirements

### Requirement: 云-边媒体面通过 DingRTC 3.x PaaS（取代 ApsaraVideo Live ARTC SDK）

云端 isales-engine 与边缘 isales-telephony（audio-bridge 模块）SHALL 通过**阿里 RTC PaaS DingRTC 3.x SDK** 作为参会者入到同一 RTC 房间进行 PCM 双向音频流传输；三端 SDK（Linux C++ in-process / Windows DLL / macOS framework）MUST 同 minor 同 patch 以保证 vendor 互通契约；MUST NOT 使用 ApsaraVideo Live 产品线下的 ARTC SDK（域名 `alivc-demo-cms.alicdn.com`，跨产品线不互通）；MUST NOT 使用其他 WebRTC 实现（aiortc / pion / mediasoup 等）；MUST NOT 引入 IMS AICallKit 等托管智能体 SaaS。

本 Requirement 取代既有 "云-边媒体面（阿里 RTC PaaS）"（来自 `arch-cloud-edge-split`，文本 "ARTC SDK for Linux Python / ARTC SDK for macOS Python" 引用 ApsaraVideo Live 下产品）；技术目标（同房间 PCM 双向流）不变，仅 SDK 选型修正。

#### Scenario: 三端 SDK 与互通契约

- **WHEN** cloud engine 与任一 edge 入会
- **THEN** SHALL 通过 DingRTC 3.x SDK join 同一 channelId 房间；三端 vendor SDK 版本 MUST 同（v1.0 锁 3.9.0）；任何一端 SDK 版本 minor / patch 升级 MUST 三端同 PR 升
- 互通行为 SHALL 通过 vendor 官方 "同 minor 同 patch 互通保证" 兜底；未来如需跨 minor 互通 SHALL 等 vendor 文档明确互通条款 + iSales e2e 验收回归

#### Scenario: AppId / AppKey 与 token 算法

- **WHEN** engine / edge 装载 RTC 凭据
- **THEN** AppId / AppKey SHALL 是 DingRTC 控制台签发的 3.x AppId（默认 `o6dpsan9...`，[[project_rtc_appid_confirmed_3x]]）；token 算法 SHALL 是 DingRTC v3.0 binary（privilege + options + HMAC-SHA256 派生 key + zlib + base64，已实证 = `gitee.com/dingrtc/AliRTCSample/Server/python3/` 算法）
- `isales_engine.transport.rtc_token` 模块 SHALL **NOT** 被本变更修改（算法已正确）；产出直接喂三端 SDK 的 token 字段（cloud `RtcEngineAuthInfo.token` / Windows / macOS 等价字段）
- MUST NOT 使用 ApsaraVideo Live ARTC SDK 内置 token 生成方法（即便算法形似，跨产品线 token 不互通）

#### Scenario: 媒体面拓扑 = audio-only + 混流订阅（v1.0）

- **WHEN** cloud engine + 1 edge join 同一房间
- **THEN** 两端 SHALL `PublishLocalAudioStream(true)` + `PublishLocalVideoStream(false)`（audio-only 拓扑）；SHALL `SubscribeAllRemoteAudioStreams(true)`（混流订阅，DingRTC Linux C++ SDK 不提供 per-uid PcmBeforMixing 订阅）
- 2-user channel 下混流 = 对方那一路；v1.0 此约束**不**构成 blocker；如未来 >2 用户场景（如三方通话）出现，SHALL 另起 change 评估替代方案（如 server-side mixer）

#### Scenario: 媒体面 PoC demo appid 隔离验证（验收前置）

- **WHEN** 任一端 DingRTC SDK 集成完成首次 e2e
- **THEN** SHALL 按以下顺序隔离验证：
  1. demo appid `a4zfr1hn` + demo AppKey 跑 `RtcSession.join` → 验 SDK 装对 + binding 通 + token 算法对
  2. 切真 AppId `o6dpsan9...` + 真 AppKey 复跑 → 验凭据对
  3. cloud engine + 真 edge 同房间 join + PCM 互通 → 验 e2e
- 任一步失败 SHALL 在该步精准定位层；MUST NOT 跳过 demo 直接试真凭据（[[feedback_isolate_with_vendor_sample]]）

#### Scenario: gslbServer 默认值

- **WHEN** 任一端调 `JoinChannel`
- **THEN** `RtcEngineAuthInfo.gslbServer`（cloud）/ 等价 Windows / macOS API 字段 SHALL 默认为 `https://gslb.dingrtc.com`（DingRTC vendor 默认 GSLB endpoint）；MUST NOT 默认指向 `gw.rtn.aliyuncs.com`（ApsaraVideo Live 旧网关，与 DingRTC roomserver 不连通）
- gslbServer 字段 SHALL 允许通过环境变量 / 配置 override，仅供专网 / privatelink 场景使用；commercial v1.0 不开放该 override

## REMOVED Requirements

### Requirement: 云-边媒体面（阿里 RTC PaaS）

**Reason**: 被本 change ADDED 的「云-边媒体面通过 DingRTC 3.x PaaS（取代 ApsaraVideo Live ARTC SDK）」取代；旧 requirement 文本引用 ApsaraVideo Live ARTC SDK（`ARTC SDK for Linux Python / ARTC SDK for macOS Python`），选错产品线（与 ECS 配置的 DingRTC 3.x AppId 跨产品线不互通）。技术目标（同房间 PCM 双向流）不变，仅 SDK 选型修正。
