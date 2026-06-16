## Why

通话出向音频目前只有 TTS 语音、没有任何环境底噪：AI 一开口才有声音，句间空档和静默期完全静音。客户侧听感是"在一个真空里跟机器人对话"，缺乏真人坐席所处的呼叫中心/办公室环境感，真实感不足、易被识别为机器外呼。

引擎出向是 pull-driven 的（`rtc_telephony.py:608` `audio_out()` 只在 TTS 吐出 PCM chunk 时才推帧），所以"持续背景音"不是简单地把背景音叠进 TTS chunk 就能做到——句间和静默期根本没有帧在推。要让客户侧**持续**听到背景音，必须在出向引入一个常驻推帧的混音泵。

## What Changes

- 在引擎出向音频链路引入**常驻出向混音泵（continuous outbound mixing pump）**：每通电话一个常驻任务，按 10ms 墙钟稳定配速，无论 AI 是否在说话都持续推帧。
- 每帧（16kHz mono int16，160 samples）= 背景音环形缓冲取一帧（loop 循环）+ 出向播放队列（playout queue）有 PCM 则取一帧、无则全零，逐样本相加并削顶（clip）保护，再 `push_external_audio` 推给 DingRTC。
- TTS 播放路径从"直接 push 给 DingRTC"改为"把已合成的 PCM 喂进 playout queue"。**TTS 合成输入仍是整句文本，合成不动**；10ms 切帧是出向推帧的既有粒度（`_session.py:527` frame_size=320B / ts_step=10ms 本就存在），不影响合成韵律。
- 打断（barge-in）时清空 playout queue 即可，背景音由泵继续推 → 打断后不再死寂。
- 附带：连续推帧消除了空档期出向时间戳跳跃（现状不推帧时戳不递增）。
- campaign 级新增配置：`ambient_audio`（背景音素材标识，空=关闭）+ `ambient_gain`（混音电平），默认关闭，白名单 campaign 开启。
- web 管理端新增背景音配置入口（素材选择 + 电平）。

非目标 / 明确不做：
- **不改入向（ASR / 断句）路径任何代码**——背景音只在出向，断句隔离性见 Impact。
- 不做客户侧 AEC（依赖 DingRTC SDK 客户端自带），引擎侧不引入回声消除。

## Capabilities

### New Capabilities
- `ambient-background-mix`: 出向常驻混音泵将持续背景环境音混入发给客户的音频；定义泵的配速契约、playout queue 与 TTS 的关系、背景音 loop 与电平、打断时的行为、以及与入向 ASR/断句的隔离不变量。

### Modified Capabilities
- `data-model`: campaign 新增 `ambient_audio` / `ambient_gain` 两列（默认关闭）。
- `web-admin-ui`: campaign 配置新增背景音素材与电平的编辑入口。

## Impact

- **isales-engine**：`realtime/rtc_telephony.py`（`audio_out` / `_CallState` 加泵 + playout queue + 时间戳连续化）、`transport/dingrtc/_session.py`（泵驱动 `push_external_audio`，现有 per-chunk 切帧/配速逻辑迁入泵）、新增背景音素材加载与预处理（→ 16kHz mono int16 预载内存）、打断路径改为清空 playout queue。
- **isales-common**：campaign 模型 + Pydantic schema 加 `ambient_audio` / `ambient_gain`；alembic 迁移；版本号 bump + 下游 pin。
- **isales-api**：campaign 读写透传新字段。
- **isales-web**：campaign 配置面板加背景音配置控件。
- **断句隔离不变量**：断句（ASR finalize）在入向（客户音频 → DingRTC → V3 SAUC ASR），背景音在出向，两条独立音频流，混音不触及入向；proposal/spec 将此列为硬不变量。
- **回声风险**：背景音经客户听筒可能漏回客户麦克风被 ASR 误判为说话；缓解=低电平（相对 TTS -20dB 量级）+ DingRTC 客户侧 AEC + 优先选无人声底噪。需真机实测验收（无验收不视为完成）。
- **实时配速风险**：泵从"被 TTS chunk 节奏驱动"改为"被 10ms 墙钟驱动"，配速漂移会导致 TTS 变调/卡顿，是本变更最需谨慎处。
