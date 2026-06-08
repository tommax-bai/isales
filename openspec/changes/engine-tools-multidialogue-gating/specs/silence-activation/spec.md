## MODIFIED Requirements

### Requirement: 沉默检测与激活触发

engine SHALL 持续监测 LISTENING 状态下的沉默时长，并在超过阈值时触发激活流程。计时起点 MUST 取「max(用户最后一次 speech_end, AI 上一轮 TTS 播完时刻)」。沉默超限挂断时，若 `campaign.silence_hangup_phrase` **为空（空串或未配置）engine MUST 直接挂断、MUST NOT 播任何兜底话术**（移除既有 `"再见。"` 兜底）；非空时先播该话术再挂。

#### Scenario: 沉默时长超过阈值且未达激活上限

- **WHEN** LISTENING 状态计时超过 `campaign.silence_threshold_ms`（默认 5000）且当前已激活次数 < `campaign.max_silence_activations`（默认 2）
- **THEN** engine 进入 ACTIVATING 阶段，从 `campaign.silence_phrases` 顺序选第 i 条话术（i = 已激活次数）播放

#### Scenario: 沉默超限挂断（结束语非空）

- **WHEN** 计时超过阈值且已激活次数 ≥ `max_silence_activations` 且 `campaign.silence_hangup_phrase` 非空
- **THEN** engine 播放 `silence_hangup_phrase` 后主动挂断，进入 END (reason=`silence_max_reached`)

#### Scenario: 沉默超限挂断且结束语为空则直接挂断

- **WHEN** 计时超过阈值且已激活次数 ≥ `max_silence_activations` 且 `campaign.silence_hangup_phrase` 为空串或未配置
- **THEN** engine MUST 直接挂断、进入 END (reason=`silence_max_reached`)，MUST NOT 播任何话术（不再兜底播 `"再见。"`）

#### Scenario: 用户在阈值期间说话

- **WHEN** 沉默计时未达阈值前 ASR 检测到 speech_start 且后续被判定为有效输入
- **THEN** 沉默计时器复位，状态走正常 LISTENING → PROCESSING 路径
