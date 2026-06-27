## Context

引擎出向（engine → 客户）音频当前是 **pull-driven**：`RtcTelephonyClient.audio_out()`（`rtc_telephony.py:608`）被动消费一个 TTS chunk 异步迭代器，`async for chunk in chunks:` 拿到一块就 `push_audio` 一块；没有 chunk 时不推任何帧。底层 `DingRtcSession.push_audio()`（`_session.py:519-559`）已经在做三件事：把任意大小的 PCM 切成 10ms 帧（`frame_size = sample_rate//100 * channels * 2 = 320B`）、短帧补零、按 `sleep_per_frame_s=0.008` 近实时配速逐帧 `push_external_audio`（16kHz mono int16，`ts_step_ms=10`）。SDK 内部抖动缓冲约在 200-250ms 满。

入向（客户 → engine）则另有一条**常驻泵**：`_drain_inbound_loop`（`_session.py:298`）`while joined` 每 ~20ms 轮询 DingRTC 环形缓冲，下游做 stereo→mono + 48k→16k 重采样喂给 V3 SAUC ASR。断句（ASR finalize）与 barge-in 检测都在这条入向路径上。

因此"持续背景音"无法靠"把背景音叠进 TTS chunk"实现——句间空档和静默期出向根本没有帧。需要把出向也改成常驻推帧。

## Goals / Non-Goals

**Goals:**
- 客户侧在整通通话中**持续**听到背景环境底噪，AI 说话时语音叠在底噪上、不说话时只剩底噪。
- 不改变 TTS 合成（输入仍是整句文本，韵律/音色零影响）。
- 不触碰入向 ASR / 断句 / barge-in 任何代码；断句隔离性作为硬不变量。
- 背景音素材与电平 campaign 级可配，默认关闭，对存量 campaign 行为零变化。
- 打断后背景音不中断（不再死寂）。

**Non-Goals:**
- 不做引擎侧回声消除（AEC），依赖 DingRTC 客户端 SDK 自带 AEC。
- 不支持每通电话动态切换背景音素材（一通电话锁定一个素材）。
- 不做背景音的服务端流式拉取 / CDN —— 素材预处理为本地文件，启动时预载内存。
- 不在本变更内做"背景音随对话情绪/场景自适应"等高级特性。

## Decisions

### D1：在出向引入常驻混音泵（continuous outbound mixing pump），而非"仅 TTS 时混音"

每通电话维护一个常驻 asyncio 任务（挂在 `_CallState` 上，join 后启动、hangup/leave 时取消）。泵按 10ms 墙钟稳定配速，每拍合成并推送一帧：

```
frame_samples = 160   # 16kHz × 10ms
每 10ms：
    bg   = ambient_ring.next_frame()        # 背景音环形缓冲，loop 循环；关闭时为全零
    tts  = playout_q.get_nowait() or zeros  # 出向播放队列非空取一帧，空则静音帧
    out  = clip_int16(tts + bg * gain)      # 逐样本相加 + 削顶（−32768..32767）
    rtc_session.push_external_frame(out, ts) ; ts += 10
```

- **替代方案（否决）**：在 `_play_chunks` / `push_audio` 层把背景音叠进每个 TTS chunk。否决理由——只有 TTS 有音频时才推帧，句间/静默期没有载体帧，背景音必然跟着一句一断，达不到"持续"目标。

### D2：TTS 改为喂 playout queue，而非直接 push

`audio_out()` 不再直接调 `push_audio`，改为把 TTS PCM 切成 10ms 帧 `put` 进 `_CallState.playout_q`（有界队列，背压保护）。泵是**唯一**调用 `push_external_audio` 的地方。`push_audio` 现有的"切 10ms 帧 + 补零 + 配速"逻辑：切帧/补零迁入入队侧或泵侧，**配速职责从 per-chunk sleep 转移到泵的 10ms 墙钟**（见 D4）。

- TTS 合成（`synthesize_stream` / `_SynthJob`）完全不动，输入仍是整句文本（`sentence_splitter` 50 字上限那条逻辑不变）。10ms 是出向推帧的既有粒度，不是新增约束，故合成韵律零影响。

### D3：背景音素材预处理为 16kHz mono int16，预载内存做环形缓冲

素材文件（WAV）在引擎启动或首次使用时解码/重采样为 16kHz mono int16，整段载入内存。泵用一个读指针在该 buffer 上循环（到尾回绕到头）形成无限 loop。回绕点做短交叉淡入淡出（避免接缝爆音）。

- **替代方案（否决）**：实时流式拉取/解码。否决理由——背景音是固定素材，预载内存最简单、无运行时 I/O 抖动、CPU 最低。

### D4：泵用单调墙钟配速，吸收抖动用"应到帧序号 vs 已推帧数"

泵不能用朴素 `await asyncio.sleep(0.01)` 累积漂移。用基于单调时钟的目标帧计数：`due_frames = floor((now - start)/10ms)`，落后则连推补齐、追上则 sleep 到下一拍。现有 `push_audio` 的"8ms/帧、略快于实时防欠载 + 200-250ms 抖动缓冲上限"经验值迁入泵：泵保持 SDK 缓冲在安全水位，避免溢出（`PushExternalAudioFrame failed`）或欠载（卡顿/变调）。

- **风险点**：这是本变更最危险处——配速漂移直接表现为 TTS 变调/卡顿。tasks 里单列配速稳定性测试 + 真机听感验收。

### D5：打断（barge-in）改为清空 playout queue

现状打断取消 `current_speaking_task`。改为：打断时 drain/清空 `playout_q`（丢弃未播的 TTS 帧），泵下一拍起只推背景音 → 打断后立即静语音但背景音延续，不死寂。`current_speaking_task` 取消逻辑保留以停止 TTS 合成侧。

### D6：campaign 级配置 `ambient_audio` + `ambient_gain`，默认关闭

- `ambient_audio`：背景音素材标识（字符串，空/NULL = 关闭，泵 bg 帧恒为全零，行为等价现状）。
- `ambient_gain`：混音电平（float，建议默认对应 -20dB 量级，范围限定避免过载）。
- common 加列（加性 alembic 迁移）、api 透传、web 配置入口。dial 消息把这两个字段带给引擎。

## Risks / Trade-offs

- **回声：背景音漏回客户麦克风被 ASR 误判为说话** → 缓解：① `ambient_gain` 低电平（-20dB 量级）；② DingRTC 客户端 SDK 自带 AEC；③ 优先选无人声底噪（办公室白噪/风扇声），避免人声底噪被当成第三方说话。**必须真机实测**：开背景音后入向 ASR 不应出现持续 partial / 误 finalize / 误触发 barge-in；否则下调电平或换素材。无真机回声验收不视为完成。
- **实时配速漂移 → TTS 变调/卡顿** → 缓解：D4 单调墙钟 + 应到帧序号补齐；保留现有 SDK 抖动缓冲水位经验；配速测试 + 真机听感验收。
- **每通一个常驻泵的 CPU/任务开销** → 逐样本混音用 numpy/`audioop.add` 向量化，单帧 160 samples 极轻；N 并发 = N 个泵 + N 份背景 buffer（素材 buffer 可全局共享只读，读指针 per-call）。可接受。
- **背景音 loop 接缝爆音** → 回绕点交叉淡入淡出。
- **断句隔离**：背景音只进出向、入向代码零改动，断句路径物理隔离——这是设计不变量，不是缓解措施；spec 将其列为 MUST。
