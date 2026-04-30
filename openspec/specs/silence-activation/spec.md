## Purpose

用户长时间不说话时 AI 主动激活，避免冷场或线路异常导致的"哑通话"。本规范定义沉默检测、激活上限、话术选择、超限挂断、与角色 LLM 上下文的隔离规则。

## Requirements

### Requirement: 沉默检测与激活触发

engine SHALL 持续监测 LISTENING 状态下的沉默时长，并在超过阈值时触发激活流程。计时起点 MUST 取「max(用户最后一次 speech_end, AI 上一轮 TTS 播完时刻)」。

#### Scenario: 沉默时长超过阈值且未达激活上限

- **WHEN** LISTENING 状态计时超过 `campaign.silence_threshold_ms`（默认 5000）且当前已激活次数 < `campaign.max_silence_activations`（默认 2）
- **THEN** engine 进入 ACTIVATING 状态，从 `campaign.silence_phrases` 顺序选第 i 条话术（i = 已激活次数）播放

#### Scenario: 沉默时长超过阈值且已达激活上限

- **WHEN** 计时超过阈值且已激活次数 ≥ `max_silence_activations`
- **THEN** engine 播放 `campaign.silence_hangup_phrase` 后主动挂断，进入 END (reason=`silence_max_reached`)

#### Scenario: 用户在阈值期间说话

- **WHEN** 沉默计时未达阈值前 ASR 检测到 speech_start 且后续被判定为有效输入
- **THEN** 沉默计时器复位，状态走正常 LISTENING → PROCESSING 路径

### Requirement: 激活后重新计时

每次激活 TTS 播完后 engine SHALL 以 TTS 播完时刻作为新的计时起点，**MUST NOT 累加**用户原始沉默时长。

#### Scenario: 第二次激活的计时起点

- **WHEN** 第 1 次激活 TTS 播完
- **THEN** 沉默计时器从 0 重新开始，不计入第 1 次激活前用户已沉默的时间

### Requirement: 话术顺序使用与超限复用

engine SHALL 按 `campaign.silence_phrases` 数组下标顺序使用激活话术；当话术数量与激活上限不一致时 MUST 按以下规则处理。

#### Scenario: 话术数等于激活上限

- **WHEN** `silence_phrases.length == max_silence_activations`
- **THEN** 第 i 次激活使用 `silence_phrases[i-1]`，一一对应

#### Scenario: 话术数小于激活上限

- **WHEN** `silence_phrases.length < max_silence_activations`
- **THEN** 用完所有话术后 engine MUST 复用最后一条直至达到激活上限

#### Scenario: 话术数大于激活上限

- **WHEN** `silence_phrases.length > max_silence_activations`
- **THEN** engine 仅使用前 `max_silence_activations` 条；剩余话术不会被触发

### Requirement: 激活话术与角色 LLM 上下文隔离

激活话术 SHALL 写入 `full_transcript`（call_record.transcript 字段），但 MUST NOT 进入下一轮角色 LLM 的对话历史（`dialog_history`）。

#### Scenario: transcript 记录激活事件

- **WHEN** ACTIVATING 期间 TTS 播完
- **THEN** full_transcript 追加 `{type: "silence_activation", text: ..., activation_index: ...}` 事件

#### Scenario: 角色 LLM 上下文不含激活话术

- **WHEN** 沉默激活后用户终于说话，engine 进入 PROCESSING 调角色 LLM
- **THEN** 拼接给角色 LLM 的对话历史中 MUST NOT 包含 silence_activation 文本（避免模型误以为"AI 上一轮说过这句话需要承接"）

### Requirement: 与其他模块的优先级

沉默激活机制 SHALL 与转人工、超时挂断等机制按明确优先级共存；任一种转人工触发命中时 engine MUST 优先进入 TRANSFERRING。

#### Scenario: 转人工触发优先于沉默激活

- **WHEN** 同时达到沉默阈值且触发转人工条件
- **THEN** engine SHALL 优先进入 TRANSFERRING，不执行激活

#### Scenario: 沉默激活与超时挂断的边界

- **WHEN** 用户一直说但都被判定为"非打断/无效内容"
- **THEN** engine 不走沉默激活，由独立的 `max_no_progress_seconds` 机制处理（详见关键业务规则 #13）

## Configuration

`campaign` 表新增字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `silence_threshold_ms` | int | 5000 | 沉默触发阈值 |
| `max_silence_activations` | int | 2 | 单通电话激活上限 |
| `silence_phrases` | JSONB array | `["请问您还在吗？","您好，请问能听到吗？"]` | 激活话术库，顺序使用 |
| `silence_hangup_phrase` | text | `"那今天就先这样，稍后联系，再见。"` | 上限达到后的告别话术 |

## Implementation Notes

engine 在 call_session 内 SHALL 维护两个集合：

- `dialog_history` — 喂给角色 LLM（不含 silence_activation / silence_hangup_phrase）
- `full_transcript` — 写 DB（含全部事件）
