## Context

TTS provider 在 `main.py._make_runner._run` 里 **per-call** 构造（`build_tts(...)`），生命周期与一通话同寿（`pipeline-latency-tail § C` 给它加了持久 httpx client + aclose）。固定话术（greeting / silence / transfer / wrap-up / filler / "您请说"）每通都现合成。

filler 现状：`run_loop` 在 PROCESSING 入口 `if config.filler_enabled: filler = FillerManager(...); await filler.start()` 立刻播；`_play_streaming` 收到第一个就绪 job 时 `filler.stop()`。`FillerManager._stream_audio` 走 `tts.synthesize_stream` 实时合成。

## Goals / Non-Goals

**Goals**：
- 固定话术命中缓存 → 零合成零网络（尤其开场白首声）。
- 垫词改为"首音频超时才播" + 走缓存音频，真正遮 LLM TTFT。
- 缓存有界、进程级、跨通话共享、对正确性透明。

**Non-Goals**：
- 不做磁盘/OSS 持久化（进程级内存）。
- 不做启动预热（懒缓存）。
- 不动 main 动态回复缓存（短文本 gate 自然排除）。

## Decisions

### 决策 1：CachingTTSProvider 装饰器 + 进程级 store

```python
class TtsCacheStore:
    """进程级有界 LRU: key=(text, voice_id) → list[bytes] (PCM chunks)。"""
    def __init__(self, *, max_entries=256, max_total_bytes=32<<20): ...
    def get(self, key) -> list[bytes] | None: ...
    def put(self, key, chunks: list[bytes]) -> None: ...   # LRU evict

class CachingTTSProvider(TTSProvider):
    def __init__(self, inner: TTSProvider, store: TtsCacheStore, *, max_cacheable_chars=60): ...
    async def synthesize_stream(self, text, voice_id):
        key = (text, voice_id)
        hit = self._store.get(key)
        if hit is not None:
            for c in hit: yield c
            return
        if len(text) > self._max_cacheable_chars:
            async for c in self._inner.synthesize_stream(text, voice_id): yield c
            return
        buf = []
        async for c in self._inner.synthesize_stream(text, voice_id):
            buf.append(c); yield c
        self._store.put(key, buf)        # 仅在完整成功后存
    async def aclose(self): await self._inner.aclose()
```

**关键点**：
- store 在 `main.py._main` 建一次（进程级），传进 runner；per-call `CachingTTSProvider(build_tts(...), store)`。aclose 透传给 inner（持久 client 仍每通关）。
- 短文本 gate（≤60 字）：固定话术都短；动态 main 回复长 → 不缓存。
- 只在 iterator **完整跑完**才 put（中途异常/打断不污染缓存）。
- 命中重放：直接 yield 存好的 chunks，零合成零网络。

**Rationale**：voxen 同款（cache 装饰 + 内容类型/长度门）。装饰器不改 TTSProvider ABC、不改调用方。

**Alternatives**：
- 进程级单 TTS provider（非 per-call）：能天然共享，但要改 provider 生命周期 + 持久 client 跨通话，回归面大。否决，用"per-call provider + 进程级 store"。
- 显式 `cacheable` 标志传进 synthesize_stream：改 ABC 签名。否决，用长度 gate 隐式判定。

### 决策 2：时间门控垫词

`_play_streaming` 重构 filler 触发：

```python
# 不在 PROCESSING 入口 start filler。改在 _play_streaming 内:
filler_task = None
if filler is not None:
    async def _maybe_filler():
        await asyncio.sleep(filler_delay_s)        # 默认 0.6s
        if first_audio_ms is None:                  # 首音频还没出
            await filler.start()                    # 播缓存垫词
    filler_task = asyncio.create_task(_maybe_filler())
# 消费第一个 job 前: filler_task.cancel() + (filler.stop() if started)
```

**关键点**：
- 首音频 < 600ms 出 → 计时器还没 fire → 取消 → **不播垫词**（快轮次干净）。
- 首音频 > 600ms → 计时器 fire → 播缓存垫词遮空档 → 首个真句就绪时停垫词接上。
- 垫词 TTS 走 CachingTTSProvider → 命中零合成（FillerManager 的 tts 就是包装后的 provider）。
- `filler_delay_ms` 来自 `campaign.filler_delay_ms`（NULL→600），`runtime_config` 透传。

**Rationale**：垫词价值是"遮 LLM 慢"，只该在真慢时出现；且必须零合成才不自相矛盾。

## Risks / Trade-offs

- **缓存内存**：有界 LRU（默认 256 条 / 32MB）+ 短文本 gate。固定话术集很小，远不到上限。
- **voice 变更**：key 含 voice_id，换音色自然 miss 重合成，透明。
- **门控垫词与预合成竞争**：filler 与 producer/consumer 并发；filler 播放走 audio_out，与主 job 的 audio_out 互斥（停 filler 再播主句，沿用现有 stop 语义）。
- **缓存污染**：仅完整成功 put；打断/异常不存。

## Migration Plan

1. isales-common：`campaign.filler_delay_ms` 列 + schema + alembic（additive）。bump 版本。
2. isales-engine：`providers/tts_cache.py`（store + 装饰器）；`main.py` 建 store + 包装；`run_loop._play_streaming` 门控垫词；`runtime_config` 透传 `filler_delay_ms`。
3. isales-api / isales-web：`filler_delay_ms` 配置入口（filler 配置页）。
4. 部署：common → engine → api → web。
5. 验收：mac dev 真通话——第二通开场白首声接近零；填一个慢轮次看垫词只在 >600ms 时出现且无合成延迟。

## Open Questions

- **Q1**：`max_cacheable_chars` 60 够覆盖固定话术？→ greeting/silence/transfer 一般 < 40 字；60 留余量。可调。
- **Q2**：`filler_delay_ms` 默认 600？→ 暂定 600（≈ 当前 LLM 首句延迟中位），mac 实测调。
- **Q3**：store 上限 256/32MB？→ 固定话术远小于此；保守上限防异常。
