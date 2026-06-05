# Design — edge-recording-dev-no-modem

## Context

`edge-local-call-recording` 的录音组件 `Recorder`（`modem_controller/recorder.py`）
本身与传输路径无关：`begin_call` / `append_user` / `append_ai` / `finalize` /
`prune`，两声道都吃 16 kHz mono PCM。它的接线点才是路径相关的。

| 路径 | RtcSession 持有者 | 用户上行 tap | AI 下行 tap |
|---|---|---|---|
| modem（生产 Windows） | `AudioBridge` | `_upstream_loop` 的 `resampled`（16k） | `_downstream_loop` 的 `frame.pcm`（16k，降到 modem 8k 前） |
| dev-no-modem（mac） | `EdgeOrchestrator` 直接持有 | `_dev_no_modem_mic_capture_pump` 的 `chunk`（16k mono） | **本 change 新增** |

dev-no-modem 此前没有 AI 下行的消费者：mac SDK 通过 `onPlaybackAudioFrame`
观察者把混音播放帧丢进 `_frame_queue`，但没人 `audio_frames()` 消费它，队列
满了走 drop-oldest。SDK 自己渲染到扬声器，与队列无关。

## Decisions

### 1. AI 下行靠新增 pump 消费 `audio_frames()`

新增 `_dev_no_modem_ai_recording_pump`：`async for frame in
rtc_session.audio_frames()` → 降采 → `recorder.append_ai`。顺带把原本被丢弃的
播放帧排空。仅在录音开启（`recorder is not None and max_recordings > 0`）时
启动，避免无谓消费。

**为何不在 mac session 的 `onPlaybackAudioFrame` 里直接 tap**：分层。session
不该知道 recorder 存在；录音是 edge 编排层的关注点（与 modem 路径在
`AudioBridge` 而非 SDK 里 tap 一致）。

### 2. 48 kHz stereo → 16 kHz mono 降采

mac `onPlaybackAudioFrame` 实测 `sr=48000 ch=2`，而 recorder 写 16 kHz wav、
左声道又是 16k mono mic。必须把 AI 帧降到 16k mono 才能对齐。Py 3.14 删了
`audioop`，用 numpy（已是 recorder 依赖）：先按声道 reshape 求均值做
stereo→mono，再 `np.interp` 线性重采样到 16k（线性插值通吃任意 src_rate，不只
精确 3:1）。helper `_downmix_playback_to_engine_mono` 为纯函数，便于单测。

modem 路径无需此转换（云侧 PCM 本就 16k mono），故 helper 只服务 dev-no-modem。

### 3. 复用同一 env / 同一 teardown

dev-no-modem 入口 `_arun_dev_no_modem` 复用 `_build_recorder()`（与 modem 入口
同一 helper / 同一 env 三件套），不引入 dev 专属开关。`begin_call` 在 join 成功后、
起 pump 前调；`ctx.recorder` / `ctx.max_recordings` 一旦设上，既有的
`_CallContext.teardown`（cancel pumps → finalize → prune → leave）原样复用，
无需为 dev 路径另写收尾。

### 4. 声道对齐与时序

两个 pump 在 join 后同一时刻起，都从通话起点 append；`_write_stereo_wav` 对
较短的一轨尾部补静音。mic 跳过时（`ISALES_DEV_NO_MIC_CAPTURE=1` 或 CI）左声道
全静音、右声道照录——录音不因缺一路而失败。

## Risks / Tradeoffs

- **全程 RAM 缓冲**：沿用 `Recorder` 现状（挂断才落盘）。dev 通话短，可接受；
  与 modem 路径同样的取舍，不在本 change 改。
- **降采保真**：线性插值 + 均值 stereo→mono 对录音回放足够；非用于再喂 ASR，
  无需高保真抗混叠。
- **绝对时序对齐**：两路 append 各自实时，未按 SDK timestamp 严格对齐，回放可能
  有亚秒级偏移。dev 复盘可接受；真严格对齐是 v1.x OSS 路径的事。

## Migration

无数据迁移。env 未开（`ISALES_EDGE_RECORDINGS_DIR` 不设）时 dev-no-modem 行为
与改前完全一致。
</content>
