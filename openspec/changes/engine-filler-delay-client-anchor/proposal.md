## Why

垫词（filler）的 `filler_delay_ms`（默认 600ms）本意是"客户说完话后等了这么久还没听到 AI 任何声音，就插一句垫词遮空档"。`filler/spec.md` 与 `data-model/spec.md` 都明确把锚点写成"**进入 PROCESSING 后**多久首音频仍未出就播垫词"。但当前引擎代码把计时器起点放在 `_play_streaming` 进入那一刻（`run_loop.py:937`），而 gate-first 重构（多裁判门控）已经把**门控/referee 投票**插到了 `_play_streaming` **之前**——于是 ASR finalize + 门控这段静默被排除在延迟预算之外，配置的秒数 ≠ 客户感知的等待时长。运营反馈"客户侧还没达到设定延迟，垫词就已经播了"，根因正是这处 **spec-code 漂移**（实现锚点随门控前移而静默偏离了规范）。

## What Changes

- 把垫词时间门控的计时锚点从"`_play_streaming` 进入时刻"改回规范所述的 **PROCESSING 进入时刻**（`processing_start`，≈ 客户说完话/speech_end）。`processing_start` 已作为参数传入 `_play_streaming`，改动落在 `_maybe_filler` 内：用 `filler_delay_s - (now - processing_start)` 计算剩余等待，而非裸 `sleep(filler_delay_s)`。
- **门控/referee 等待期间计入 `filler_delay_ms` 预算**：若进入 `_play_streaming` 时已超预算（剩余 ≤ 0 且首音频未出），engine SHALL 立即播垫词，不再额外等满一个 `filler_delay_ms`。
- 收紧 `filler` 能力规范，把锚点显式钉死为"PROCESSING 进入时刻"并写明"门控等待计入该延迟预算"，消除导致本次漂移的措辞歧义（旧实现把"`_maybe_filler` 任务创建时刻"当作"PROCESSING 进入"的代理，在门控前移后失效）。
- 非破坏性：不改 schema（`campaign.filler_delay_ms` 字段不动）、不改 web、不改 API、无 alembic。语义只对 `filler_enabled=true` 的 campaign 生效，且只影响垫词触发时机。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `filler`: 「filler（垫词）时间门控播放」需求——把计时锚点显式钉为 PROCESSING 进入时刻（`processing_start` ≈ 客户说完话），并明确门控/referee 等待期间计入 `filler_delay_ms` 预算；新增"门控耗时已超预算则进入播音即刻插垫词"场景。

## Impact

- `isales-engine`：`isales_engine/run_loop.py` `_play_streaming._maybe_filler`（计时锚点）；不动 `runtime_config.py`（`filler_delay_ms` 透传链路不变）。
- 测试：`isales-engine` 垫词门控相关单测需新增/调整——覆盖"门控耗时 < 预算正常等剩余"、"门控耗时 ≥ 预算即刻播"、"快轮次首音频先出则取消"三条路径。
- 行为变化：`filler_enabled=true` 的 campaign，垫词会更贴近客户感知的等待时刻触发（门控慢时更早、快轮次仍不播）；`data-model/spec.md` 既有措辞已与新行为一致，无需改动。
- 不涉及：schema / alembic / web / api / scheduler / worker / telephony。
