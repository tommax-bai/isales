## Why

被打断时 AI 的声音瞬间硬切到静音，客户听感很突兀、不像真人。这其实是两个独立缺陷叠加：(1) 在振幅非零处一刀切产生高频爆音 click（纯声学失真）；(2) 收声比真人生理极限（换话间隔最常见 ~200ms、被打断者往往把当前字说完再 trailing-off）还快、且毫无收尾，所以耳朵立刻判定「这是机器」。现状代码 `_flush_playout()` 在 barge-in 时同步清空整条 playout 队列、下一帧即推 `SILENCE_FRAME`，TTS 在 <1ms 内阶跃归零，无任何斜坡。主流语音 AI 框架（LiveKit / OpenAI Realtime / Vapi）也都是硬切——给收声加一段淡出是它们普遍跳过的低成本自然度提升点。

## What Changes

- **打断收声改为渐隐淡出，不再硬切。** barge-in 判定后停止 TTS 时，对「尚未播出」的队首若干帧施加一段下行增益斜坡（指数优先）到零，再丢弃其余队列，pump 继续推（背景底噪不受影响）。淡出窗口默认 ~100ms：短至 15~30ms 即去爆音，~100ms 同时复刻真人「把字说完 + 渐弱」的收声特征。一个时长旋钮同时覆盖「去 click」与「像人」两个目标，避免叠加多层机制。
- **出向 TTS 路径统一走常驻 pump 缓冲。** 现状 `ambient_active` 为 `True` 才走「队列+pump」，默认（生产多数 campaign 关 ambient）走 `audio_out` 直推 `push_audio`、无缓冲。直推路径没有任何 lookahead，物理上无法淡出已推出的音频。改为出向始终经 pump（ambient 关时背景帧为静音、`mix_frame` 原样返回 TTS），使淡出只写在一处即同时覆盖 ambient 开/关，并消除一处双路径分支（符合「多层兜底是味道」原则）。
- **新增 campaign 级可调旋钮 `barge_in_fadeout_ms`**（默认 100，0 = 保留硬切旧行为），与 `interruption_min_chars` / `wrap_up_silence_hangup_ms` 同一配置模式。
- **明确不做（OUT）**：语气词 / backchannel「嗯/哦/对」让出（中文场景反馈词频率仅英/日 1/4、电话里易撞客户话，风险高，留作以后 gated 可选点缀）；打断门控是否误切的复核（独立事）；真机回声 / AEC 验收（deferred 到真机演练 change，本地单测 + smoke 为据）。

## Capabilities

### New Capabilities
<!-- 无新增 capability：本变更修改既有打断行为。 -->

### Modified Capabilities
- `interruption-detection`: 「打断判定不可撤销」要求新增收声方式约束——判定打断后停止 TTS MUST 经一段可配置的淡出斜坡，MUST NOT 硬切到静音；并约束出向 TTS 始终经常驻 pump 缓冲以使淡出在两种 ambient 模式下一致生效。

## Impact

- **isales-engine**（主）：`realtime/rtc_telephony.py`（`_flush_playout` 改淡出、`audio_out` 去掉 ambient 分支统一走 `feed_playout`、pump 在 ambient 关时以静音背景常驻）、`realtime/ambient.py`（复用 `_clip16` 增加纯 `array('h')` 淡出 helper，无需 audioop）；新增引擎单测。
- **isales-common**：`models/campaign.py` + `schemas/campaign.py` 新增 `barge_in_fadeout_ms`；新增 alembic migration；版本号 bump，下游 pin 跟随。
- **isales-api**：campaign 读写 schema 透传新字段（多为自动跟随 common）。
- **isales-web**：campaign 编辑器「打断配置」高级区暴露 `barge_in_fadeout_ms`（可随既有面板，UI 改动最小）。
- **行为/延迟**：统一走 pump 后非 ambient 路径首帧引入既有 ~200ms 抖动缓冲（预合成句近乎瞬填、~0 增量；仅极慢 vendor 付出，正是需要平滑之时）；淡出本身给收声加 fadeout_ms（默认 100ms，仍在人类换话区间内）。两者均为 design.md 中量化的取舍。
- **不触及**：service-communication（纯引擎内部音频路径，无新信道）、ASR/inbound、断句。
