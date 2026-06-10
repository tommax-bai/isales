## MODIFIED Requirements

### Requirement: 与其他模块的优先级

沉默激活机制 SHALL 与转人工、超时挂断等机制按明确优先级共存；任一种转人工触发命中时 engine MUST 优先进入 TRANSFERRING。沉默驱动的挂断 SHALL 仅由本 spec「沉默超限挂断」一条路径收口（`max_silence_activations` + `silence_threshold_ms` + `silence_hangup_phrase`）；engine MUST NOT 另设独立的 wall-clock 无进展超时计时器（原 `campaign.max_no_progress_seconds` 机制已移除）。

#### Scenario: 转人工触发优先于沉默激活

- **WHEN** 同时达到沉默阈值且触发转人工条件
- **THEN** engine SHALL 优先进入 TRANSFERRING，不执行激活

#### Scenario: 持续无效输入不再独立超时挂断

- **WHEN** 用户一直说但都被判定为"非打断/无效内容"（从不真正沉默）
- **THEN** engine 保持 LISTENING、不触发沉默激活；MUST NOT 触发独立的 `no_progress` 超时挂断（`campaign.max_no_progress_seconds` 机制已移除）。若客户最终停说，则走沉默阈值 → 激活 → 超限挂断（`silence_max_reached`）路径收口
