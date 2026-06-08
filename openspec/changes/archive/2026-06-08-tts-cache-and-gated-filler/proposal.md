## Why

`pipeline-latency-tail` 把句间空档和连接握手压下去了，但用户真通话体感剩两个可下手点（对照 voxen 源码 `core/provider/tts/cache/`）：

1. **固定话术每通实时合成**。`campaign.greeting`（开场白，用户听到的**第一声**）、silence / transfer / wrap-up / filler / "您请说" 等固定文本，每通都走一次 TTS（~330ms 首字节 + 网络）。voxen 把这类固定文本**缓存**（内存 + 磁盘），命中即零合成零网络。iSales 没有缓存层。

2. **垫词功能基本没用**：`filler_enabled` 默认 `false`；即使开了，现在是**每轮 PROCESSING 一开始就立刻播垫词**（不是"超时才垫"），且 `FillerManager._stream_audio` 走**实时 TTS**——垫词自己还要等合成，起不到遮延迟的作用。

## What Changes

### A — 固定话术 TTS 缓存

- 新增 `CachingTTSProvider`（装饰 `TTSProvider`）：`synthesize_stream(text, voice_id)` 命中进程级缓存即重放已存 PCM（零合成）；未命中则透传 inner provider、边播边累积、结束后存入缓存。
- 缓存是**进程级单例 store**（跨通话共享；engine 进程内开场白第一通合成、之后零延迟），不是 per-call。
- 只缓存**短文本**（≤ `max_cacheable_chars`，默认 60）——固定话术都短，动态 main 回复长、不缓存（避免缓存爆 + 浪费）。
- store 有界（LRU，默认上限 N 条 / 总字节上限），避免无界增长。
- main.py 在进程启动建一个 store，per-call `build_tts(...)` 外面包 `CachingTTSProvider(inner, store)`。

### B — 时间门控垫词

- `run_loop._play_streaming`：不再 PROCESSING 一开始就播垫词。改为起一个计时器，**首音频超过 `filler_delay_ms`（默认 600）还没出**才播一句垫词；首个真句就绪即取消计时器 + 停垫词。
- 垫词音频走 A 的缓存（命中零合成）才真正起到"遮 LLM TTFT"的作用。
- `campaign.filler_delay_ms`（INT, nullable，默认 600）可调。

## Capabilities

### New Capabilities

无（缓存是 provider-abc 内部成分；门控垫词是 ai-pipeline filler 行为）。

### Modified Capabilities

- `provider-abc`: § "TTSProvider" 增补可选缓存装饰约束（命中重放、未命中透传并填充、有界）。
- `ai-pipeline`: § "filler" 从"每轮即播"改为"首音频超时才播"；垫词音频走缓存。
- `data-model`: § "campaign 字段" 新增 `filler_delay_ms`。

## Impact

**受影响 sub-repo**：
- `isales-engine`（主）：新增 `providers/tts_cache.py`；`main.py` 建 store + 包装；`run_loop._play_streaming` 门控垫词；`runtime_config` 读 `filler_delay_ms` 透传。
- `isales-common`：`campaign.filler_delay_ms` 列 + schema + alembic（additive）。
- `isales-api` / `isales-web`：`filler_delay_ms` 配置入口（filler 配置页）。

**数据库 migration**：additive 一列（`campaign.filler_delay_ms INT NULL`）。

**部署顺序**：common（migration）→ engine → api → web。

**性能预期**：
- 开场白第二通起首声 ~330ms→~0（缓存命中）。
- silence/transfer/wrap-up/filler 等固定话术命中零合成。
- 垫词只在真慢（>600ms）时出现，且零合成 → 遮住 LLM TTFT 体感空档，不污染快轮次。

**风险**：
- 缓存 PCM 占内存 → 有界 LRU + 短文本 gate 控制。
- 缓存键 (text, voice_id) → 换 voice 自然 miss 重新合成，正确性透明。
- 门控垫词太频繁 → `filler_delay_ms` 可调；默认 600ms 只在真慢时触发。

**Non-Goals**：
- 不做磁盘 / OSS 持久化缓存（v1 进程级内存；磁盘/OSS 列 followup）。
- 不做固定话术的**启动预热**（v1 懒缓存，第一通暖；预热 followup）。
- 不动 close_timeout barge-in（另一个 change `asr-speaking-ear-close-timeout`）。
