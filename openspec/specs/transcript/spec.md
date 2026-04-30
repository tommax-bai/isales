## Purpose

定义通话事件流（transcript）的数据格式：存储模型、事件类型枚举、dialog_history 与 full_transcript 的关系、AI 管线 trace 的独立存储、录音关联。本规范是各个实时行为模块的"输出统一口径"。

## Requirements

### Requirement: 三段式存储模型

通话事件流、AI 管线 trace、录音音频 SHALL 分三处存储，避免互相污染。

#### Scenario: 三处存储位置

- **WHEN** 通话结束 engine 落 DB
- **THEN** 数据 SHALL 分别落到：
  - 通话事件流 → `call_record.transcript`（JSONB array）
  - AI 三层管线候选 / 裁判 / 润色 trace → 独立表 `pipeline_trace`（按 call_record_id + turn_id）
  - 整通录音音频 → OSS（`call_record.recording_url` 引用）

#### Scenario: trace 不污染 transcript

- **WHEN** 运营或坐席查 transcript
- **THEN** transcript JSONB MUST NOT 包含管线候选、裁判细节、润色输入；这些 MUST 存在 pipeline_trace 表

### Requirement: 通用事件结构

每个 transcript 事件 SHALL 包含共同字段 `type` (string) 和 `ts` (number, 相对通话开始的毫秒数)，以及类型特有字段。

#### Scenario: 共同字段

- **WHEN** 落入 transcript 的任何事件
- **THEN** MUST 包含 `type` 与 `ts` 字段

### Requirement: 事件类型枚举

transcript 事件类型 SHALL 限定为以下枚举：

| type | 类型特有字段 | 说明 |
|---|---|---|
| `greeting` | text, audio_duration_ms | 开场白播放 |
| `user_speech` | text, asr_confidence, duration_ms | 用户一段语音的 ASR 终态结果 |
| `ai_reply` | text, turn_id, selected_role_config_id, goal_achieved, goal_type, extracted, is_wrap_up | AI 回复（润色后） |
| `interruption` | interrupted_event_id, user_text_at_interruption | 用户打断 |
| `filler` | text, filler_phrase_id, duration_ms | 垫词播放 |
| `default_reply_used` | text, reason | 全部裁判否决，走默认回复 |
| `silence_activation` | text, activation_index | 沉默激活话术 |
| `transfer_initiated` | trigger_type, trigger_detail | 转人工触发命中 |
| `transfer_marked` | handoff_task_id | 衔接话术播完、handoff_task 已派发 |
| `goal_achieved` | goal_type, extracted | 目标达成（与 ai_reply 重复时单独标记里程碑事件） |
| `wrap_up_started` | rounds_remaining, seconds_remaining | 进入收尾 |
| `wrap_up_completed` | reason (`max_rounds`/`max_seconds`) | 收尾结束 |
| `hangup` | reason, initiated_by (`user`/`ai`) | 挂断 |

#### Scenario: 类型扩展约束

- **WHEN** 未来需要新增事件类型
- **THEN** 修改 SHALL 视为 schema 变更，需经 OpenSpec change proposal 流程

### Requirement: dialog_history 与 full_transcript 双集合

engine 在 call_session 内 SHALL 维护两个集合：`dialog_history`（喂角色 LLM）与 `full_transcript`（写 DB）。系统话术 MUST NOT 进入 dialog_history。

#### Scenario: dialog_history 包含的事件

- **WHEN** 拼接 user message 中的【对话】段
- **THEN** dialog_history MUST 仅包含：`greeting`, `user_speech`, `ai_reply`（含 wrap_up 期间，因为收尾对话也是对话本身）

#### Scenario: full_transcript 包含全部事件

- **WHEN** 通话结束写 call_record.transcript
- **THEN** full_transcript MUST 包含所有事件，含状态变化与系统话术（silence_activation / filler / transfer_marked / wrap_up_started 等）

#### Scenario: 系统话术不入 dialog_history

- **WHEN** silence_activation 或 silence_hangup_phrase 或转人工衔接话术 TTS 播放
- **THEN** 这些 MUST 仅追加到 full_transcript，MUST NOT 追加到 dialog_history

### Requirement: pipeline_trace 表的字段约束

`pipeline_trace` 表 SHALL 按 call_record_id + turn_id 主键存储每轮管线详情，用于调试与优化。

#### Scenario: pipeline_trace 字段

- **WHEN** PROCESSING 完成
- **THEN** engine SHALL 写入一条 pipeline_trace 记录，含：
  - call_record_id, turn_id, ts_start, ts_end
  - user_input (text)
  - role_candidates (JSONB array): 每个候选的 `{role_config_id, prompt_version_id, raw_output, parsed_json, duration_ms, prompt_tokens, completion_tokens, error}`
  - judge_results (JSONB array): 每个候选 × 每个裁判的 `{candidate_index, role_config_id, prompt_version_id, passed, reason, duration_ms}`
  - polish_input (JSONB), polish_output (text), polish_duration_ms, polish_role_config_id, polish_prompt_version_id
  - final_selected_candidate_index

#### Scenario: pipeline_trace 不展示在主管理界面

- **WHEN** 普通用户查通话记录
- **THEN** UI MUST NOT 展示 pipeline_trace 内容；MAY 在"高级"调试视图中展示

### Requirement: 录音存储

录音 SHALL 由 modem-controller 在通话建立后启动 PCM 录音，整通录成单个 wav 文件；挂断后 worker 异步上传 OSS。

#### Scenario: 录音存储路径

- **WHEN** 录音上传成功
- **THEN** OSS 路径 SHALL 形如 `isales/recordings/{YYYY-MM-DD}/{call_record_id}.wav`；`call_record.recording_url` 存完整路径或带签名 URL

#### Scenario: 用 ts 字段定位录音

- **WHEN** 前端播放录音
- **THEN** transcript 事件的 `ts` 字段（相对通话开始的毫秒偏移）MUST 可被前端播放器用于跳转到任意时刻

### Requirement: PII 脱敏 v1 不做

电话号码、姓名、地址等敏感信息 v1 MUST 直接明文存 transcript / pipeline_trace。脱敏 / 加密 / 留存策略 MUST 列入 v1 范围外。

#### Scenario: 敏感字段存储现状

- **WHEN** 通话结束写 transcript
- **THEN** 敏感字段直接明文写入；仅靠数据库访问控制保护

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `call_record.transcript` (JSONB array) | 通话事件流 |
| `call_record.recording_url` (text) | OSS 录音路径 |
| `pipeline_trace` 表 | AI 管线 trace |
