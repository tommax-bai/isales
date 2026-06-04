## Context

`pipeline-stream-and-referee`（已 archive 前的最后阶段 / 已部署 ECS）实测：`first_audio_ms` 在 PROCESSING-measured 层面 678-1106ms，达标。但该指标不含 (a) 用户停说话 → EOS 的 ASR 端点等待，(b) 句间 TTS 合成空档。用户对照 voxen 仍觉延迟明显、全程发飘。

诊断证据（`call_record 137`，ECS `isales-engine` 日志，2026-06-04）：

- `volcengine_asr_partial_stable: text='嘿，你好' stable_for_s=0.76 (thr=0.70)` —— 每轮 EOS 前硬等 0.7s。
- `volcengine_tts_first_byte latency_ms=253-498 text_len=11-41`/句 —— 每句独立 TTS round-trip，且 `tts_volcengine.synthesize_stream` 每次新建 `httpx.AsyncClient`。
- `_play_streaming` 串行：`async for sentence in sentences: ... await _play_tts(sentence)` —— 播放期间生成器挂起。
- `evaluate_transfer` 在 `sm.transition_to(PROCESSING)` 之前；`transfer_llm_enabled` 时内含 `await llm.chat(json_mode=True)`。

## Goals / Non-Goals

**Goals**：
- 消除句间静音空档，实现连续语音（B）。
- main LLM 不被播放挂起，跑到底（B）。
- TTS 跨句复用连接（C）。
- 开口端点延迟可调、默认更激进（A）。
- transfer 的 LLM 检测不再卡在 PROCESSING 之前（D）。
- mac dev 真通话 EOS→首音频接近 voxen ~0.5-1.5s，句间无明显静音。

**Non-Goals**：
- 不重做 referee / extractor。
- 不换 main 模型做 TTFT 优化。
- 不动 DingRTC 自环 / VAD barge-in 误触（telephony/SDK 层）。
- 不引入新的 RTC / 编解码路径。

## Decisions

### 决策 1：B —— producer/consumer + TTS 预合成

`_play_streaming` 重写为两段并发：

```python
# 伪码
async def _play_streaming(...):
    sentences = stream.sentences()                # producer: chat_stream -> split
    pcm_q: asyncio.Queue[_SynthJob | None] = asyncio.Queue(maxsize=2)

    async def _producer():
        async for s in sentences:
            # 立即 kick off TTS 合成(不等播放)，把"就绪句柄"塞队列
            await pcm_q.put(_SynthJob(text=s, pcm=tts.synthesize_stream(s, voice_id)))
        await pcm_q.put(None)                      # sentinel

    prod = asyncio.create_task(_producer())
    while True:
        job = await pcm_q.get()
        if job is None:
            break
        played = await _play_pcm(job.pcm)          # 播放当前；下一句已在 producer 侧合成
        if not played:                              # barge-in
            prod.cancel(); ...; return first_audio_ms, False
    ...
```

**关键点**：
- `maxsize=2` 有界队列：producer 最多领先 consumer 2 句（避免 LLM 跑太快堆爆内存 / 浪费 TTS 配额，也限制打断时已合成的"沉没成本"）。
- 预合成：把 `tts.synthesize_stream(s)`（一个 async iterator / 未来）塞队列，consumer 取出即播 —— 播 N 时 N+1 的 TTS 已在 vendor 侧产音。
- `first_audio_ms` 记录点：consumer 播放第一个 job 的首 PCM chunk 时（语义不变）。
- main LLM `chat_stream` 由 producer 持续消费，不再被播放挂起。

**Rationale**：voxen 的连续感来自"生成 / 合成 / 播放"三级流水并行。有界队列是流水缓冲。

**Alternatives**：
- (A) 不预合成、只解耦生成与播放：仍有句间 TTS 首字节空档。否决。
- (B) 无界队列：LLM 远跑在前 → 打断时浪费大量已合成音频 + 内存。否决，用 maxsize=2。

### 决策 2：B 的 barge-in 兼容

打断点可能落在三态：consumer 正播放（cancel `current_speaking_task`）/ producer 正合成下一句 / 队列等待。统一处理：barge-in 信号 → cancel consumer 当前播放 + cancel producer task + drain 队列里未播的 job（关闭其 TTS iterator）。`current_speaking_task` 仍指向"当前正播的 audio_out task"，partial_monitor 的 cancel 路径不变。

**测试**：新增覆盖三态打断 + 打断后 `interrupted=True` + 下一轮 LISTENING 正常。

### 决策 3：C —— TTS provider 持久连接

`VolcengineTTSProvider.__init__` 建一个 `self._client = httpx.AsyncClient(timeout=..., limits=keepalive)`，`synthesize_stream` 用 `self._client.stream(...)` 而非新建。新增 `async def aclose()` 释放。engine provider 生命周期与进程同寿（factory 单例），故无需每通关。

**Rationale**：keep-alive 复用 TCP+TLS，省每句握手。vendor SSE 是短连接 per request，但底层 TCP 连接池复用。

**风险兜底**：httpx 自动处理半开连接重连；保留现有 `ProviderError` 重试一层。

### 决策 4：A —— ASR 端点参数化 + campaign 可调

- `asr_volcengine` 把 `_PARTIAL_STABLE_S` 改为构造参数 `partial_stable_s`，默认 0.4（原 0.7）。
- `campaign.asr_eos_silence_ms`（INT, nullable，默认语义 400）。`load_runtime_config` 读 → 传给 ASR provider 构造（factory 接受可选 override，或 runtime 注入）。
- 默认 0.4 是保守激进：比 0.7 快 300ms，又给犹豫者留 0.4s。campaign 可压到 0.25 或放宽到 0.6。

**Rationale**：端点是 latency/打断误判的权衡点，必须 campaign 可调（不同话术 / 客群停顿习惯不同）。

**Alternatives**：写死 0.3 —— 太激进会频繁打断慢说话客户。否决，做成可调 + 默认 0.4。

### 决策 5：D —— transfer LLM 移出主链路

`evaluate_transfer` 拆为 `evaluate_transfer_cheap`（keyword / round，纯字符串 / 计数，inline 在 PROCESSING 前，零 LLM）+ LLM 检测移出：
- **首选**：删除独立 `transfer_intent` / `transfer_llm` 的 inline LLM 调用，**复用 referee 的 `transfer` decision**（referee 已判 transfer）。campaign 的 `transfer_intent_threshold` 等语义迁移说明写进 spec。
- **过渡兼容**：若 campaign 仍显式配 `transfer_llm_enabled` 且 referee 未覆盖该语义，则把该 LLM 检测**与 main streaming 并行 spawn**（不阻塞 PROCESSING 入口），结果在 SPEAKING 结束前 await（同 referee 模式）。

**Rationale**：referee 本就是"旁路结构化决策"，transfer 是它四个 decision 之一。inline transfer LLM 是 pipeline-stream-and-referee 没清理干净的重复。

**Open**：keyword/round 的 inline 检测是否也并入 referee？本 change 保留 inline（零成本、确定性高，适合硬关键词如"投诉""转人工"）。

## Risks / Trade-offs

- **B 重构回归**：producer/consumer + 预合成是并发改写，barge-in / 异常传播 / 队列 drain 易出 bug → **Mitigation**：三态打断测试 + 异常注入测试（producer 中途抛 / consumer 播放抛 / TTS 合成抛）+ mac dev 真通话回归。
- **A 误打断**：端点太短把停顿当说完 → **Mitigation**：默认 0.4 不激进，campaign 可调，mac dev 校准。
- **C 半开连接**：持久连接遇 vendor 空闲断连 → **Mitigation**：httpx keep-alive 自愈 + 一层重试。
- **D 语义迁移**：transfer_intent/llm 的 campaign 配置含义变化（迁到 referee）→ **Mitigation**：spec 写清迁移；过渡期并行 spawn 兜住显式配置的 campaign。
- **预合成浪费**：打断时队列里已合成的 N+1 被丢 → 浪费 1-2 句 TTS 配额 → **Mitigation**：maxsize=2 限制沉没成本；可接受（TTS 便宜，体感优先）。

## Migration Plan

1. **isales-common**：`campaign.asr_eos_silence_ms` 列 + schema + alembic（additive）。bump 版本。
2. **isales-engine**：B（`_play_streaming` 重写）/ C（tts 连接复用）/ A（asr 参数 + runtime_config 透传）/ D（transfer 拆分 + referee 复用）。
3. **isales-api / isales-web**：`asr_eos_silence_ms` 配置入口。
4. **部署**：common → engine → api → web（scp/rsync editable，同 pipeline-stream-and-referee 路径）。engine 可先单独上 B+C+A-default 拿体感，再补 campaign 可调链路。
5. **验收**：mac dev 真通话量 EOS→首音频 + 句间空档；ECS 日志看 `tts_first_byte` 是否跨句复用连接（连接建立次数）。

## Open Questions

- **Q1**：预合成队列 `maxsize` 取 2 还是 3？太大浪费打断沉没成本，太小退化回串行。→ 默认 2，mac dev 实测调。
- **Q2**：`asr_eos_silence_ms` 默认 400 还是 350？→ 暂定 400，mac dev 跑 350/400/500 三档对照。
- **Q3**：D 完全删 inline transfer_llm 还是保留并行 spawn 兜底？→ 倾向"referee 复用为主 + 显式 transfer_llm campaign 走并行兜底"，最终看 referee transfer 召回质量。
- **Q4**：C 持久连接是否每通话 reset？→ 不 reset（provider 进程级单例），靠 httpx keep-alive；若 vendor 强制 per-session 鉴权再评估。
