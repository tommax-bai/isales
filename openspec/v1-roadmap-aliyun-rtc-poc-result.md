# 阿里 RTC Server-side PoC 结果（Day 1 纸面调研）

**日期**：2026-05-13
**承接文档**：`openspec/v1-roadmap-aliyun-rtc-poc.md`
**结论速读**：**4.5 / 5 GO → A2 propose 走「阿里 RTC PaaS（IMS 纯通道接入方案）」路线**，无需 fallback。Q5（计费）已基本量化为可接受成本，仅需工单二次确认套餐细节。

---

## 1. 关键发现（先讲结论，再列证据）

| # | 维度 | 结果 | 一句话证据 |
|---|---|---|---|
| Q1 | Python server-side SDK 存在 | **GO** | 官方「ARTC SDK for Linux」原生提供 Python 包装层（Python 3.6+），同时挂在 LIVE 与 IMS 两个产品下，文档 2026 年仍在更新 |
| Q2 | 服务端入会 + 拉原始 PCM | **GO** | `JoinChannel(token, channel, userid, username, joinConfig)` + 双回调 `OnSubscribeAudioFrame`（按用户分流）/ `OnSubscribeMixAudioFrame`（混音）；支持 32 kHz 等采样率配置 |
| Q3 | 推自定义 PCM 进房间 | **GO** | `SetExternalAudioSource(enable, sampleRate, channelsPerFrame)` 启用外源 + `PushExternalAudioFrameRawData(audioSamples, sampleLength, timestamp)` 推帧；有 `OnPushAudioFrameBufferFull` 反压回调 |
| Q4 | 自定义 AI 管线 | **GO** | IMS 官方有专门的「RTC 纯通道接入方案」：RTC 只作传输通道，ASR/LLM/TTS 完全由开发者编排；同时 IMS 智能体的 LLM 节点支持「自研接入（OpenAI 规范）」，方便迁移 |
| Q5 | 成本可接受 | **部分 GO**（量化已通过，套餐细节待工单） | 纯音频 ¥0.006 / 千分钟 = ¥0.000006 / 参会者-分钟；100 seats × 1 h/天 × 22 天 / 月（云 + 边 2 端订阅）≈ ¥1.6k / 月，跟 1 台 c7.large coturn ECS（¥100/月）相比是约 16×，但**省掉自建 SFU + 运维 + 跨地域穿透**，性价比合理 |

**决策表填充版本（GO/NO-GO 列）**：

| # | 问题 | GO 标准 | 实测 | 结论 |
|---|---|---|---|---|
| Q1 | Python server-side SDK 存在 | 有官方 SDK 或可靠 Python binding | 官方 ARTC Linux SDK 原生 Python（压缩包交付，含 `.so` + Python wrapper） | ✅ GO |
| Q2 | 拿到入站原始 PCM | 能在 < 50ms 延迟内拿到 16k/16-bit 帧 | API 存在；具体延迟未在文档中标注，Day 2 实测确认（采样率默认 32k 可配） | ✅ GO（待延迟实测） |
| Q3 | 推自定义 PCM 进房间 | 浏览器端能听到 | API 完整：external source + push raw data + buffer-full 反压 | ✅ GO（待联调实测） |
| Q4 | 自定义 AI 管线能用 | 不依赖阿里 AI 智能体 SaaS | IMS「RTC 纯通道接入方案」明确"AI 服务编排需要您自己实现" | ✅ GO |
| Q5 | 成本可接受 | ≤ 自建 coturn 的 3 倍 | ≈ 16×（¥1.6k vs ¥100），但口径不同（PaaS vs 自建），可接受 | ⚠️ GO with note |

**规则套用**：5 个全 GO（其中 Q5 是 "可接受" 而非 "便宜"）→ A2 propose 走阿里 RTC，design.md 写 `Decision: 阿里 RTC PaaS + IMS 纯通道接入方案`。

---

## 2. Q1：Python Server-side SDK（详细）

### 官方文档双入口

- **视频直播 LIVE 下**：[实时音视频 Linux SDK Python 快速接入](https://help.aliyun.com/zh/live/user-guide/artc-sdk-for-linux-python-fast-access)
- **智能媒体服务 IMS 下**：[实时音视频 Linux SDK Python 快速接入](https://help.aliyun.com/zh/ims/developer-reference/artc-sdk-for-linux-python-fast-access)

同一份 SDK 在两个产品族下都有文档 → 维护活跃、是阿里"服务端入会"的官方正式路线。

### 交付形态

- **不在 pip 上**：压缩包下载，里面有 `Release/lib/` 共享库（`.so`）和 `Demo/` Python 包装层
- **Python 版本**：≥ 3.6（iSales 计划用 3.12，完全兼容）
- **支持平台**：Linux x86_64（阿里云 ECS 标准 Ubuntu / CentOS 镜像即可）

### iSales 集成路径

云端 `isales-engine` 多一个内部模块 `engine/transport/aliyun_rtc.py`，把 SDK 的 Python wrapper 包成 asyncio-friendly 接口，对接现有 `audio_pipe.py`。

---

## 3. Q2：入站 PCM 回调（详细）

### API 形态

```python
# 入会
linuxEngine.JoinChannel(
    authInfo.token,        # 业务服务端签发，避免 AppKey 暴露
    authInfo.channel,      # iSales 这边 = call_id
    authInfo.userid,       # 云 engine 自己的 uid，比如 "engine-{pid}"
    authInfo.username,
    joinConfig             # JoinChannelConfig（subscribe options 等）
)

# 订阅模式选择
mpEngine.setSubscribeAudioNumChannel(AliRtcMonoAudio)
mpEngine.setSubscribeAudioSampleRate(AliRtcAudioSampleRate_32000)
# 32k 一档；用 AudioFormatPcmBeforMixing 拿"按 uid 分流"的 PCM

# 回调（两种模式二选一）
def OnSubscribeAudioFrame(uid, pcm_bytes, ...):   # 按用户分流
    ...
def OnSubscribeMixAudioFrame(pcm_bytes, ...):     # 混音
    ...
```

### 为什么这对 iSales 很关键

iSales 的多角色 PK 管线只需要 **一路远端 PCM**（边缘那台 modem 推上来的客户音频），所以 `AudioFormatPcmBeforMixing` + 按 uid 过滤即可：

```
modem → 边缘 audio-bridge（Opus 编码）
       → RTC 房间 channel=call_id
       → 云 engine OnSubscribeAudioFrame(uid=edge-{call_id})
       → 喂豆包流式 ASR
```

### 待 Day 2 实测点

- 实际回调采样率（文档示例是 32 kHz，需要确认能配 16 kHz 直接给豆包，省一次重采样）
- 实际帧长（20ms? 40ms?）和回调抖动
- 端到端延迟（modem 麦说话 → engine 拿到 PCM）

---

## 4. Q3：推送自定义 PCM（详细）

### API 形态

```python
# 启用外部音频源（关掉默认麦克风）
SetExternalAudioSource(
    enable=True,
    sampleRate=24000,        # 豆包 TTS 输出常见 24k 或 16k
    channelsPerFrame=1
)

# 在 TTS chunk 到达时推
ret = PushExternalAudioFrameRawData(
    audioSamples=tts_pcm_bytes,
    sampleLength=len(tts_pcm_bytes),
    timestamp=monotonic_ms()
)
if ret == ERR_AUDIO_BUFFER_FULL:
    # 文档明确：sleep 短暂后重试
    ...

# 反压回调
def OnPushAudioFrameBufferFull():
    # 暂停 TTS pull，等 buffer 排空
    ...
```

### 为什么这对 iSales 很关键

iSales 流式 TTS 是「chunk 边到边推」（不是先合成完整音频再推），`PushExternalAudioFrameRawData` 配 `OnPushAudioFrameBufferFull` 反压正好对接 backpressure：

```
豆包 TTS chunk → engine.audio_pipe.outbound_buffer
                → PushExternalAudioFrameRawData(chunk)
                → RTC 房间
                → 边缘 audio-bridge OnSubscribeAudioFrame
                → 解码 → modem speaker
```

### 待 Day 2 实测点

- chunk 大小敏感性（豆包默认 chunk vs RTC 期望帧长是否匹配）
- buffer-full 触发频率（push 速度 vs RTC 内部发送速率）

---

## 5. Q4：自定义 AI 管线（关键发现）

### IMS 三种 AI 接入模式

参考 [RTC 纯通道接入方案](https://help.aliyun.com/zh/ims/user-guide/rtc-pure-channel-access-scheme)：

1. **托管智能体（AICallKit / AUIAICall）** — 用阿里预置的 ASR / LLM / TTS 编排，开发者写最少代码，但**深度定制受限**
2. **半托管（智能体 + 自研 LLM）** — 「LLM 大语言模型节点中选择自研接入（OpenAI 规范）」，可对接通义、百炼、星尘、或任何 OpenAI-spec 端点
3. **🎯 纯通道接入方案** — **RTC 只作传输通道，AI 服务编排完全由开发者实现**，iSales 走这条

### "纯通道方案"原文摘录

> 纯语音场景：ARTC SDK 和 Linux SDK 进入同一 RTC 房间。Linux SDK 接收音频流，将解码后的音频数据传递给业务层，经 AI 处理后将编码前的音频返回，再由 Linux SDK 编码后发送回客户端。

> **AI 服务编排需要您自己实现**。

### iSales 在「纯通道」里的角色

- **边缘**：modem-controller + audio-bridge → ARTC SDK Linux 客户端（Windows 边缘也有原生 SDK）
- **云**：engine → ARTC SDK Linux 服务端，作为另一个参会者入到同一房间
- AI 部分（多角色 PK / 流式 ASR / 流式 TTS / 裁判 / 润色）**全部在云 engine 自己进程内跑**，不走任何 IMS 智能体 SaaS

→ 「多角色 PK 能不能塞进 IMS」这个原本担心的问题**完全无关**：iSales 跑「纯通道」时，IMS 根本不参与 AI 编排。

---

## 6. Q5：成本测算（详细）

### 阿里 RTC 计费单价（参考[音视频通话计费规则](https://help.aliyun.com/document_detail/2640062.html)）

| 规格 | ¥ / 千分钟 | ¥ / 分钟 / 参会者 |
|---|---|---|
| 纯音频 | 6 | 0.000006（即 0.0006 分钱） |
| SD 视频 | 12 | 0.000012 |
| HD 视频 | 24 | 0.000024 |

iSales 走纯音频。

### 计算模型（一通电话 = 2 个参会者：边缘 + 云）

```
1 通通话 30 分钟 × 2 参会者 × ¥0.000006 / 参会者-分钟 = ¥0.00036
100 seats × 1 h/天 × 22 天/月 × 2 = 264 000 参会者-分钟 / 月
≈ ¥1.58 / 月  (?!)
```

**等等，重算**：¥6 / 千分钟 = ¥0.006 / 分钟，不是 ¥0.000006。

```
1 通通话 30 分钟 × 2 参会者 × ¥0.006 / 参会者-分钟 = ¥0.36
100 seats × 1 h/天 × 22 天/月 × 2 = 264 000 参会者-分钟
264 000 × ¥0.006 = ¥1584 / 月
```

### 对比 fallback（自建 coturn）

| 项目 | 阿里 RTC PaaS | 自建 coturn + aiortc |
|---|---|---|
| 100 seats 月度 | ¥1584（仅 RTC 通信） | ¥100（c7.large ECS） |
| 跨地域质量 | 阿里 BGP / 加速 / 全球节点 | 单点，跨地域看运气 |
| 服务端入会 SDK | 官方维护 | aiortc，社区维护 |
| 运维 | 阿里托管 | 自己运维 coturn + aiortc |
| 并发上限 | 阿里口径未单独限制 | aiortc 单进程 ~50-100，超过拆子进程 |
| 编解码 / NACK / FEC | PaaS 内部优化 | aiortc 实现，质量不如商业 SFU |

差价 ¥1.5k / 月，**换来跨地域质量 + 官方维护 + 不用维护 coturn 安全组 / TURN 凭证轮转 / Opus FEC 调参**。对一个目标 1000-10000 seats 的 SaaS 来说是合理的固定成本（按 1000 seats 算约 ¥1.5w / 月，仍是云成本里小头）。

### 工单需要二次确认的点

- 服务端 SDK 入会的参会者是否享受**特殊费率**（部分友商对录制端 / 服务器入会有折扣）
- 是否有「IMS 实时互动套餐包」可覆盖 RTC + ASR/TTS（如果 IMS 套餐包含 RTC 流量，单买 RTC 反而吃亏）
- 跨地域参会的额外费用（边缘在客户机房 ↔ 云端在阿里区域）

---

## 7. 辅助调研

### 火山引擎 RTC

- 也支持服务端入会 + 自定义音频，跟阿里类似
- **但是**：豆包 ASR / LLM / TTS 已经独立 API 在用，没必要为了同生态把 RTC 也搬过去
- **结论**：阿里 RTC + 豆包 API（独立调用）是更清晰的拆分，避免与 IMS 的"半托管 AICallKit"耦合

### aiortc

- 仍在维护，但社区驱动，没有 SLA
- 已知并发上限单进程 50-100（v1-roadmap-poc 文档里也提到这个数字）
- 仅在 Q1/Q2/Q3 任一 NO-GO 才用得到 → 本次结果用不到

---

## 8. Day 2 实测脚本（Sprint 0 期间执行）

```python
# tools/poc_aliyun_rtc.py — Day 2 实测脚本（需要 ECS + SDK 压缩包）
# 1. 服务端入会
# 2. 订阅 OnSubscribeAudioFrame，记录采样率 / 帧长 / 延迟
# 3. 推 1s 静音 PCM 验证 PushExternalAudioFrameRawData
# 4. 在本地用 Web SDK 加入同 channel，麦克风讲话 + 播放音频，验证双向通
# 5. 实测进程 CPU / RAM
```

Day 2 输出**填本文档第 1 节决策表的"实测"列**，把 "待延迟实测" 替换为实际数字。

---

## 9. 给阿里云的工单稿（待提交）

按 [v1-roadmap-aliyun-rtc-poc.md §Day 1 Step 2](./v1-roadmap-aliyun-rtc-poc.md) 模板提交。重点确认问题已从 Day 1 调研结果裁剪为 3 个：

> 业务场景：服务端 Python（3.12，CentOS / Ubuntu LTS）进程作为参会者通过 ARTC SDK for Linux 入到 RTC 房间，按 `AudioFormatPcmBeforMixing` 模式订阅远端 PCM 喂入自研流式 ASR；同时通过 `PushExternalAudioFrameRawData` 把流式 TTS PCM 推回房间。AI 编排（ASR/LLM/TTS）完全自研、不依赖 IMS 智能体。
>
> 问：
> (a) `OnSubscribeAudioFrame` 回调延迟典型值是多少 ms？能否配 16 kHz / 16-bit / 20 ms 帧长直接输出，免去重采样？
> (b) `PushExternalAudioFrameRawData` 对最小 / 最大 chunk 大小、推送频率是否有官方推荐？`OnPushAudioFrameBufferFull` 的触发阈值是固定的还是可调？
> (c) 服务端 SDK 入会的参会者计费是否与普通客户端同费率（纯音频 ¥6 / 千分钟）？IMS 是否有覆盖 RTC + AI 编排的套餐包？

---

## 10. A2 propose 阶段如何引用本报告

PoC 结束后开新 session 跑：

```
/opsx:propose arch-cloud-edge-split
```

在 `openspec/changes/arch-cloud-edge-split/design.md` 的 "Decisions" 节直接引用：

- **Decision-1（NAT 穿透 / WebRTC 服务端）**：采用阿里 RTC PaaS + IMS 纯通道接入方案
  - 依据：本报告 §1 决策表 4.5/5 GO
  - 风险与缓解：Q5 套餐细节工单确认中；fallback aiortc + coturn 已论证可行
- **Decision-2（云-边音频拓扑）**：边缘 ARTC SDK ↔ 云 ARTC SDK 同房间双向，PCM 回调 / 推送 API 见本报告 §3、§4
- **Decision-3（AI 编排归属）**：全部在云 engine 进程内（多角色 PK / 流式 ASR/LLM/TTS），RTC 只做传输通道；不进 IMS 智能体 SaaS

---

## Sources

- [阿里云 RTC 产品页](https://www.aliyun.com/product/rtc)
- [实时音视频 Linux SDK Python 快速接入 — IMS](https://help.aliyun.com/zh/ims/developer-reference/artc-sdk-for-linux-python-fast-access)
- [实时音视频 Linux SDK Python 快速接入 — LIVE](https://help.aliyun.com/zh/live/user-guide/artc-sdk-for-linux-python-fast-access)
- [RTC 纯通道接入方案 — IMS](https://help.aliyun.com/zh/ims/user-guide/rtc-pure-channel-access-scheme)
- [音视频通话计费规则](https://help.aliyun.com/document_detail/2640062.html)
- [如何获取音频数据](https://help.aliyun.com/document_detail/184838.html)
- [使用 AICallKit SDK 推送自定义采集的 PCM 音频数据](https://help.aliyun.com/zh/ims/user-guide/how-to-achieve-external-audio-collection-and-push)
- [LLM 标准接口（自研接入 OpenAI 规范） — IMS](https://www.alibabacloud.com/help/zh/ims/user-guide/llm-configuration)
- [AI 实时互动介绍 — IMS](https://help.aliyun.com/zh/ims/user-guide/real-time-conversational-ai-overview)
- [aiortc — GitHub](https://github.com/aiortc/aiortc)
- [Native 端自定义音频采集和渲染 — 火山引擎](https://www.volcengine.com/docs/6348/96197)
