## MODIFIED Requirements

### Requirement: 事件类型枚举

transcript 事件类型 SHALL 限定为以下枚举：

| type | 类型特有字段 | 说明 |
|---|---|---|
| `greeting` | text, audio_duration_ms | 开场白播放 |
| `user_speech` | text, asr_confidence, duration_ms | 用户一段语音的 ASR 终态结果 |
| `ai_reply` | text, turn_id, selected_role_config_id, goal_achieved, goal_type, extracted, is_wrap_up | AI 回复（润色后）。payload MUST NOT 含 `interrupted` 字段——是否被打断由独立 `interruption` 事件 + pipeline_trace 承载，不在 ai_reply 上冗余标记 |
| `interruption` | interrupted_event_id, user_text_at_interruption | 用户打断 |
| `filler` | text, filler_phrase_id, duration_ms | 垫词播放 |
| `default_reply_used` | text, reason | 全部裁判否决，走默认回复 |
| `silence_activation` | text, activation_index | 沉默激活话术 |
| `transfer_initiated` | trigger_type, trigger_detail | 转人工触发命中 |
| `transfer_marked` | （无类型特有字段） | 衔接话术播完、已标记转人工（裸标记事件；`handoff_task_id` 字段已随 `admin-prune-vestigial-features` 删除——handoff_task 表已删，引擎从不写该 id） |
| `goal_achieved` | goal_type, extracted | 目标达成（与 ai_reply 重复时单独标记里程碑事件） |
| `wrap_up_started` | rounds_remaining, seconds_remaining | 进入收尾 |
| `wrap_up_completed` | reason (`max_rounds`/`max_seconds`) | 收尾结束 |
| `hangup` | reason, initiated_by (`user`/`ai`) | 挂断 |
| `state_warning` | attempted, from_state, to_state | 状态机非常规 transition 的 advisory 警告留痕（见 `call-state-machine` spec）；当前 engine 写此事件名 |
| `state_error` | attempted, from_state, to_state | 历史事件名（`call-state-machine-soften-guard` 之前的真 IllegalTransition 写入）；新通话不再产生，但历史 DB 行可能含此事件，消费方 MUST 能解析 |

#### Scenario: 类型扩展约束

- **WHEN** 未来需要新增事件类型
- **THEN** 修改 SHALL 视为 schema 变更，需经 OpenSpec change proposal 流程

#### Scenario: transfer_marked 为裸标记事件

- **WHEN** 衔接话术 TTS 播完、engine 落 `transfer_marked` 事件
- **THEN** 该事件 MUST 仅含通用字段 `type` 与 `ts`，MUST NOT 携带 `handoff_task_id`（该字段连同 handoff_task 表已删除）；消费方 MUST NOT 读取该已删字段

#### Scenario: ai_reply 事件不含 interrupted 字段

- **WHEN** engine 落 `ai_reply` transcript 事件（无论本轮回复是否被用户打断）
- **THEN** 该事件 payload MUST NOT 含 `interrupted` 字段；本轮是否被打断 MUST 仅由独立的 `interruption` 事件与 pipeline_trace 记录承载
- **AND** 消费方（如 `isales-api` 的 `CallRecordRead`）按 `extra="forbid"` 校验 transcript 时 MUST NOT 因 ai_reply 出现 `interrupted` 而失败——即该字段不得存在

#### Scenario: state_warning / state_error 事件可被读端解析

- **WHEN** 通话 transcript 含 `state_warning`（当前）或 `state_error`（历史）事件
- **THEN** transcript schema 消费方（`TranscriptEvent` union）MUST 能将其按 `attempted` / `from_state` / `to_state` + 通用 `ts` 字段成功校验，MUST NOT 因这两类事件而抛 validation 错误
