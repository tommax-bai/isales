## MODIFIED Requirements

### Requirement: 三层并行管线编排

每一轮对话生成回复 SHALL 顺序经过三层 LLM：Layer 1 角色 LLM 并行产候选 → Layer 2 裁判 LLM 并行审查 → Layer 3 润色 LLM 选优。**Layer 1 与垫词播放 MUST 同时启动**，覆盖整个管线延迟。

每一轮 PROCESSING 完成（无论走完整管线 / 默认回复兜底 / 润色降级 / 简化管线）MUST 落一条 `pipeline_trace` 记录到 DB（按 transcript spec § pipeline_trace 字段约束），含全部候选 / 裁判 / 润色字段；若 PROCESSING 中途异常（如 LLM Provider 全部超时）MUST 仍写一条 `pipeline_trace`，标注 `error` 字段且 `final_selected_candidate_index = -1`。MUST NOT 因写 pipeline_trace 失败而影响通话主路径——写入 SHALL 用 try/except 包裹，失败仅 ERROR 日志。本 Requirement 把"orchestrator 与 pipeline_trace 表的写入时机"从隐式约定提升为硬契约。

#### Scenario: N 个角色 LLM 并行调用

- **WHEN** 进入 PROCESSING 状态
- **THEN** engine SHALL 同时调用 Campaign 配置的 N 个角色 LLM；每个 LLM 用各自独立的 prompt 与 model；**MUST 强制 JSON Mode**（详见 role-prompt 规范）

#### Scenario: 候选传递给裁判

- **WHEN** Layer 1 全部完成（含成功 / 解析失败 / 超时 / 异常）且至少有 1 个角色 LLM 成功返回 JSON 解析通过的候选
- **THEN** engine SHALL 把通过解析的候选集合传给 Layer 2

#### Scenario: 裁判 N×M 并行调用

- **WHEN** Layer 2 启动
- **THEN** engine SHALL 对每个候选并行调用 M 个裁判；裁判输入 MUST 仅包含候选的 `reply` 字段（标记字段透传不审）

#### Scenario: 任一裁判否决即淘汰候选

- **WHEN** 某候选被 M 个裁判中的任一个判定为不通过
- **THEN** 该候选 MUST 直接淘汰，不进入 Layer 3

#### Scenario: 每轮 PROCESSING 写一条 pipeline_trace（成功路径）

- **WHEN** PROCESSING 走完整管线并由润色返回 reply
- **THEN** engine MUST 在通话结束时落库一条 `pipeline_trace(call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates, judge_results, polish_input, polish_output, polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index, error=null)`

#### Scenario: 兜底路径仍写 pipeline_trace

- **WHEN** PROCESSING 走默认回复兜底（全部裁判否决或全部候选解析失败）
- **THEN** engine MUST 仍写 pipeline_trace，`final_selected_candidate_index = -1`，`polish_output=null`，`error="all_candidates_rejected"` 或 `"all_candidates_parse_failed"`

#### Scenario: 降级路径仍写 pipeline_trace

- **WHEN** 润色超时 / 异常 / JSON 错导致取通过裁判的第一个候选作为兜底
- **THEN** engine MUST 仍写 pipeline_trace，`polish_output` 字段记录原始润色尝试的 raw_output 或异常信息，`error="polish_failed_fallback_to_first_passed"`

#### Scenario: 异常路径仍写 pipeline_trace

- **WHEN** Layer 1 全部失败（含 Provider 全部超时 / 异常）
- **THEN** engine MUST 仍写 pipeline_trace，`role_candidates` 含每个角色的 `error` 字段，`judge_results=[]`，`polish_output=null`，`error="all_roles_failed"`

#### Scenario: pipeline_trace 写入失败不影响通话

- **WHEN** END 时事务批量写 pipeline_trace 因 DB 短暂不可用而失败
- **THEN** engine MUST 重试 3 次（指数退避）后仍失败 → ERROR 日志、session 仍清理（DECR 并发 + LPUSH CallEnded）；MUST NOT 因 pipeline_trace 失败而阻塞 call_record / CallEnded 路径

#### Scenario: 简化管线（WRAPPING_UP）也写 pipeline_trace

- **WHEN** WRAPPING_UP 期间走简化管线（单角色 + 润色，不 PK 不裁判）
- **THEN** engine MUST 仍写 pipeline_trace，`role_candidates` 仅 1 条，`judge_results=[]`，`polish_output` 与 `final_selected_candidate_index=0` 正常填，无 `error`
