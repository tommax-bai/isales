## MODIFIED Requirements

### Requirement: pipeline_trace 表的字段约束

`pipeline_trace` 表 SHALL 按 (call_record_id, turn_id) 主键存储每轮管线详情，用于调试与优化。字段集随本 change（pipeline-stream-and-referee）从"三层管线 trace"改为"main + referee 双 LLM trace"。

#### Scenario: pipeline_trace 字段

- **WHEN** PROCESSING 完成
- **THEN** engine SHALL 写入一条 pipeline_trace 记录，含：
  - `call_record_id` (BigInt, FK), `turn_id` (Int), `ts_start` (datetime), `ts_end` (datetime)
  - `user_input` (Text): 触发本轮的 ASR final 文本
  - `main_reply_text` (Text): main LLM 流式聚合后的完整 reply 文本（或 default_reply 兜底文本）
  - `main_duration_ms` (Int): main LLM chat_stream 启动到 last token 总时长
  - `main_tokens_in` (Int), `main_tokens_out` (Int): main LLM 计费
  - `main_fallback_used` (Bool, default false): 是否走了 streaming → chat() 非流式 fallback
  - `referee_decision` (Text): referee 输出 decision（含 `"timeout" / "invalid" / "low_confidence"` 三种 fail-open 标记 + 4 个正常枚举）
  - `referee_goal_type` (Text, nullable): referee 输出 goal_type
  - `referee_confidence` (Real, nullable): referee 输出 confidence
  - `referee_duration_ms` (Int): referee LLM 调用时长
  - `first_audio_ms` (Int): 从 PROCESSING 入口到首 PCM chunk 推到 RTC 的时间差（SLA 监控核心字段）
  - `error` (Text, nullable): 任意失败原因汇总（兜底场景）

#### Scenario: pipeline_trace 不展示在主管理界面

- **WHEN** 普通用户查通话记录
- **THEN** UI MUST NOT 展示 pipeline_trace 内容；MAY 在"高级"调试视图中展示

#### Scenario: 历史 pipeline_trace 旧字段不可读

- **WHEN** 查询本 change archive 之前写入的 pipeline_trace 历史记录
- **THEN** 旧字段 `role_candidates` / `judge_results` / `polish_input` / `polish_output` / `polish_duration_ms` / `polish_role_config_id` / `polish_prompt_version_id` / `final_selected_candidate_index` MUST 已被 alembic migration 删除（v1 无真实数据，acceptable）
- **AND** UI MUST NOT 试图读取这些旧字段；调试视图 MUST 仅展示新字段集
