## Context

当前 TTS 合成路径（`isales-engine/run_loop.py`）：main LLM 流式 token → `sentence_splitter`（命中 `。？！` / `\n\n` / 满 50 字 emit）→ 每句构造一个 `_SynthJob` → `tts.synthesize_stream(text, voice_id)` 发**一次独立单向 SSE 请求**（`isales-common/providers/tts_volcengine.py`，`POST /api/v3/tts/unidirectional/sse`）。producer/consumer 流水线（`_play_streaming`，`job_q` maxsize=2）让句 N+1 在句 N 播放时预合成，barge-in 时 `_SynthJob.aclose()` 逐句取消。

每句一个冷请求 = 每句重新规划语调、重置音高基线、句尾各做一次降调 → 跨句音色 / 语气「跳一下」。这是**结构性根因**，`emotion_scale=2` 只压摆幅、不消重置。

探针 `scripts/tts_bidi_probe.py` 已实测：双向端点 `wss://openspeech.bytedance.com/api/v3/tts/bidirection` 本账号可用、不需新 grant；二进制帧家族同 ASR SAUC（4-byte header + event + session_id + payload）；一个 session 内多个 TaskRequest（一句一个）跨句连续合成成功（moon/wvae 家族 410KB/≈12.7s）。但 `resource_id ↔ speaker` 严格绑定：xiaohe（`seed-tts-2.0`/uranus）双向声学层不跑（握手过、SentenceEnd 回显、零 PCM）；moon/wvae（`volc.service_type.10029`）才出音。

## 决策

### 决策 1：会话式接口与一次性接口并存，按调用形态分流（非 fallback）

TTS Provider ABC 新增**会话式合成接口**，与现有一次性 `synthesize_stream(text, voice_id)` 并存：

- **会话式**（新）：用于**多句连续轮次**（main 流式回复、restructure 流式回复）。一个 session 跨整轮，句子依次喂入，vendor 统一规划韵律。
- **一次性**（保留）：用于**单片段**场景 —— 开场白（固定单句）、垫词（单短语）、默认回复兜底、listen_only 引导语、isales-api 试听 preview。这些天然只有一个片段，无跨句韵律收益，走会话式只会徒增握手开销。

> 这**不是** `feedback-avoid-multilayer-fallback` 意义上的多层兜底：两条路径服务**不同调用形态**（多句轮次 vs 单片段），不是「主路径失败回落备用」。明确**不引入**「双向合成失败 → 自动回落单向」的运行时兜底 —— bidi 音色配错（用了 xiaohe）是**配置错误**，应 fail-loud（zero-audio → 抛错），不静默回落掩盖问题。

会话式接口形态（待 apply 时定稿，倾向显式 session 对象优于回调）：

```
session = await tts.open_session(voice_id)   # StartConnection + StartSession，建连握手
await session.feed(text)                       # 每句一个 TaskRequest，可多次
audio_iter = session.audio()                   # AsyncIterator[bytes]，连续 PCM
await session.finish()                          # FinishSession，告知无更多文本
await session.close()                           # 中途 barge-in / teardown，关 WS
```

`audio()` 与 `feed()` 并发：feed 推文本、audio 持续 yield PCM，直到收到 SessionFinished/TTSEnded 终止。

### 决策 2：`_play_streaming` 从「每句一 job」改「整轮一 session」

producer 不再对每句 `_SynthJob`，而是：轮开始 `open_session` → 对 `sentences()` 每句 `feed` → 句流结束 `finish`。consumer 播放 `session.audio()` 这条**单一连续流**。

保留的不变量：
- `first_audio_ms` 仍从 `processing_start`（PROCESSING 进入 ≈ 客户说完话）起算，锚到 audio 首 chunk。
- 时间门控垫词（`filler_delay_s`，从 `processing_start` 起算）逻辑不变：首 audio chunk 未在窗口内就绪才播垫词。
- barge-in（partial monitor 取消 audio_out task）→ `session.close()` 关 WS（替代逐 job aclose）。
- barge-in 残句捕获（`interrupt_remaining`，D5）：已 feed 但未播出的句子语义保留 —— 实现上仍可在 producer 侧记录「已 feed 未确认播完」的句子集合供捕获。

producer/consumer 仍保留（main LLM 不被播放阻塞），但 `job_q` 从「`_SynthJob` 队列」退化为「sentence 文本队列」或直接 producer feed、consumer 读 `session.audio()`。预合成超前由 session 内 vendor 侧 pipelining 自然承担（feed 不阻塞等播放）。

### 决策 3：bidi 路径按 speaker 家族选 resource_id

复用现有 `_resource_for(speaker)` 模式：bidi 会话的 `X-Api-Resource-Id` 对 moon/wvae 家族用 `volc.service_type.10029`。具体映射在 apply 时定（可能按 speaker 后缀 `*_moon_bigtts` / `*_wvae_bigtts` 判，或单独 bidi resource_id 配置）。生产 campaign `voice_id` 迁到该家族的一个具体 speaker（如 shuangkuaisisi / M392 对应的 vendor id）。

### 决策 4：协议实现位置

bidi WS 协议实装在 `isales-common`（与单向 SSE 同模块或拆 `tts_volcengine_bidi.py`），因为 ABC 在 common、且未来 api 也可能复用。`MockTTSProvider`（`isales_common.providers.testing`）补会话式接口的 mock 实现，使 engine 单测无需真 vendor。

## 接口稳定性

ABC 新增会话式接口属**新增可选能力**（provider-abc § ABC 接口稳定性「新增可选参数」）：一次性 `synthesize_stream` 签名不变，存量调用方（api preview、greeting/filler 路径）零改动。

## 风险

- **session 生命周期 ↔ barge-in 竞态**：feed 进行中被 close 需干净关 WS、不泄漏连接。沿用 `_SynthJob.aclose()` 的 contextlib.suppress + 显式 close 纪律。
- **首音延迟**：bidi 多一次 StartConnection/StartSession 握手 vs 旧首句直接 SSE。靠时间门控垫词覆盖；必要时 session 预热（PROCESSING 入口即 open_session，与 referee 门控并行）。
- **音色迁移回归**：moon/wvae 与 xiaohe 音色不同，需用户确认新音色可接受（真机听感，deferred 到 `pipeline-stream-realmachine-acceptance`）。
- **common 依赖**：common 需 `websockets`（engine 已有）；确认 common pyproject 依赖。

## 待定问题（apply 时定稿）

- 会话式接口最终签名（session 对象 vs async generator 双向）。
- bidi resource_id 是按 speaker 后缀推断还是独立配置字段。
- 预合成超前是否仍需 engine 侧队列，还是全交给 vendor session pipelining。
- 单向 SSE 路径长期是否仅留单片段用途（删除 main 路径对它的调用后，是否还有多句调用方）。
