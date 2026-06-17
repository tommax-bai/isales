## Why

长文本合成时音色 / 语气会逐句突然跳变。根因不是帧衔接，而是**结构性的**：引擎把每轮回复按句切（`sentence_splitter.py`，命中句末标点或满 50 字 emit），**每一句发一个完全独立的单向 SSE 请求**（`run_loop.py` 的 `_SynthJob` → `synthesize_stream(text, voice_id)`），请求间无任何上下文 → 每句重新规划语调、重置音高基线、句尾各做一次降调，听感就是上下句「跳一下」。`emotion_scale=2` 只能压低摆幅，消不掉冷启动重置。治本是迁到**整轮一个双向流式 session**：LLM 文本增量持续喂入同一 session，vendor 跨句统一规划韵律 = 一条连续嗓子。

双向端点 `wss://openspeech.bytedance.com/api/v3/tts/bidirection` 已用探针脚本（`isales-engine/scripts/tts_bidi_probe.py`）实测：本账号可用、**不需新 grant**，但 `resource_id ↔ speaker` 严格绑定 —— 现生产音色 xiaohe（`seed-tts-2.0` / `*_uranus_bigtts`）双向声学层不跑、零音频；必须把 campaign 音色换到 moon/wvae 家族（`volc.service_type.10029`，如 shuangkuaisisi / M392）才能双向。

## What Changes

- **新增** `isales-common` 双向流式 TTS 路径：在 `VolcengineTTSProvider`（或同模块新类）实装 V3 bidirection WS 协议（StartConnection → StartSession → 多个 TaskRequest → FinishSession，二进制帧家族同 ASR SAUC），暴露**会话式接口**：开 session → 持续 `feed(text)` → 流式收 PCM → `finish()` / `close()`。
- **修改** TTS Provider ABC：在保留一次性 `synthesize_stream(text, voice_id)` 的基础上，新增会话式合成接口（`synthesize_session(...)` 或等价），供多句连续轮次使用。一次性接口仍服务于**单片段**场景（开场白 / 垫词 / 默认回复 / listen_only 引导语 / api 试听）—— 这些天然无跨句韵律收益，不是 fallback，是不同调用形态。
- **修改** 引擎主回复播放路径（`_play_streaming`）：把「每句一个 `_SynthJob` 独立请求」改成「整轮开一个 TTS session，sentence_splitter 切出的句子依次 `feed` 进同一 session，消费端播放连续音频流」。barge-in / teardown 时 `close()` 该 session（替代 `_SynthJob.aclose()` 的逐句取消）。保留 `first_audio_ms` 锚点（PROCESSING 进入起算）与时间门控垫词逻辑。
- **修改** campaign 音色：生产 campaign 的 `voice_id` 从 xiaohe 迁到 bidi-capable 的 moon/wvae 家族；bidi 路径按 speaker 家族选 `resource_id`（`volc.service_type.10029`），与现有 `_resource_for` 同款分流。
- **保留** 单向 SSE 路径不删 —— 单片段场景继续用它（见上）。**不引入**「双向失败回落单向」这类运行时多层兜底（遵 `feedback-avoid-multilayer-fallback`）：bidi 音色配错是配置错误，应 fail-loud，不静默回落。

## Capabilities

### New Capabilities
<!-- 无新增 capability：双向流式是现有 TTS provider 契约 + AI 管线合成路径的演进，落在既有 spec 上。 -->

### Modified Capabilities
- `provider-abc`: TTS Provider 接口在一次性 `synthesize_stream` 之外，新增**会话式双向流式合成接口**（一个 session 跨多句、文本增量喂入、连续 PCM 输出、可中途 close）；明确两种接口的适用边界（多句轮次 vs 单片段）。
- `ai-pipeline`: 「main LLM 流式 token → sentence → TTS」与 sentence boundary detector 的下游消费方式从「每句独立 `synthesize_stream`」改为「整轮一个 TTS session、句子依次 feed、统一韵律」；明确 barge-in 关 session 语义；明确开场白 / 简化管线 / 默认回复 / listen_only 仍走一次性合成。

## Impact

- **代码**：
  - `isales-common/isales_common/providers/tts_volcengine.py`（+ 可能拆分 bidi 子模块）、`providers/tts.py`（ABC）、`providers/testing` 的 `MockTTSProvider`（补会话式接口）。
  - `isales-engine/isales_engine/run_loop.py`（`_SynthJob` / `_play_streaming` 重构）、相关 `tests/test_play_streaming.py`、`test_providers.py`、`test_tts_cache.py`。
  - `isales-common` 版本号 bump + 六个消费仓 pin 更新（按本仓 CLAUDE.md 跨仓约定）。
- **数据 / 配置**：生产 campaign `voice_id` 迁到 moon/wvae；`provider_credential` 的 `tts_resource_id`（bidi 用 `volc.service_type.10029`）核对。无新增 alembic 列（voice_id / resource_id 均已存在）。
- **依赖**：`isales-common` 新增 `websockets`（engine 已依赖，common 需确认）。
- **部署**：scp engine + common 到 ECS，重启 engine。
- **验收**：真机拨测听感（跨句连续 vs 旧逐句起伏）属 `pipeline-stream-realmachine-acceptance` 范畴，本 change deferred 真机听感对比到该 change。
- **风险**：bidi session 生命周期与 barge-in 中途 close 的竞态；首音延迟（session 建连握手 vs 旧逐句 SSE）—— 靠垫词与 session 预热覆盖。
