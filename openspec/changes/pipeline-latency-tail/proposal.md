## Why

`pipeline-stream-and-referee` 把首音频从 ~6500-9500ms 降到 PROCESSING-measured `first_audio_ms ~800ms`，已上线 ECS 并在 `call_record 137` 真通话验证。但用户实测**感知延迟**（停说话 → 听到 AI 第一声）对比 voxen 仍有明显差距，且全程"发飘"。

在 `call_record 137` + ECS engine 日志上定位到 4 个阻塞点（`first_audio_ms` 只量了 PROCESSING→首句，漏掉了前后两大块）：

- **A — ASR 端点延迟**：`asr_volcengine._PARTIAL_STABLE_S=0.7`，用户停说话后硬等 0.7s 才判 EOS（日志每轮 `stable_for_s=0.7x`），全程在 PROCESSING **之前**纯死等。voxen 约 0.2-0.3s。
- **B — main LLM 与 TTS 串行无预合成（最大体感主因）**：`run_loop._play_streaming` 里 `await _play_tts(sentence)` 等整句音频播完才回头从生成器拉下一句 → (1) main LLM `chat_stream` 在播音期间被挂起，没法边播边生成；(2) 句与句之间有 250-500ms 静音空档（下一句 TTS 此时才开始合成；实测 `volcengine_tts_first_byte latency_ms=253-498`/句）。
- **C — TTS 每句新建连接**：`tts_volcengine.synthesize_stream` 每次都 `async with httpx.AsyncClient(...) as client, client.stream(...)` 新开连接，而 `_play_streaming` 每句调一次 → 每句白付一次 TLS 握手 + vendor session 建立。
- **D — transfer 阻主链**：`transfer.manager.evaluate_transfer` 在 PROCESSING **之前**同步调 LLM（`transfer_intent` / `transfer_llm`，json_mode），开了的 campaign 每轮多一整轮 LLM round-trip 卡在主链路前；而 referee 现在已经判 `transfer`，这是重复（campaign 1 当前 transfer 全 false 未踩，但是潜在阻塞）。

本 change 吸收原 `pipeline-stream-and-referee` §19.1 `asr-fast-eos` followup 占位。

## What Changes

### B — main streaming 与 TTS 解耦 + 预合成（核心）

- **重写** `run_loop._play_streaming` 为 producer/consumer：producer 跑 `chat_stream → split_sentences` 持续填一个有界 `asyncio.Queue`（不被播放挂起，main LLM 跑到底）；consumer 拉句子 → TTS → audio_out。
- **预合成**：consumer 播第 N 句的同时，第 N+1 句的 TTS 已经在合（队列里缓冲的是"已就绪的 PCM 流 / TTS 句柄"），消灭句间静音空档。
- **兼容 barge-in**：partial_monitor cancel `current_speaking_task` 仍生效；producer + consumer + 预合成任务在打断时一并 cancel；`first_audio_ms` 记录点不变。

### C — TTS 连接复用

- `VolcengineTTSProvider` 持有一个持久 `httpx.AsyncClient`（构造时建、provider 生命周期内复用），`synthesize_stream` 复用它而非每次新建；连接在 keep-alive 下跨句省 TLS 握手。provider close 时显式 `aclose()`。

### A — ASR 端点可调 + 默认更激进

- `asr_volcengine._PARTIAL_STABLE_S` 从写死 0.7 改为**可配置**，默认降到 0.4。
- **新增** campaign 级可调：`campaign.asr_eos_silence_ms`（默认 400，nullable→走默认）；`load_runtime_config` 读出 → 透传到 ASR provider 构造。
- isales-api / isales-web 配套暴露该字段（编辑 + 提示"太短会把停顿误判成说完"）。

### D — transfer LLM 移出关键路径

- `evaluate_transfer` 拆分：便宜的 **keyword / round** 检测保留 inline（在 PROCESSING 前，零 LLM）；**intent / llm**（带 LLM 调用）的检测**移出主链路** —— 优先复用 referee 的 `transfer` decision；过渡期若 campaign 仍单独配 `transfer_llm`，则与 main streaming 并行 spawn（像 referee 一样），不阻塞 PROCESSING 入口。

## Capabilities

### New Capabilities

无。均为 `ai-pipeline` capability 内部成分的延迟优化 + `data-model` 加一个可调字段。

### Modified Capabilities

- `ai-pipeline`: § "单 main LLM streaming" 增补 producer/consumer + TTS 预合成的并发模型描述；§ "referee 二级决策" 增补 transfer LLM 检测复用 referee。
- `provider-abc`: § "TTSProvider" 增补连接复用约束（provider 可持久化底层连接，MUST 在 close 时释放）。
- `data-model`: § "campaign 字段" 新增 `asr_eos_silence_ms`。
- `interruption-detection`: § barge-in 与新 producer/consumer 播放模型的兼容性说明（cancel 语义不变）。
- `web-admin-ui`: § "Campaign 配置页" 加 `asr_eos_silence_ms` 输入。

## Impact

**受影响 sub-repo**：
- `isales-engine`（主）：`run_loop._play_streaming` 重构 / `tts_volcengine` 连接复用 / `asr_volcengine` 端点参数化 / `transfer.manager` 移位 / `runtime_config` 透传 eos 参数。
- `isales-common`：`campaign.asr_eos_silence_ms` 列 + schema + alembic migration（additive）。
- `isales-api` / `isales-web`：`asr_eos_silence_ms` 配置入口。

**数据库 migration**：additive 一列（`campaign.asr_eos_silence_ms INT NULL`），无破坏性。

**部署顺序**：common（migration）→ engine → api → web。engine 是体感主战场，可先单独上 B+C+A-default 再补 campaign 可调 UI。

**性能预期**：
- 句间静音空档（250-500ms × N-1 句）基本消除 → 连续语音感（B，最大体感提升）。
- TTS 每句省 ~100-200ms TLS（C）。
- 开口省 ~300ms（A，0.7→0.4）；campaign 可进一步压。
- 开了 transfer_llm 的 campaign 每轮省一整轮 LLM round-trip（D）。
- 目标：mac dev 真通话 EOS→首音频接近 voxen ~0.5-1.5s，句间无明显静音。

**风险**：
- A 端点太短 → 把用户的自然停顿误判成"说完"提前打断 → **Mitigation**：默认 0.4 保守，campaign 可调；mac dev 跑足样本校准。
- B 重构 producer/consumer → barge-in cancel 语义回归风险 → **Mitigation**：保留 `current_speaking_task` cancel 路径，新增测试覆盖打断点落在"预合成中 / 播放中 / 队列等待中"三态。
- C 持久连接 → vendor 空闲断连 / 半开连接 → **Mitigation**：httpx keep-alive + 失败时单次重连（已有 provider retry 语义）。

**Non-Goals**：
- 不重做 referee / extractor 逻辑。
- 不换 main LLM 模型做 TTFT 优化（另起 change 评估）。
- 不动 DingRTC 自环 / VAD 那条已知 barge-in 误触线（属 telephony/SDK 层）。
