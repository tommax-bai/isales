## Context

barge-in 链路：`run_loop.py:_partial_monitor` 判定打断后 `speaking_task.cancel()` → `rtc_telephony.py:feed_playout` 捕获 `CancelledError` → `_flush_playout()` 同步把整条 `playout_q` 清空（`q.get_nowait()` 循环），pump (`_outbound_loop`) 下一帧拿不到 TTS 即推 `SILENCE_FRAME`。结果：人声在一个 10ms 帧边界内从满幅阶跃到零，无斜坡 → 爆音 click + 不像人。

出向当前有两条路径，由 `_CallState.ambient_active` 决定（init 时为 `False`，仅 `enable_ambient()`/`configure_ambient()` 在 campaign 配了 `ambient_audio` 时翻 `True`）：
- **ambient 开**：`audio_out` → `feed_playout` → `playout_q`（含 ~200ms `PLAYOUT_PREBUFFER_FRAMES` 抖动缓冲）→ 常驻 `_outbound_loop` pump 按 10ms 墙钟绝对调度 `mix_frame(tts, bg, gain)` 后 `push_audio`。
- **ambient 关（生产多数）**：`audio_out` 直接 `async for chunk: push_audio(chunk)`，**无队列、无 lookahead**。

关键约束：要淡出必须作用在「尚未推给 RTC 的音频」上——已 `push_audio` 的帧无法收回。直推路径没有任何缓冲，物理上没有可淡出的音频。现成基础设施：`ambient.py` 的纯 `array('h')` 整数运算 + `_clip16()` + `_linear_crossfade()` 模式，无需 audioop（dev venv Py3.14 已无 audioop）。帧格式固定 16kHz/mono/int16/10ms=320B。

## Goals / Non-Goals

**Goals:**
- 打断收声从硬切改为可配置淡出斜坡，同时根除爆音 click 与「比人快、无收尾」两种不自然。
- 淡出只实现一处、对 ambient 开/关两种模式一致生效。
- 提供 campaign 级 `barge_in_fadeout_ms` 旋钮；`0` 完整保留旧硬切行为（安全回退 + A/B 对照）。
- 背景底噪在淡出期间不受影响（人声渐隐、room tone 仍在，更自然）。

**Non-Goals:**
- 语气词 / backchannel 让出（中文风险高，deferred）。
- 音素 / 音节边界检测（不做真正的「finish-the-syllable」；用「继续播一小段再渐弱」近似，见 Decisions）。
- 打断门控误切复核、真机回声/AEC 验收（各自独立）。
- 改 TTS 合成或 `engine-tts-bidi-streaming`（互不依赖；见 Risks 的冲突说明）。

## Decisions

### D1：淡出作用在队首「将播」帧，而非队尾
pump 从队首 FIFO 取帧（`q.get_nowait()`），队首即「下一个被客户听到」的音频。`_flush_playout` 新行为：取队首 `N = ceil(fadeout_ms/10)` 帧，逐帧施加**下行增益斜坡**（帧 i 整体增益按指数 `g_i = base^((i+1)/N)`，末帧≈0；线性亦可接受），把这 N 帧重新入队，丢弃其余；pump 在随后 N×10ms 内播完渐弱音后落入静音。
- 备选（被否）：只淡最后一帧——research 子代理初稿如此，但队尾不是「将播」音频，淡错了位置，且单帧 10ms 不足以去 click。
- 备选（被否）：在 RTC SDK 内淡——帧已推出，不可控。

### D2：一个 `fadeout_ms` 旋钮同时覆盖「去 click」与「像人」
不引入两个机制（declick 微淡 + finish-chunk 续播）。单一指数斜坡：窗口 15~30ms 时听感等同「立即停 + 无爆音」；窗口 ~100ms 时指数渐弱本身就是真人 trailing-off 的声学特征。默认 **100ms**（仍在人类 ~200ms 换话区间内）。这避免叠层（符合「多层兜底是味道」）。
- 「finish-the-syllable」用「继续以渐弱增益播 N 帧」近似，不做音素检测——工程上简单、无新依赖，且 100ms 指数尾音在听感上已覆盖「把字收完」。

### D3：出向 TTS 路径统一走常驻 pump
去掉 `audio_out` 里的 `ambient_active` 分支，恒走 `feed_playout` + pump。ambient 关时 `ambient_reader = None`、`gain = 0`，`mix_frame(tts, None/empty, 0)` 已定义为原样返回 `tts`（见 `ambient.py:mix_frame` 守卫）→ 行为等价于「只推 TTS」，但现在有了队列缓冲可供淡出。pump 本就常驻（`enable_ambient` 之外需保证 init 即起 pump + 建队列）。
- 收益：淡出逻辑只写在 `_flush_playout` 一处即覆盖两模式；消除一处长期双路径分支。
- 代价：见 Risks R1（首帧抖动缓冲延迟）。

### D4：配置走 campaign 列，对齐既有先例
`campaign.barge_in_fadeout_ms`（`Integer`, 非空, 默认 100, `ge=0`），与 `interruption_min_chars`(default 2) / `wrap_up_silence_hangup_ms`(default 6000) 同模式：model + schema(Read/Create/Update) + alembic + api 透传 + web 高级区。引擎从 runtime campaign 配置读取，无配置时回落引擎默认常量。
- 备选（被否）：纯引擎常量/env——与项目既有「可调项即 campaign 列」先例不一致，且运营无法分 campaign 调；保留引擎常量仅作 campaign 值缺失时的兜底默认。

### D5：`0` = 关闭淡出 = 旧硬切
`barge_in_fadeout_ms == 0` 时 `_flush_playout` 走原 path（清空全队列、不淡）。给安全回退与上线初期 A/B 对照，且语义直观。该兜底带明确移除条件：淡出在真机验收稳定后此分支可保留为「显式关闭」语义（非临时兜底，故不违反单层原则）。

## Risks / Trade-offs

- **R1 统一 pump 给非 ambient 路径引入 ~200ms 首帧抖动缓冲** → 预合成句（sentences≥2，常见）缓冲近乎瞬填、~0 增量；仅 vendor 真慢时付出，而那正是需要平滑之时。若真机测得开场白/首句首帧延迟回归，调小 `PLAYOUT_PREBUFFER_FRAMES`（与 `engine-greeting-window-prewarm` 的首句关切对齐复核）。
- **R2 淡出给收声加 fadeout_ms（默认 100ms）的「仍在说话」窗口** → 客户已开口、AI 多说 100ms 渐弱音 → 轻微重叠，但正是真人被打断时的自然 overlap（modal overlap ~100ms）。`0` 可回退。
- **R3 改的是 `engine-ambient-background-mix`（active 24/28 未 archive）落地的 pump 代码** → 该代码已在 main HEAD，本变更直接叠加；需在同 session 部署时与其 §7 deploy 协调，避免 run_loop.py/rtc_telephony.py 部署撞车（参照 wrap-up/greeting 并行撞车教训）。
- **R4 与 `engine-tts-bidi-streaming`（0/27 未起）未来重写 TTS 流式可能冲突** → 该 change 未开工；本 change 只动出向播放/截断，不动合成，冲突面小；若 bidi 先落地，淡出锚点 `_flush_playout` 仍适用。
- **R5 指数斜坡整数运算精度** → int16 + `_clip16`，斜坡按整帧增益缩放（复用 `mix_frame` 风格的 per-sample 乘加），单测覆盖端点（首帧≈满幅、末帧≈0、N=0 不变）。
