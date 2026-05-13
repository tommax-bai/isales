# 阿里 RTC Server-side PoC（A2 propose 硬前置）

## 背景

v1-roadmap A2 `arch-cloud-edge-split` 把 5 服务搬阿里云 + 边缘留 modem-controller + audio-bridge，云-边音频走 WebRTC。NAT 穿透 / WebRTC 服务端方案在 v1-roadmap 已列为"技术风险 #1"：

- **首选**：阿里 RTC PaaS（与 OSS / RDS 同生态，内网延迟可能低）
- **Fallback**：自建 coturn + aiortc SFU（已知可行，月度 ¥100 量级）

阿里 RTC SDK 主要面向移动 / Web 终端（"客户 ↔ 客户"音视频）。**服务端**入会能力是不确定项——iSales 需要在云端 engine 进程里：

1. **作为 RTC 参会者**入到边缘机所在的房间
2. **取原始入站 PCM**（来自 modem mic，经边缘 audio-bridge 编 Opus 推上来）
3. **喂入流式 ASR**（豆包），进入现有多角色 PK 管线
4. **推自定义 TTS PCM**（豆包流式 TTS）到房间，边缘解码后播给 modem speaker

这种"Python 进程作 RTC 服务端 + 自定义 ASR/LLM/TTS pipeline"用法非主流，必须先 PoC 才能定 A2 design。

---

## PoC 要回答的 5 个问题

| # | 问题 | 不通的后果 |
|---|---|---|
| Q1 | 阿里 RTC 有没有官方 **Python server-side SDK**？版本 / 维护活跃度？ | 没有 → 要么 headless 浏览器跑 Web SDK（不靠谱），要么走 Linux native SDK 的 C/C++ binding 自己封 Python；倾向直接 fallback 到 aiortc |
| Q2 | 服务端能否**作为参会者入会**？能否拿到**入站原始 PCM 帧**（不是 Opus packet，是解码后的 16-bit linear PCM）？ | 拿不到原始 PCM → ASR 跑不了；fallback aiortc |
| Q3 | 服务端能否**推自定义 PCM 流**（不走 RTC 自带麦克风采集，而是从 TTS 拿 PCM 字节）到房间？ | 推不进去 → TTS 出不去；fallback aiortc |
| Q4 | 多角色 PK 管线（N 角色并发 LLM + N×M 裁判 + 1 润色 + 流式 TTS）能不能塞进**阿里"AI 智能体接入"产品**（IMS / RAB / 智能对讲）？这些 SaaS 是阿里官方 RTC + AI 整合套餐，但通常只允许配厂商 ASR/LLM/TTS，自定义管线深度受限。 | 不能塞 → 即使 RTC 能用，AI 部分要绕过 SaaS 自己集成，那 RTC 价值减半；fallback aiortc |
| Q5 | 阿里 RTC 服务端入会**计费模型**？每路 ¥/分钟？每月固定？跟自建 coturn（一台 ECS ¥100/月）比成本如何？ | 比 coturn 贵 5-10 倍 → 商业角度也支持 fallback |

---

## Day 1：纸面调研 + 提工单

### Step 1：官方文档梳理（半天）

- 阿里云 RTC 产品页 → 看"服务端 SDK"是否独立栏目
- 控制台 → RTC → SDK 下载，看支持哪些语言
- 文档关键词搜：`server SDK`、`服务端`、`Python`、`Linux 入会`、`自定义音频源`、`自定义音频采集`、`回调音频帧`、`raw PCM`、`录制端`、`旁路推流`、`AI 智能体接入`、`实时音频机器人`、`IMS`、`RAB`、`智能对讲`
- 找官方 demo / GitHub repo：`aliyun/rtc-`、`alibabacloud-rtc-`、`aliyun-sdk-server-rtc-`

**记录**：每个 keyword 找到的链接 + 一句话摘要，贴到 PoC 报告。

### Step 2：阿里云工单（半天）

提工单（"创建工单 → 实时音视频 → 技术咨询"），把以下贴进去：

> 业务场景：服务端 Python 进程作为参会者加入 RTC 房间，需要：
>
> 1. 拿到入站音频流的原始 PCM 帧（16kHz / 16-bit linear，逐帧 20ms）
> 2. 推送自定义 PCM 字节流（来源是另一个 ASR/LLM/TTS pipeline 的 TTS 输出，不走 RTC 自带麦克风采集）到房间
> 3. 多路自定义并发 LLM + 裁判管线在服务端 Python 进程内运行，不走任何 AI 智能体 SaaS
>
> 问：
> (a) 阿里 RTC 服务端是否有官方 Python SDK？版本？维护状态？
> (b) 如果只有 Linux native SDK，Python 是否能通过 ctypes / pybind 调用？官方有没有 sample？
> (c) "AI 智能体接入"产品（IMS / RAB / 智能对讲）是否允许完全自定义 ASR/LLM/TTS 管线？还是只能选阿里提供的预置模型？
> (d) 服务端入会每路每分钟计费？还是有"服务端"专属套餐？
>
> 期望 24h 内有初步答复，若需要 demo / 测试账号配合，我们可以提供项目细节。

### Step 3：跟同行 / 群打听（弹性）

- 火山引擎 RTC（豆包同生态）也支持服务端入会的话，PoC 难度可能更低
- 即构 ZEGO / 声网 Agora 的服务端 SDK 成熟度公开资料更多，可参考其 Python sample 找思路

---

## Day 2：跑最小 PoC 脚本（**前提是 Day 1 找到可用 SDK**）

如果 Day 1 找到了 Python 服务端 SDK / native SDK + Python binding，跑这个最小脚本：

```python
# poc_aliyun_rtc.py — 服务端入会 + 拉 PCM + 推自定义 PCM
import asyncio
from aliyun_rtc_server_sdk import Engine, ChannelConfig, AudioFrame  # 假设的 import

async def main():
    eng = Engine(app_id="<from console>", app_key="<from console>")
    channel = await eng.join_channel(
        channel_id="poc-test",
        uid=10001,
        role="publisher_subscriber",
    )

    # Q2: 能不能拿到入站原始 PCM？
    async def on_audio_frame(uid, frame: AudioFrame):
        # frame.pcm = bytes, frame.sample_rate=16000, frame.channels=1
        print(f"RX uid={uid} bytes={len(frame.pcm)} rate={frame.sample_rate}")
        # 在真实代码里这里喂入豆包 ASR

    channel.on("audio_frame", on_audio_frame)

    # Q3: 能不能推自定义 PCM？
    await asyncio.sleep(2)
    fake_tts_pcm = bytes(16000 * 2)  # 1s 静音 PCM
    for chunk_start in range(0, len(fake_tts_pcm), 640):  # 20ms 帧
        chunk = fake_tts_pcm[chunk_start:chunk_start+640]
        await channel.push_audio_frame(pcm=chunk, sample_rate=16000)
        await asyncio.sleep(0.02)

    # 让 inbound callback 多收 5 秒数据再退出
    await asyncio.sleep(5)
    await channel.leave()
    await eng.shutdown()

asyncio.run(main())
```

并在另一台机（或本机的浏览器）用阿里 RTC Web SDK 加入同一个 channel `poc-test`，浏览器麦克风说话 / 播放音频，观察 Python 端 stdout 能不能收到 PCM 帧。

**记录**：执行结果（能跑 / 报错栈 / PCM 帧实际能不能拿到 / 推送是否被对端收到）+ Python 进程 CPU / 内存占用。

---

## GO / NO-GO 决策表

PoC 结束后按下表填值：

| # | 问题 | GO 标准 | 实测 | 结论 |
|---|---|---|---|---|
| Q1 | Python server-side SDK 存在 | 有官方 SDK 或可靠 Python binding | _________ | ⬜ GO ⬜ NO-GO |
| Q2 | 拿到入站原始 PCM | 能在 < 50ms 延迟内拿到 16k/16-bit 帧 | _________ | ⬜ GO ⬜ NO-GO |
| Q3 | 推自定义 PCM 进房间 | 浏览器端能听到 | _________ | ⬜ GO ⬜ NO-GO |
| Q4 | 自定义 AI 管线能用 | 不依赖阿里 AI 智能体 SaaS | _________ | ⬜ GO ⬜ NO-GO |
| Q5 | 成本可接受 | ≤ 自建 coturn 的 3 倍 | _________ | ⬜ GO ⬜ NO-GO |

**规则**：

- **5/5 GO** → A2 propose 走阿里 RTC，design.md 写"Decision: 阿里 RTC PaaS"
- **3-4 GO** → 视哪些 NO-GO 决定。若只 Q5 NO-GO（贵但能用），先走阿里 RTC 跑 QA，v1.0 上线前评估迁移；若 Q1-Q4 任一 NO-GO，直接 fallback
- **≤ 2 GO 或 Q1/Q2/Q3 任一 NO-GO** → fallback 到 coturn + aiortc，A2 propose 走"自建 SFU"路线

---

## Fallback：coturn + aiortc 路线（已知可行）

如果 PoC 走不通，A2 design 改用：

- **STUN / TURN**：自建 coturn 跑在同一台阿里云 ECS（或单独一台 c7.large，月度 ¥100 量级）
  - UDP 端口段：49152-65535（阿里云安全组开放，注意源 IP 限制）
  - TURN 凭证 short-term，gRPC 控制面下发给边缘
- **SFU**：云端 engine 进程内嵌 aiortc，作为 P2P 对端直接收 modem 边缘推的 Opus 流
  - 解码 Opus → 16k PCM → 喂豆包 ASR
  - 豆包 TTS PCM → Opus 编码 → aiortc 推回边缘
- **信令**：复用 gRPC bidi stream，SDP offer/answer + ICE candidate 走 protobuf oneof（与 v1-roadmap §"云-边通信拓扑"一致）

aiortc 已知坑：单进程性能上限大概 50-100 并发连接（够 v1.0 单实例 100-1000 seats 范围），超了再拆子进程。

---

## 时间预算

| 阶段 | 时长 | 阻塞 A2 propose? |
|---|---|---|
| Day 1：调研 + 工单 | 0.5 天 | 是 |
| Day 1：等阿里工单回复 | 0.5-1 天（异步） | 是 |
| Day 2：跑最小脚本（如果有 SDK） | 0.5 天 | 是 |
| Day 2：填决策表 + 写 PoC 报告 | 0.5 天 | 是 |
| **合计** | **2-3 天** | |

**硬截止**：PoC 报告写到 `openspec/v1-roadmap-aliyun-rtc-poc-result.md`（同目录），A2 propose 阶段直接引用。

---

## 并行 Sprint 0 准备项（不阻塞 PoC，可同时跑）

- 阿里云账号准备 + VPC / 安全组规划 + 域名 + Let's Encrypt 证书
- ECS 4C16G / RDS PostgreSQL 16 / Redis 1G / OSS bucket 开通（按量付费，QA 用完销毁）
- Windows 机环境：Python 3.12 + Git + VS Build Tools + 插 GSM modem 确认 COM 口 + Wireshark
- 把 isales-engine 现有的 `audio_pipe.py` + provider 接口梳理一遍，确认 A2 实装阶段哪些代码会被改

---

## PoC 之后的下一步

PoC 结果回来后开新 session 跑：

```
/opsx:propose arch-cloud-edge-split
```

把 PoC 报告内容贴进 design.md 的 "Decisions" 节，把 GO / NO-GO 决策表 + fallback 论证作为路径选择的依据。
