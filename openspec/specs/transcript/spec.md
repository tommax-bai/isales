## Purpose

定义通话事件流（transcript）的数据格式：存储模型、事件类型枚举、dialog_history 与 full_transcript 的关系、AI 管线 trace 的独立存储、录音关联。本规范是各个实时行为模块的"输出统一口径"。
## Requirements
### Requirement: 三段式存储模型

通话事件流、AI 管线 trace、录音音频 SHALL 分三处存储，避免互相污染。

#### Scenario: 三处存储位置

- **WHEN** 通话结束 engine 落 DB
- **THEN** 数据 SHALL 分别落到：
  - 通话事件流 → `call_record.transcript`（JSONB array）
  - dual-LLM 管线（main LLM 流式 + N 路 referee 并行）trace → 独立表 `pipeline_trace`（按 call_record_id + turn_id）
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

`pipeline_trace` 表 SHALL 按 (call_record_id, turn_id) 主键存储每轮管线详情，用于调试与优化。字段集随本 change（engine-multi-referee-and-restructure）从「main + 单 referee 双 LLM trace」改为「main + N referee 数组 + restructure trace」；本 change（engine-tools-multidialogue-gating）追加门控选路字段 `selected_route_id` / `selected_route_kind` / `persona_candidates`。写入 MUST 保持「不因 trace 失败影响主路径」（try/except 包裹，失败仅 ERROR 日志）。

#### Scenario: pipeline_trace 字段

- **WHEN** PROCESSING 完成
- **THEN** engine SHALL 写入一条 pipeline_trace 记录，含：
  - `call_record_id` (BigInt, FK), `turn_id` (Int), `ts_start` (datetime), `ts_end` (datetime)
  - `user_input` (Text): 触发本轮的 ASR final 文本
  - `main_reply_text` (Text): main LLM 流式聚合后的完整 reply 文本（或 default_reply 兜底文本）
  - `main_duration_ms` (Int): main LLM chat_stream 启动到 last token 总时长
  - `main_tokens_in` (Int), `main_tokens_out` (Int): main LLM 计费
  - `main_fallback_used` (Bool, default false): 是否走了 streaming → chat() 非流式 fallback
  - `referee_results` (JSONB): N 个 referee 结果数组，每元素 `{label, category, confidence, duration_ms}`；`category` 含 `"timeout" / "invalid" / "low_confidence"` 三种 fail-open 标记 + 该 referee prompt 定义的正常枚举
  - `matched_rule` (JSONB, nullable): 路由规则引擎本轮命中的规则（无命中为 null）
  - `selected_route_id` (Text, nullable): 本轮门控放行的 route id（如 `main` / `persona:<label>` / `closing` / `tool:hangup`）
  - `selected_route_kind` (Text, nullable): `dialogue` / `tool` 之一
  - `persona_candidates` (JSONB, nullable): 本轮 eager 推测的候选 route label 集（无推测时为 null 或单元素 `["main"]`）
  - `restructure_active` (Bool, default false): 本轮是否走了重组流
  - `restructure_trigger` (Text, nullable): `last_reply` / `interrupt_remaining` / `low_confidence` 之一
  - `restructure_source_text` (Text, nullable): 本轮 restructure 的 InterruptText
  - `first_audio_ms` (Int): 从 PROCESSING 入口到首 PCM chunk 推到 RTC 的时间差（SLA 监控核心字段）
  - `error` (Text, nullable): 任意失败原因汇总（兜底场景）

#### Scenario: 多 referee 轮的 trace 记录

- **WHEN** 一轮 PROCESSING 跑了 N 个 referee 并由规则引擎决策
- **THEN** 该轮 pipeline_trace 记录 SHALL 含长度 N 的 `referee_results` 数组 + 命中的 `matched_rule`

#### Scenario: restructure 轮的 trace 记录

- **WHEN** 本轮命中 restructure action 并播出重组语句
- **THEN** 记录 SHALL 置 `restructure_active=true`、`restructure_trigger ∈ {last_reply, interrupt_remaining, low_confidence}`、`restructure_source_text` 为本轮 InterruptText；MUST NOT 写 referee 结果（restructure 轮不过 referee）

#### Scenario: restructure 输出对 ai_reply 事件透明

- **WHEN** restructure stream 播出后聚合文本
- **THEN** ai_reply 事件 payload 结构 MUST NOT 改变（`text` 字段照常承载本轮播出的聚合文本），对 transcript 消费方透明

#### Scenario: pipeline_trace 不展示在主管理界面

- **WHEN** 普通用户查通话记录
- **THEN** UI MUST NOT 展示 pipeline_trace 内容；MAY 在「高级」调试视图中展示

#### Scenario: 历史 pipeline_trace 旧字段不可读

- **WHEN** 查询本 change archive 之前写入的 pipeline_trace 历史记录
- **THEN** 旧单 referee 字段 `referee_decision` / `referee_goal_type` / `referee_confidence` / `referee_duration_ms` MUST 已被本 change 的 alembic migration 删除（v1 无真实数据，acceptable）
- **AND** UI MUST NOT 试图读取这些旧字段；调试视图 MUST 仅展示新字段集（含 `referee_results` 数组 + restructure 字段 + 门控选路字段）

### Requirement: 录音存储

录音 SHALL 由 edge 在通话建立后启动 PCM 录音，整通录成单个 stereo wav 文件（左声道=用户上行、右声道=AI 下行），落 edge 本地磁盘。录音的两条接线路径行为对等：modem 路径经 `AudioBridge` 在上行/下行 loop tap PCM；dev-no-modem 路径经 orchestrator 直采（用户上行=mac mic 推流帧，AI 下行=SDK 播放观察帧）。录音 SHALL 纯本地保留最近 N 个（默认 N=10，按文件个数滚动删除最旧），不上传 OSS、不回写数据库、admin 后台不可见。

OSS 上传、`call_record.recording_url` 回写、前端用 transcript `ts` 字段跳转回放 MUST 列入 v1.x 范围外；`call_record.recording_url` 字段保留为 v1.x 预留，v1.0 不写入。

#### Scenario: 录音落盘路径

- **WHEN** 一通通话结束（挂断）
- **THEN** edge SHALL 在 `RECORDINGS_DIR` 下写入单个 stereo 16 kHz wav 文件，文件名以 `call_id` 标识
- **AND** 文件 MUST NOT 上传 OSS，`call_record.recording_url` MUST 保持为空

#### Scenario: 按个数滚动保留

- **WHEN** 录音文件写入完成后
- **THEN** edge SHALL 按文件 mtime 仅保留最近 `MAX_RECORDINGS`（默认 10）个 wav，删除更旧的文件
- **AND** 当 `MAX_RECORDINGS` 设为 0 时 MUST 完全禁用录音（不创建文件）

#### Scenario: 磁盘下限兜底

- **WHEN** 通话建立时录音目录可用空间低于配置下限
- **THEN** edge SHALL 跳过本通话录音并记结构化 warning（含可用空间与阈值）
- **AND** 通话本身 MUST NOT 受影响

#### Scenario: dev-no-modem 路径录音对等

- **WHEN** 在 `--dev-no-modem`（mac dev/QA）路径上建立一通通话且 `RECORDINGS_DIR` 已配置
- **THEN** edge SHALL 把 mac mic 推流帧（16 kHz mono）写入左声道，把 SDK 播放观察帧（48 kHz stereo）降采为 16 kHz mono 后写入右声道
- **AND** 挂断时写出的 wav MUST 与 modem 路径同格式（stereo 16 kHz、文件名 `call_id`、本地滚动保留、不上传 OSS）
- **AND** 当 mic 采集被显式跳过时，左声道 MUST 以静音补齐而录音 MUST NOT 失败
</content>

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
