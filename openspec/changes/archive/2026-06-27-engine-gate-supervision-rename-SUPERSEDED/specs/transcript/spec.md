<!-- transcript: rename display 裁判/referee→门控监管 in prose; drop low_confidence from referee_results fail-open marker set (keep {timeout, invalid}); JSON keys referee_results / referee_decision[historical] kept verbatim -->

## MODIFIED Requirements

### Requirement: 三段式存储模型

通话事件流、AI 管线 trace、录音音频 SHALL 分三处存储，避免互相污染。

#### Scenario: 三处存储位置

- **WHEN** 通话结束 engine 落 DB
- **THEN** 数据 SHALL 分别落到：
  - 通话事件流 → `call_record.transcript`（JSONB array）
  - dual-LLM 管线（main LLM 流式 + N 路 门控监管 LLM（主路径门控、与 main 并行执行）） trace → 独立表 `pipeline_trace`（按 call_record_id + turn_id）
  - 整通录音音频 → OSS（`call_record.recording_url` 引用）

#### Scenario: trace 不污染 transcript

- **WHEN** 运营或坐席查 transcript
- **THEN** transcript JSONB MUST NOT 包含管线候选、门控监管细节、重组输入；这些 MUST 存在 pipeline_trace 表

### Requirement: 事件类型枚举

transcript 事件类型 SHALL 限定为以下枚举：

| type | 类型特有字段 | 说明 |
|---|---|---|
| `greeting` | text, audio_duration_ms | 开场白播放 |
| `user_speech` | text, asr_confidence, duration_ms | 用户一段语音的 ASR 终态结果 |
| `ai_reply` | text, turn_id, selected_role_config_id, goal_achieved, goal_type, extracted, is_wrap_up | AI 回复（聚合后） |
| `interruption` | interrupted_event_id, user_text_at_interruption | 用户打断 |
| `filler` | text, filler_phrase_id, duration_ms | 垫词播放 |
| `default_reply_used` | text, reason | 无任何路由规则命中（门控监管均未命中放行规则），走默认回复 |
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

### Requirement: pipeline_trace 表的字段约束

`pipeline_trace` 表 SHALL 按 (call_record_id, turn_id) 主键存储每轮管线详情，用于调试与优化。字段集随本 change（engine-multi-referee-and-restructure）从「main + 单 门控监管 双 LLM trace」改为「main + N 门控监管（`referee_results`）数组 + restructure trace」；本 change（engine-tools-multidialogue-gating）追加门控选路字段 `selected_route_id` / `selected_route_kind` / `persona_candidates`。写入 MUST 保持「不因 trace 失败影响主路径」（try/except 包裹，失败仅 ERROR 日志）。

#### Scenario: pipeline_trace 字段

- **WHEN** PROCESSING 完成
- **THEN** engine SHALL 写入一条 pipeline_trace 记录，含：
  - `call_record_id` (BigInt, FK), `turn_id` (Int), `ts_start` (datetime), `ts_end` (datetime)
  - `user_input` (Text): 触发本轮的 ASR final 文本
  - `main_reply_text` (Text): main LLM 流式聚合后的完整 reply 文本（或 default_reply 兜底文本）
  - `main_duration_ms` (Int): main LLM chat_stream 启动到 last token 总时长
  - `main_tokens_in` (Int), `main_tokens_out` (Int): main LLM 计费
  - `main_fallback_used` (Bool, default false): 是否走了 streaming → chat() 非流式 fallback
  - `referee_results` (JSONB): N 个门控监管结果数组，每元素 `{label, category, confidence, duration_ms}`；`category` 含 `"timeout" / "invalid"` 两种 fail-open 标记 + 该门控监管 prompt 定义的正常枚举（`confidence` 由引擎钉死 1.0，trace 中保留无害）
  - `matched_rule` (JSONB, nullable): 路由规则引擎本轮命中的规则（无命中为 null）
  - `selected_route_id` (Text, nullable): 本轮门控放行的 route id（如 `main` / `persona:<label>` / `closing` / `tool:hangup`）
  - `selected_route_kind` (Text, nullable): `dialogue` / `tool` 之一
  - `persona_candidates` (JSONB, nullable): 本轮 eager 推测的候选 route label 集（无推测时为 null 或单元素 `["main"]`）
  - `restructure_active` (Bool, default false): 本轮是否走了重组流
  - `restructure_trigger` (Text, nullable): `last_reply` / `interrupt_remaining` / `low_confidence` 之一
  - `restructure_source_text` (Text, nullable): 本轮 restructure 的 InterruptText
  - `first_audio_ms` (Int): 从 PROCESSING 入口到首 PCM chunk 推到 RTC 的时间差（SLA 监控核心字段）
  - `error` (Text, nullable): 任意失败原因汇总（兜底场景）

#### Scenario: 多门控监管轮的 trace 记录

- **WHEN** 一轮 PROCESSING 跑了 N 个门控监管并由规则引擎决策
- **THEN** 该轮 pipeline_trace 记录 SHALL 含长度 N 的 `referee_results` 数组 + 命中的 `matched_rule`

#### Scenario: restructure 轮的 trace 记录

- **WHEN** 本轮命中 restructure action 并播出重组语句
- **THEN** 记录 SHALL 置 `restructure_active=true`、`restructure_trigger ∈ {last_reply, interrupt_remaining, low_confidence}`、`restructure_source_text` 为本轮 InterruptText；MUST NOT 写门控监管结果（restructure 轮不过门控监管）

#### Scenario: restructure 输出对 ai_reply 事件透明

- **WHEN** restructure stream 播出后聚合文本
- **THEN** ai_reply 事件 payload 结构 MUST NOT 改变（`text` 字段照常承载本轮播出的聚合文本），对 transcript 消费方透明

#### Scenario: pipeline_trace 不展示在主管理界面

- **WHEN** 普通用户查通话记录
- **THEN** UI MUST NOT 展示 pipeline_trace 内容；MAY 在「高级」调试视图中展示

#### Scenario: 历史 pipeline_trace 旧字段不可读

- **WHEN** 查询本 change archive 之前写入的 pipeline_trace 历史记录
- **THEN** 旧单门控监管字段 `referee_decision` / `referee_goal_type` / `referee_confidence` / `referee_duration_ms` MUST 已被本 change 的 alembic migration 删除（v1 无真实数据，acceptable）
- **AND** UI MUST NOT 试图读取这些旧字段；调试视图 MUST 仅展示新字段集（含 `referee_results` 数组 + restructure 字段 + 门控选路字段）
