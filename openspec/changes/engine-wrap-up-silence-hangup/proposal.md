## Why

生产通话 call 215 暴露：AI 在收尾阶段说完告别语（「…再见。」）后，客户随即沉默，引擎**没有挂断**——phase-blind 的静音循环照常播放「你好，还在么？」重新激活，最终硬等到客户自己挂机（~19s 后）才结束。

根因：收尾期的终止判定**只靠计数器**（`evaluate_wrap_up` 只看 `max_rounds`/`max_seconds`），而静音机制（`_await_user_or_silence` + `evaluate_silence`）**与阶段无关**，于是收尾期跑的是和通话中段一样的「先激活、再挂断」阶梯。多智能体（grounding + 设计 + 对抗评审）已验证：「收尾裁判」思路**修不了 call 215**——客户告别后从未再开口，`_gated_wrap_up_turn` 根本没被调用，承重墙是静音挂断这条路。

## What Changes

- 收尾期（`session.in_wrap_up=True`）新增**客户静默主动挂断**：客户沉默超过 `campaign.wrap_up_silence_hangup_ms` 即直接挂断，**跳过** `silence_activation` 重新激活阶梯（「你好，还在么？」）。这是面向**所有 campaign** 的全局行为变更（收尾期还做重新激活本身就是 bug），不设 per-campaign 开关。
- 新增 campaign 配置列 `wrap_up_silence_hangup_ms`（默认 ~6000ms，比通话中段的 `silence_threshold_ms` 默认 3000ms 更长，给客户告别后留思考时间）。
- 收尾期静音挂断**复用现有静音机制**（按 `session.in_wrap_up` 分支），**不**新建第二条静音线——避免重蹈 silence-drop-no-progress-timeout（common 0.8.6）删掉的重复。
- `wrap_up_max_rounds` / `wrap_up_max_seconds` 计数器**原样保留**为兜底；新挂断原因**不**经 `evaluate_wrap_up` / `WrapUpDecision.reason`（其为封闭 `Literal["max_rounds","max_seconds"]`），改发 `HangupEvent(reason="wrap_up_silence", initiated_by="ai")`（free-form），复用 `HangupCause.SILENCE_MAX_REACHED`。
- **修计时 bug（强制项）**：`_await_user_or_silence` 的 `asyncio.wait` 超时当前硬编码 `silence_threshold_ms`；收尾期阈值更长（6s > 3s）时窗口会在 3s 就醒、永远累加不到 6s → 挂断**永不触发**。收尾期 wait 超时 MUST 改用 `wrap_up_silence_hangup_ms`。

非目标（明确推迟到后续 change `engine-wrap-up-bypass-referee` / Slice 2）：收尾期专用旁路（非门控、并行）裁判判「无心问题 / 同意挂断」→ `tool:hangup`。该 change 需改 `_gated_wrap_up_turn` 并放宽 ai-pipeline「简化管线（WRAPPING_UP）」要求，用专用收尾裁判（**无需** `{{is_wrap_up}}` 占位符，阶段隐含）。

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `goal-achievement`: 「收尾期间的特殊情况处理」requirement 新增「客户静默 → 主动挂断」场景（区别于计数器耗尽的终止）；「收尾双计数器与主动挂断」requirement 明确计数器为兜底、静默挂断为新增主动终止路径；Data Schema 表新增 `campaign.wrap_up_silence_hangup_ms`。

## Impact

- **isales-common**：`models/campaign.py` 新增 `wrap_up_silence_hangup_ms` 列；`schemas/campaign.py`（CampaignBase + CampaignUpdate）；alembic ADD COLUMN（`down_revision='a2c4e6b8d0f2'`，commit 前重跑 `alembic heads` 防撞）；版本 0.8.20→0.8.21 + CHANGELOG。消费方 pin（api>=0.8.14 / engine>=0.8.16，均 <0.9）已容纳，但 engine/api venv 需重装 isales-common。
- **isales-engine**：`SilenceConfig`（`realtime/silence_detector.py`）加 `wrap_up_hangup_ms`；`evaluate_silence` 加 `in_wrap_up` 参数；`run_loop.py` 静音 await 超时与 `evaluate_silence` 调用点接入 `session.in_wrap_up`；`silence_hangup` handler 分支发 `wrap_up_silence` 事件；`runtime_config.py` 装配新字段。
- **isales-web**：`views/Campaigns/Tabs/WrapUpTab.vue` 加一个数字输入控件；`types/campaign.ts` 加字段。
- **specs**：`goal-achievement` MODIFIED delta。transcript / ai-pipeline 不动（reason 为 free-form；Slice 1 无裁判）。
- **行为变更**：所有 campaign 收尾期不再播「你好，还在么？」，静默 `wrap_up_silence_hangup_ms` 后直接挂断。
